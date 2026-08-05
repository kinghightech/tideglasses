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

## Current state (2026-08-05)

Working:
- BLE connect, battery + charging, photo capture.
- Wi-Fi media import: gallery, full-quality photo/video/audio download, save to
  Photos + in-app album, progress UI. **Fragile — do not touch.**
- Voice recordings play in-app (tap a tile → player sheet with waveform,
  timings, play/pause).
- UI: onboarding (name + pair), home screen (#111111, large glasses hero,
  glass status/battery pills, action tiles), settings, auto-reconnect loop.
- **AI assistant**: click the back button, talk, get a spoken answer. Say
  "take a photo" and it sees what you are looking at. Works with the phone
  locked. Typed chat with photo attachment in the AI tab. See the AI section
  below — read it before touching anything voice- or camera-related.
- **Ascent game**: five-lane ocean-to-orbit runner controlled by the glasses'
  touch strip or the phone screen, with a full SceneKit 3D presentation. See
  the game section below before touching its renderer or controls.

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

## Physical buttons (re-measured 2026-08-04 — CORRECTS the 08-03 entry)

**The glasses DO report the back button over BLE.** The 2026-08-03 claim that
they never do was wrong, and it was wrong because of a bug in the capture
script, not because of the firmware. `button_watch.py` filtered on
`NOISE_PREFIXES = (bytes([0xBC, 0x73, 0x02, 0x00]),)` — that is magic + cmd
`0x73` + **length 2**, i.e. the frame *header*. It matched every two-byte
`0x73` report regardless of payload, which is precisely where the button events
live. The events were arriving the whole time and being dropped before print.

Measured with `scratchpad/button_map.py` (no filtering, guided timing, and a
red-button control to prove the capture was live):

- **Back (black) button, single click** → this sequence, twice, identical:

  | offset | frame | meaning |
  | --- | --- | --- |
  | `+0.00 s` | `0x73` payload `03 01` | microphone / listening ON |
  | `+0.2 s → +4.95 s` | `0x59`, 40-byte Opus frames @ 20 ms | the utterance |
  | `+4.98 s` | `0x73` payload `0a 01` | window closed |

  Both windows measured 4.98 s start-to-end. **The firmware gives a fixed
  ~5 s listening window with an explicit start and end marker**, so the app
  needs no voice-activity detection — just buffer between `03 01` and `0a 01`.
- `0x0A` is not in any reference enum; it is this firmware's end-of-window
  event. `0x02 AI_RECOGNITION` was predicted and does **not** appear.
- **Front (red) button** → `0x73` payload `01 01 00 00 00 01 00 01`
  (media count). Used as the control; it fired, so the capture was verified
  live and a silent result would have meant something.
- Long-hold vs single-click could not be told apart in this capture — the same
  `03 01` / `0a 01` pair appeared for what the wearer reported as single
  clicks. Worth a second pass if the two ever need distinguishing, but it does
  not block the AI feature: the trigger is the same either way.
- Leaving speech-recognition mode enabled previously broke the front button.
  Always stop any mode that gets started.

## Audio recordings (solved 2026-08-03)

- Saved on the glasses as **bare Opus**, extension `.opus` — no Ogg, no WAV
  header. The file is a flat run of **40-byte CBR packets** (`4B 41 …`,
  Opus TOC + frame-count byte), one 20 ms frame each, 16 kHz mono.
  323 packets ≈ 6.5 s. It is the same framing the BLE mic stream uses.
- **Never trim trailing zero bytes from a frame.** The nisaetus reference does
  this; on this firmware the zeros are part of the fixed-size frame and
  trimming corrupts ~60% of them. Pass the 40-byte payload whole.
- **Never de-duplicate consecutive identical frames** on the live BLE mic
  stream. `scratchpad/audio_capture.py` drops a frame when it equals the one
  before it, on the theory that BLE delivers some notifications twice. It does
  not. Measured 2026-08-04: 477 frames arrived while the mic was open for
  ~9.5 s wall-clock; 477 × 20 ms = 9.54 s, an exact match, and identical-payload
  pairs have the same inter-arrival distribution as different-payload pairs
  (median 29 ms both). Repeated payloads are real frames — near-silence encodes
  to identical bytes. De-duplicating throws away 43% of the audio and yields
  5.42 s for a 9.5 s recording. Same family of bug as the zero-trimming one.
- **iOS decodes it with no third-party library**: AudioToolbox
  `AudioConverterNew` with `mFormatID = kAudioFormatOpus`,
  `mFramesPerPacket = 320`, feeding one packet at a time with an
  `AudioStreamPacketDescription`. Verified 323/323 packets on macOS before
  writing any app code. See `TideOpusDecoder.swift`.
  (The C callback needs a stable allocated scratch buffer — handing it a Swift
  `Data` trips exclusivity checking and crashes.)
- Audio already flows through the existing import path: the manifest lists
  `.opus`, the importer downloads every item and adds it to the album; only
  the Photos-library save is skipped (Photos rejects audio). No transfer code
  changes were needed to support audio.
- Nothing in the app or either reference SDK sends a delete command. If media
  vanishes from the glasses after a transfer, the firmware did it.

## AI assistant — BUILT AND WORKING (2026-08-04)

Click the back button, talk, get a spoken answer. Say "take a photo" in the
question and it also sees what you are looking at. Works with the phone locked.

Files, all new except where noted:

| file | what it does |
| --- | --- |
| `TideAIClient.swift` | POSTs to the edge function, parses the SSE stream, shrinks images to fit the 400 KB cap |
| `TideConversation.swift` | the open thread; `send()` returns a Task yielding the final answer, and takes an `onFragment` callback |
| `TideVoiceSession.swift` | the whole voice loop and its state machine |
| `TideSpeechTranscriber.swift` | on-device speech → text |
| `TideSentenceSplitter.swift` | splits streamed text into speakable sentences |
| `TideGlassesPhotoCapture.swift` | pulls a photo over BLE |
| `TideVoiceCatalog.swift` | picks the TTS voice |
| `TideChatStore.swift` | chat threads persisted to `Documents/TideChats` |
| `TideMemoryStore.swift` | the main memory block (UserDefaults, 1000-char cap) |
| `TideMemoryTrigger.swift` | parses "update memory …" out of a message |
| `AIView.swift` | chat UI (was an empty stub) |
| `ChatListView.swift` | thread list + the way into Memory |
| `MemoryView.swift` | the memory editor |
| `TideSecrets.swift` | device key, **gitignored** |
| `TideGlassesBluetoothManager.swift` | *existing file* — three small additions, see below |

**Only three things were added to the BLE manager.** Everything else in the AI
feature is new files.

1. `onPacket?(command, payload)` in `processPacket` — a read-only tap placed
   before every existing branch.
2. `sendVisionCommand(command:payload:)` — a thin pass-through to the private
   writer, guarded so it refuses to fire during a Wi-Fi transfer negotiation.
3. A fix to `handleSerialNotification` reassembly (see the next section — this
   one is important and non-obvious).

**Done (2026-08-04):**
- `tide-vision` edge function is live on the Kernel project
  (`zwxmmkiwvhsjdztenwfy`). Reads secret `OPENROUTER_API_KEY`, model
  `openai/gpt-5.6-luna`, `verify_jwt: false`, auth by an `x-tide-key` header
  checked against a SHA-256 hash in its own source. Streams SSE, sets
  `data_collection: "deny"` so no provider retains the wearer's photos, and its
  system prompt is already written for short spoken answers.
- `TideAIClient.swift` (SSE streaming + image downscaling to fit the 400 KB
  cap), `TideConversation.swift` (thread state, reusable by the voice path),
  `AIView.swift` (chat UI, attach from photo library or glasses album).
  Verified on device: text, follow-up context, and vision all work.
- `TideSecrets.swift` holds the device key and is **gitignored**.
- The button trigger bytes are now known — see Physical buttons above.

**Voice trigger — built and working (2026-08-04).** `TideVoiceSession.swift`
watches for `0x73 03 01`, buffers the `0x59` frames, and closes on
`0x73 0a 01`. Decodes with `TideOpusDecoder.decode(data:)`, transcribes with
`TideSpeechTranscriber`, asks through `TideConversation`, speaks the answer.

Design decisions that were paid for in testing — do not undo casually:

- **The voice path never sends a command to the glasses.** The longer listening
  that speech-recognition mode (`0x41 [02 01 07]`) would allow is deliberately
  NOT used — that mode has broken the front button before. Only the camera
  writes, and only via the guarded `sendVisionCommand`.
- **Window stitching**: the firmware's window is a fixed ~5 s, which is not a
  sentence. After it closes there is a **1 second** grace period; another click
  inside it continues the same question instead of starting a new one. Two
  seconds felt laggy; one is what the wearer chose. Audio spoken during the gap
  between windows is lost — that is inherent, not a bug.
- **Audio session is activated once per app launch and never deactivated**
  (`prepareAudioRoute`). Toggling it around each answer makes iOS re-acquire
  the Bluetooth route and the glasses chime every single time. Do not add a
  `setActive(false)` back.
- **Errors are displayed, never spoken.** Speaking them meant the glasses
  talked at the wearer every time a transcription came back empty.
- **Transcription is on-device only** (`requiresOnDeviceRecognition = true`).
  Letting it fall back to Apple's servers would ship the wearer's voice off the
  phone, which is the thing this app exists to avoid. If offline recognition is
  missing it fails with instructions instead.
- **Background**: `UIBackgroundModes` = `bluetooth-central` + `audio` in
  `Tide-Glasses-Info.plist`, plus a `beginBackgroundTask` assertion held from
  the click until the answer finishes. Without the assertion iOS suspends the
  app in the seconds between the last audio frame and the spoken reply.
  Verified working with the screen locked. **Not** covered: if iOS terminates
  the app outright, the button does nothing — that would need CoreBluetooth
  state restoration, which means changing how the central manager is built.
- **TTS voice**: `TideVoiceCatalog` ranks installed English voices
  Premium → Enhanced → Standard. `AVSpeechSynthesisVoice(language:)` returns
  the compact robotic voice and should never be used directly. Settings has a
  picker; empty preference means "track the best installed". Apple renamed the
  download screen in iOS 26: **Settings → Accessibility → Read & Speak →
  Voices** (was "Spoken Content"). Siri's own voice is not available to
  third-party apps. Currently using Evan (Enhanced).

## Photo over BLE (measured 2026-08-04, fully proven end to end)

A complete 512x384 JPEG can be pulled off the glasses over BLE in ~2 seconds.
The image is **pulled, never pushed** — taking the photo returns only an ack;
nothing arrives until it is requested.

```
TX  0x41 [02 01 06 02 02 02]         take a fresh AI photo
RX  0x41 [02 01 06 ff ff]            ack
RX  0x73 [02 00 NN 01 00]            ready; NN = chunk count

TX  0xFD [02 idxLo idxHi]            request chunk idx
RX  0xFD [01 cntLo cntHi idxLo idxHi] + body
```

- **The request index is LE16 at byte OFFSET 1.** Byte 0 is a type prefix and
  is ignored. Proven by elimination: `01 00` returns chunk 0 while `00 01`
  returns chunk 1 — so the index cannot be at offset 0. An empty payload, or
  any 1-byte payload, returns chunk 0.
- Response header is 5 bytes: status `01`, chunk count LE16, chunk index LE16.
  **Trust the 0xFD header for the count, not the 0x73 report** — they have
  disagreed.
- Body is 1013 bytes per chunk except the last, which is short (measured 632).
  Concatenate bodies in index order; the result starts `FF D8 FF` and ends
  `FF D9`. Measured 22 chunks, 21905 bytes, 512x384.
- Chunks arrive ~60-90 ms apart. One transient stall was seen at chunk 20 of a
  22-chunk pull; a retry absorbed it. **Retry individual chunks** — do not
  restart the whole capture.
- **nisaetus is wrong here.** `capture_and_get_thumbnail` reads one packet,
  finds `FF D8`, and returns it — that is 1/22nd of the image, the top ~5%.
  Same class of bug as its zero-trimming and frame-dedup mistakes.
- AI-photo mode conflicts with speech-recognition mode. The voice flow is
  naturally sequential (mic window closes, *then* capture), so they never
  overlap. Never start a capture while `0x73 03 01` is open.

## Two bugs that cost hours. Do not reintroduce either.

### 1. BLE packet reassembly — `0xBC` is not always a packet start

`handleSerialNotification` used to say "a fragment beginning with `0xBC` is a
new packet". That is wrong for anything larger than one BLE notification.

A photo chunk is ~1 KB and arrives as **about five notifications** (182 bytes
each on this phone). The middle fragments are raw JPEG — arbitrary bytes — so
roughly 1 in 256 of them begins with `0xBC` by pure coincidence. The old rule
threw away the half-assembled chunk and wedged the reader, so the retries
failed too. With ~108 continuation fragments per photo that is a **~34% chance
of losing the entire photo**, every time. Measured, not estimated.

The rule is now: **`0xBC` starts a packet only when no packet is in flight.**
Plus a 4 KB ceiling so a corrupt length field cannot wedge the channel forever.

Single-notification packets — which is everything the Wi-Fi transfer path
exchanges, and every audio frame — behave exactly as before. This is why the
bug lay dormant since day one: **the photo chunks are the first large packets
this app has ever received.**

### 2. Phase guards must accept `.looking`

`TideVoiceSession.Phase` is `idle → listening → pausing → thinking → looking →
speaking`. A guard written as `phase == .thinking` breaks the moment an early
capture flips the phase to `.looking`, silently dropping the question *after*
the shutter has fired. Symptom: you hear the shutter and nothing else happens.

**Use `isAnswering`** (thinking ∨ looking ∨ speaking) for "does this answer
still own the session", never a bare equality check.

## Vision: "take a photo" is the trigger

The camera fires when the wearer says one of `visionTriggers` in
`TideVoiceSession` — "take a photo", "take a picture", "take a look", "have a
look", "look at this/that" — matched anywhere in the question.

- **The trigger phrase is deliberately left in the question.** Stripping it
  mangles real sentences: "take a photo of this plant" became "plant", and
  "take a look at this and tell me what it says" lost its subject. The model
  ignores the instruction once an image is attached. Only a *bare* command with
  no question becomes "What am I looking at?".
- **An earlier design let the model ask to see** by replying `<<LOOK>>`, and it
  was reverted. It needed two round trips on exactly the slowest questions, and
  it misjudged the wearer's real phrasing on device even though it passed
  synthetic tests. Explicit is faster, simpler, and more private. Do not
  resurrect it without a strong reason.
- The capture starts from a **partial** transcript, so the shutter fires as
  soon as the phrase is heard rather than after recognition finishes. If the
  final transcript lacks the trigger the capture is cancelled; the photo is not
  stored on the glasses and never leaves the phone.
- **AI photos are not saved to the glasses** — confirmed by importing after a
  capture. Taking one leaves nothing behind.

## Chats and memory (built 2026-08-04)

Chats persist across launches, there can be many of them, and there is a
separate block of facts that survives across all of them.

**Two different memories. Do not conflate them.**

| | in-chat history | main memory |
| --- | --- | --- |
| scope | one thread | every thread |
| sent as | `history` | `memory` |
| written by | every message | only the wearer |
| limit | 20 turns / 6000 chars | 1000 chars |

**The main memory is read on every request and never gated.** This was
considered and rejected: gating reads behind "use memory" would mean "is this
safe for me to eat, take a photo" does not know about a peanut allergy, which
is the exact moment it matters. 1000 chars is ~250 tokens; the cap is what
controls cost, not gating.

**Only the wearer writes it.** `TideMemoryTrigger` matches "update memory",
"add to memory", "save to memory", "use memory" at the **start or end** of a
message — never the middle, because "how do I update memory on my laptop" is
someone talking *about* memory. The phone appends the line itself. Nothing the
model returns is ever fed back in. The edge function is told it cannot write to
memory, and to tell the wearer to say "update memory" if they ask it to
remember something any other way — otherwise it promises to remember things
that were never saved.

Same as the camera trigger, **the phrase is left in the question**; the strip
only decides what gets *stored*.

Storage: `Documents/TideChats/<uuid>.json`, images in `Images/` alongside.
Chat photos used to be RAM-only — they are written down now, and deleting a
thread deletes its pictures.

**"remember" is deliberately NOT a trigger.** It is reserved for Tide Remember,
a later feature for recalling where objects were put. Do not spend it.

Three bugs fixed here that are easy to reintroduce:

1. **The latest question used to be sent twice** — `send()` appends the user
   message before `historyForRequest()` runs, and the edge function appends the
   question itself. History must `dropLast()`.
2. **`persist()` must skip a pending assistant message.** Backgrounding mid-
   answer otherwise saves the empty placeholder, and reopening that chat shows
   a typing indicator that never stops.
3. **In-flight streams carry a `streamGeneration`.** Without it, an answer to a
   question you have switched away from writes itself into whatever chat is now
   open.

## Tide Actions — calendar and reminders (built 2026-08-05)

Third trigger in the same family as "take a photo" and "update memory", built
the same way and for the same reasons. `TideActionTrigger` matches **remind /
reminder / reminders** and **calendar / schedule / agenda**, within the first
six words. Everything runs through EventKit on the phone; no network call is
made and no model is asked to classify anything.

| file | what it does |
| --- | --- |
| `TideActionTrigger.swift` | parsing — trigger, intent, date, title |
| `TideActions.swift` | EventKit execution + spoken confirmations |
| `TideActionLog.swift` | local history, `Documents/tide-actions.json` |
| `ActionsView.swift` | the tab: permissions, phrasings, history |

**Nothing about an action reaches the AI service.** Both halves — the request
and the confirmation — are flagged `isLocalAction` and skipped by
`historyForRequest()`, so a calendar full of appointments is not replayed as
context on the next ordinary question. The flag is persisted, so a reopened
chat keeps holding it back. `TideVoiceSession` was **not modified**: dispatch
happens inside `TideConversation.send()`, so voice and typing both work and the
delicate voice state machine was left alone.

Three NSDataDetector behaviours, each **measured** with `scratchpad/detect.swift`,
not assumed. Do not "simplify" these away:

1. **It does not read spoken numbers.** "tomorrow at six" matches only
   `tomorrow` and silently defaults to **noon**; "tomorrow at 6" parses
   correctly. `normalizingSpokenTimes` rewrites one–twelve to digits, but only
   next to a time word, so "buy six eggs" is untouched.
2. **It swallows meal names.** "lunch tomorrow at noon" comes back as a single
   match *including* "lunch", so cutting the date out deleted the event title
   and the whole thing degraded to a look-up. `removalRange` keeps the meal
   word.
3. **A bare hour is read as AM.** "at six" → 06:00. Shifted to PM for hours 1–7
   unless "am"/"morning"/"noon" was actually said. The confirmation always
   speaks the resolved time back, which is the safety net for a wrong guess.

Also: title extraction drops everything **up to and including the trigger
word**, not just leading filler — "Can you remind me to take the bins out"
stops dead on "Can" otherwise.

**Action outcomes are always spoken, including failures.** This deliberately
differs from the "failures are shown, never spoken" rule for AI answers: a
wearer who is hands-free needs to hear "I do not have access to your reminders"
rather than get silence.

Permissions are granted in the Actions tab, on purpose — the system prompt
cannot appear on a locked phone, which is exactly when the glasses are used.
Plist keys: `NSRemindersFullAccessUsageDescription`,
`NSCalendarsFullAccessUsageDescription` (verified merged into the built binary).

Reminders get an `EKAlarm` as well as `dueDateComponents`; a due date alone
shows in the list but never notifies, which is not what "remind me" means.

## Note taker — transcripts and summaries (built 2026-08-05)

Tapping an imported voice recording opens a **full page** (`RecordingView`,
which replaced `AudioPlaybackSheet`), with a Transcribe button and then a
Summarise button. Both run on-device and cost nothing per minute.

| file | what it does |
| --- | --- |
| `TideTranscriber.swift` | SpeechAnalyzer → timed segments |
| `TideSummarizer.swift` | Foundation Models → notes, with chunking |
| `TideTranscriptStore.swift` | `Documents/TideTranscripts/<file>.json` |
| `RecordingView.swift` | the page; player, transcript, notes |

**`SpeechAnalyzer(inputAudioFile:)` does NOT work here, and it is the obvious
thing to reach for.** The glasses write bare Opus with no container, which
`AVAudioFile` cannot open — the same fact that made `TideOpusDecoder` necessary
in the first place. Use the buffer overload, `analyzeSequence(_:)` with
`AnalyzerInput`, fed from the decoder. Anything that "simplifies" this back to
the file overload will fail on every glasses recording.

**A transcript does not fit in the Foundation Models context window.**
`LanguageModelSession.GenerationError.exceededContextWindowSize` is a real case
in the SDK. `TideSummarizer` splits on sentence boundaries at ~3000 characters,
summarises each part, then folds the parts together. Each pass uses a **fresh
`LanguageModelSession`** — reusing one carries every earlier chunk along and
hits the same wall from the other side.

Other things worth knowing:

- The speech model is installed at system level, not bundled. First run may
  need `AssetInventory.assetInstallationRequest(supporting:)` and a network
  connection; progress is surfaced rather than left as a frozen screen.
- Apple Intelligence needs a supported device. `TideSummarizer.unavailableReason`
  turns each `SystemLanguageModel.Availability` case into something the wearer
  can act on; the button disables rather than failing on tap.
- **The summary never replaces the transcript.** Both are stored, and the page
  has a Transcript / Notes toggle once a summary exists.
- Transcripts and summaries are local only and are never attached to an AI
  request. A recording of a conversation is the last thing that should be
  uploaded.
- `TideAudioPlayer` gained `seek(url:id:to:)` so tapping a line jumps to it.
  It reuses the cached decoded buffer and does **not** release the audio
  session between seeks — re-acquiring the route is audible on Bluetooth, the
  same problem that caused the "ching" in the voice path.

## Ascent game — 3D visual renderer (built 2026-08-05)

The game is still the same five-lane upward dodge mechanic. Its presentation
was replaced with an original ocean-to-orbit 3D arcade world; the rules,
collision thresholds, spawn cadence, scoring, touch-strip mapping, and BLE
observation path were deliberately left unchanged. The timer lifecycle was
repaired after the redesign: leaving the tab stops the timer and returning
resumes the same active run.

| file | what it does |
| --- | --- |
| `TideDiveGame.swift` | existing game state/mechanics plus the tab-return timer resume hook |
| `TideGlassesTouchBar.swift` | existing controller bridge — **unchanged by the visual overhaul** |
| `GameView.swift` | game-only SwiftUI shell, gesture surface, arcade HUD, launch/result cards |
| `TideAscentScene.swift` | read-only SceneKit renderer fed by `TideDiveGame` state |
| `TideAscentSplash.imageset` | original generated launch artwork, stored locally in the asset catalog |

`TideAscentScene` builds the visuals from SceneKit geometry at runtime: a
jet-diver with twin particle exhausts, a perspective current grid, animated
fish, pulsing jellyfish, low-poly rock clusters, layered macaws with broad
flapping wings and tapered tails, and rotating satellites. Lighting, fog,
background objects, and colour grading change at the existing zone boundaries
from seabed through space. Obstacle nodes are keyed by their existing UUID and
moved as altitude changes; the renderer never creates a second timer, changes
an obstacle, or decides a hit.

Layout and lifecycle facts paid for in simulator QA:

- iOS 26's floating tab bar overlays tab content. Ready/game-over cards keep an
  explicit 96 pt bottom clearance; do not remove it without testing on the
  15 Pro-sized portrait viewport.
- `GameView.onDisappear` stops the loop, and `onAppear` calls
  `resumeIfNeeded()`. The game timer is registered in `.common` run-loop mode
  so holding or dragging on the screen does not pause the course.
- Phone input accepts left/right swipes, up/down swipes matching the glasses
  strip, and left/right-half taps.
- Scene lane spacing is 1.0 and the camera sits at z 14.2. This combination was
  forced to lane five in a simulator QA build and keeps the rider's full arms,
  jet pack, legs, and exhaust inside the frame. Do not widen the lane spacing
  without rerunning that edge-lane check.

**Keep the separation.** Visual work belongs in `GameView` and
`TideAscentScene`. Do not move rendering concerns into `TideDiveGame`, and do
not make the renderer observe or write BLE packets. The transparent gesture
surface in `GameView` intentionally calls the same `move(_:)` methods as the
old Canvas version, so phone and glasses controls stay mechanically identical.

Verified 2026-08-05: compact launch card above the floating tab bar, clickable
launch/restart, active play, game-over layout, layered bird render, and the
forced far-right lane framing all passed on the iPhone 17 Pro simulator. A
signed generic-device build also passed. The build was installed on the iPhone
15 Pro. The automated launch request returned without an error, but command-line
process inspection did not confirm a live process, so the installed physical-
device build still needs a quick visual open on the phone.

## Speech recognition

- **One shared `SFSpeechRecognizer`, prewarmed at launch.** Building one per
  question makes iOS reload the on-device model each time, which was seconds of
  dead air. Never construct one per call.
- On-device only (`requiresOnDeviceRecognition = true`). Falling back to
  Apple's servers would ship the wearer's voice off the phone, which is the
  thing this app exists to avoid.
- `TideSpeechTranscriber` logs its own timing to `tide-diagnostics.log`
  (`transcribed 5.2s of audio in 1.34s`). **Unverified as of this writing** —
  the wearer reported 7–8 s before the shutter, which pointed at recognition
  rather than the camera. Pull the log and read the real number before doing
  anything else about latency.

## Latency budget, measured

| stage | time | changeable? |
| --- | --- | --- |
| grace period after speech ends | 1.0 s | yes, but the wearer chose it |
| speech recognition | ~1 s hoped, **needs measuring** | probably |
| glasses exposing + encoding a photo | 2.3 s | no, firmware |
| pulling 22 chunks over BLE | 1.6 s | maybe — pipelining untested |
| model's first spoken word | ~0.7 s | already streamed sentence-by-sentence |

## Answered questions, so nobody re-researches them

- **Siri cannot be launched from a third-party app.** No API, no URL scheme, no
  entitlement. SiriKit and App Intents work the other direction. The way to get
  calendar/reminder actions is tool calling plus EventKit, which also works with
  the phone locked — Shortcuts needs the screen unlocked and switches apps.
- **Apple renamed the TTS voice download screen** in iOS 26: Settings →
  Accessibility → **Read & Speak** → Voices (was "Spoken Content"). Siri's own
  voice is not available to third-party apps; Premium is the closest.

## Known remaining work

- Transcription timing is instrumented but not yet read. Do that first.
- Chunk-request pipelining is untested; could take ~0.8 s off a photo.
- Tool calling (calendar, reminders via EventKit) discussed, not started.
- The Wi-Fi transfer path still has bugs the wearer has explicitly decided to
  leave alone: bogus IPs parsed from somewhere during listening windows, and
  ~800 failed probes in the log. **Do not "fix" these** — that code took two
  days to stabilise and the wearer wants it untouched.

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
- No custom wake word. The single-click AI trigger is firmware-provided and is
  what the feature should hang off.
- Decode incoming mic frames the same way as recordings (see above).

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
`brew install opus` + `pip install opuslib` gives a reference Opus decoder for
checking captures. Useful scripts written so far: passive event watcher, mic
capture → WAV, and protocol replays.

Pull an imported file off the phone to inspect it:

```bash
xcrun devicectl device info files --device <id> \
  --domain-type appDataContainer --domain-identifier com.aahish.Tide-Glasses
xcrun devicectl device copy from --device <id> \
  --domain-type appDataContainer --domain-identifier com.aahish.Tide-Glasses \
  --source "Documents/TideAlbum/<file>" --destination ./<file>
```

## Harmless console noise

`PointerUI`, `cannot add handler to 0 from 0`, `FigApplicationStateMonitor`,
and `nw_connection_copy_… on unconnected nw_connection` are iOS framework
chatter. `probe <ip> failed` is the app checking candidate IPs when not on the
glasses Wi-Fi. Two of ours, both cosmetic: the Opus converter's
"packet descriptions (0)" message while draining, and an AVAudioSession
main-thread warning on play.
