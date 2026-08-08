//
//  TideFindMyGlasses.swift
//  Tide Glasses
//
//  Makes the glasses beep so you can find them down the back of the sofa.
//
//  The command is `0x41` (glasses control) with payload `02 01 0D` — the mode
//  byte the vendor enum calls `QCOperatorDeviceModeFindDevice`. Three
//  independent sources agree on `0x0D`: the vendor SDK's own enum ordering
//  (`QCDFU_Utils.h`), nisaetus's explicit `FIND_DEVICE = 0x0D` with a working
//  `find_device()`, and the fact that this app already depends on that same
//  ordering being correct for `0x0E` (restart) and `0x0F` (P2P restart).
//
//  Additive by design — this file touches nothing in the Bluetooth manager.
//  `sendVisionCommand` is already a generic framed-command writer and already
//  refuses to fire during a Wi-Fi transfer negotiation, which is the only part
//  of that file worth being careful around. The reply is inert: it reaches
//  `handleGlassesControlResponse`, fails the `isPhotoMode` test, and returns
//  without touching any published state.
//
//  Note there is no FindDeviceStop in the vendor enum, which implies the beep
//  ends on its own. If it ever turns out not to, a power cycle is the only way
//  back and this feature needs rethinking.
//

import Foundation

extension TideGlassesBluetoothManager {
    /// Asks the glasses to play their find-me sound.
    ///
    /// Returns `false` when the command could not be sent — the serial channel
    /// is not up yet, or a Wi-Fi transfer is mid-negotiation. Worth surfacing:
    /// a button that silently does nothing reads as broken.
    @discardableResult
    func playFindDeviceSound() -> Bool {
        sendVisionCommand(command: 0x41, payload: Data([0x02, 0x01, 0x0D]))
    }
}

/// What the button is showing right now. Shared by the home tile and the
/// settings row so the two stay worded the same.
enum TideFindPhase {
    case idle
    case beeping
    case failed

    /// How long the label stays before falling back to `idle`.
    var duration: Duration? {
        switch self {
        case .idle: nil
        case .beeping: .seconds(4)
        case .failed: .seconds(2.5)
        }
    }
}
