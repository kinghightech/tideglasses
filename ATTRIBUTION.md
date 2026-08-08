# Tide Glass acknowledgements

Tide Glass is a personal-use project by Aahish Abbani.

Its HeyCyan Bluetooth protocol mapping was informed by **Nisaetus**, an MIT-licensed project by `pepebot-space`:

- Repository: https://github.com/pepebot-space/nisaetus
- License: MIT

Additional compatibility research referenced the source-available HeyCyan SDK/demo repository:

- Repository: https://github.com/ebowwa/HeyCyanSmartGlassesSDK

The compiled HeyCyan vendor frameworks and libraries in that repository are described by its maintainer as proprietary and are not copied into Tide Glass.

The first Tide Glass compatibility build was intentionally read-only. It performed Bluetooth scanning, connection, GATT discovery, and standard Device Information reads only.

The connection-and-battery milestone references Nisaetus commit `ca24d5cf14195a891fdb0b91a47fe5a1bcbdaad3` for the HeyCyan large-data frame, the `DE5BF72A` write / `DE5BF729` notification channel, and battery operation `0x42`. Tide Glass implements this small protocol subset natively in Swift. It does not copy or link the proprietary vendor framework.

The photo-capture milestone additionally uses Nisaetus's documented `0x41` glasses-control frame with payload `02 01 01`, and validates the separate `0x73` media-update event without automatic retries.

The gallery milestone uses the documented `0x41` transfer-mode payload `02 01 04`, the glasses hotspot credentials response, the device-reported Wi-Fi IP event, and the local HTTP endpoints `/files/media.config` and `/files/<filename>`. The iOS Wi-Fi join and media-list sequence was cross-checked against the HeyCyan SDK demo. Tide Glass implements the flow natively in Swift and does not copy or link the proprietary vendor framework.

The find-device milestone uses the documented `0x41` glasses-control frame with payload `02 01 0D`, the mode the vendor enum names `QCOperatorDeviceModeFindDevice`, cross-referenced against Nisaetus's `find_device()`. It asks the glasses to play their own locate sound and carries no data.

At this stage, Tide Glass sends battery-status, single-photo-capture, Wi-Fi transfer-mode, and find-device commands. Gallery imports are copies: Tide Glass does not delete media from the glasses. Video, audio, delete, restart, firmware, and device-setting commands remain disabled.
