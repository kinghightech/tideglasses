# AGENTS.md — Tide Glasses

Context that must survive a chat rollback. Read this first. Update it whenever
something is learned or changed.

## What this app is

Private, local-only companion app for AIMB-G2 / HeyCyan smart glasses.
Everything stays on the iPhone — the whole point is not sending media to the
vendor's cloud. Bundle id `com.aahish.Tide-Glasses`.

## Working rules (agreed after a costly rollback on 2026-08-03)

1. **Never edit the media transfer path** unless explicitly asked. That means
   `TideGlassesMediaTransferManager.swift` and the Wi-Fi/transfer sections of
   `TideGlassesBluetoothManager.swift`. It works but is fragile.
2. **Additive only for new features.** New files, new tab. The only allowed
   touch to existing BLE code is a read-only observer hook that does not alter
   existing parsing.
3. **Prove protocol bytes on the Mac before writing Swift.** There is a working
   Python/bleak rig (see below). Only proven bytes get ported.
4. **One change at a time**: build → install → verify on device → commit.
   If something regresses, revert; do not patch forward.
5. **Commit often, with real messages.** A rollback should cost one command.
6. **Keep this file current** so a rewound chat loses nothing.

## Current state (2026-08-03)

Working:
- BLE connect, battery + charging, photo capture.
- Wi-Fi media import: gallery, full-quality photo/video download, save to
  Photos + in-app album, progress UI. **Fragile — do not touch.**
- UI: onboarding (name + pair), home screen (#111111, large glasses hero,
  glass status/battery pills, action tiles), settings, auto-reconnect loop.

Not working / known issues:
- Hotspot start is unreliable. Tide's BLE commands are byte-identical to the
  official Cyan app (verified via HCI capture) yet Cyan brings the hotspot up
  in 12–19 s while Tide often times out at 36 s with event `0x73 09 FF 02`.
  Cause is below the app layer; unresolved.

## Protocol facts (verified on the physical device)

- Frame: `[0xBC, cmd, lenLE16, crc16modbus(payload)LE16, payload]`,
  empty-payload CRC `FF FF`. Serial channel write `DE5BF72A…`, notify
  `DE5BF729…`.
- Start transfer: `0x41` payload `02 01 04 02` (the 4th byte is absent from
  every public SDK but present in the official app's traffic).
- Stop transfer: `0x41` payload `02 01 09`. Official app sends this at the end
  of every session.
- Opening handshake (official app, paced ~60–150 ms apart): `0x43 [01]`,
  `0x40 [YY MM DD HH MM SS 01 29 02]` BCD time, `0x47 [01]`,
  `0x41 [02 04]` media counts, `0x42 [01]` battery.
- Hotspot live event: `0x73` payload `08 <4 IP bytes>`. Abort: `0x73 09 FF 02`.
- `0x73 0B xx` is a free-running counter, not a stage. Never gate on it.
- Media over HTTP: `http://192.168.31.1/files/media.config`, `/files/<name>`.
- **URLSession is unusable on the glasses hotspot** (no internet → iOS fails
  requests). All glasses HTTP uses raw `NWConnection` with
  `requiredInterfaceType = .wifi`.
- Videos must be saved to Photos from a **file URL**, not Data.
- Firmware ends idle Wi-Fi sessions after ~40 s; a periodic IP query keeps it
  alive during transfers.

## AI voice feature (planned, not built)

Goal: press-to-talk / wake trigger → glasses stream mic audio → AI answers,
optionally seeing a photo the glasses send over BLE.

Known-good references:
- `/Users/aahishabbani/Projects/nisaetus/nisaetus/live_client.py` — working
  voice assistant for these glasses. Mic audio arrives as OPUS frames on cmd
  `0x59`; decode at 16 kHz mono, 20 ms frames (320 samples).
  Start mic = speech-recognition mode `0x41 [02 01 07]`, stop = `[02 01 0B]`.
  Restart the mode if audio stalls >3 s. **AI photo mode conflicts with
  speech-recognition mode — never run both.**
- Vendor SDK: `QGVoiceWakeupCmd` (on-device wake word on/off, cmd `0x44`),
  `QGVoiceHeartbeatCmd` (`0x45`), AI speak mode (`0x48`),
  `aiImageData` / `didReceiveAIChatImageData` (image pushed over BLE),
  thumbnail cmd `0xFD`.
- Android SDK jar (`android/glasses_sdk_20250723_v01.aar`) has
  `AiChatResponse`, `GlassesAiVoiceRsp`, `GlassesAiVoicePlayStatusRsp`,
  `TouchControlReq` (cmd `0x3B`, `[01]` read / `[01, on]` set).

Constraints:
- The wake phrase lives in firmware; it cannot be renamed to "Hey Tide".
  Options are the built-in phrase, a button trigger, or phone-side detection.
- Leaving speech-recognition mode enabled previously broke the physical
  shutter button (single press = photo, double = video). **Always stop the
  mode when done.**

Backend: OpenRouter model `openai/gpt-5.6-luna`, called from a Supabase edge
function (project `kernel`, secret `Openrouter_Api_key`). The app should call
the edge function, never hold the key.

## Tooling

Build + install (device id is the iPhone 15 Pro):

```bash
xcodebuild -project 'Tide Glasses.xcodeproj' -scheme 'Tide Glasses' \
  -configuration Debug -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates build

xcrun devicectl device install app --device 01C8F77F-4D6B-5CFA-8237-458845FF0DB7 \
  '<DerivedData>/Build/Products/Debug-iphoneos/Tide Glasses.app'
```

On-device diagnostics log (pull over USB):

```bash
xcrun devicectl device copy from --device 01C8F77F-4D6B-5CFA-8237-458845FF0DB7 \
  --domain-type appDataContainer --domain-identifier com.aahish.Tide-Glasses \
  --source Documents/tide-diagnostics.log --destination ./tide.log
```

Bluetooth packet capture: Apple's Bluetooth logging profile is installed on the
phone. Trigger a sysdiagnose (Vol-Up + Vol-Down + Side, one-second squeeze),
then pull `DiagnosticLogs/sysdiagnose/*.tar.gz` from the `systemCrashLogs`
domain and parse `logs/Bluetooth/bluetoothd-hci-latest.pklg`.

Mac-side BLE rig (test protocol without risking the app): Python venv with
`bleak` in the session scratchpad; scripts drive the glasses directly from the
Mac. Only one BLE central can connect at a time — quit the phone apps first.
