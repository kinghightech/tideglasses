//
//  TideVoiceCatalog.swift
//  Tide Glasses
//
//  Chooses which voice speaks the answers.
//
//  `AVSpeechSynthesisVoice(language:)` returns the *compact* system voice —
//  the robotic one, and the worst of the bunch. Apple ships three tiers, and
//  the better two are the same neural models Siri uses. They are free, they run
//  on-device, and they cost nothing in latency. They just have to be asked for
//  by identifier, and downloaded once in iOS Settings.
//

import AVFoundation

enum TideVoiceCatalog {
    /// Where the wearer's choice is remembered.
    static let preferenceKey = "tide.voiceIdentifier"

    struct Option: Identifiable, Hashable {
        let identifier: String
        let name: String
        let language: String
        let quality: AVSpeechSynthesisVoiceQuality

        var id: String { identifier }

        var qualityLabel: String {
            switch quality {
            case .premium: "Premium"
            case .enhanced: "Enhanced"
            default: "Standard"
            }
        }

        /// Sort key: premium first, then enhanced, then standard.
        var rank: Int {
            switch quality {
            case .premium: 0
            case .enhanced: 1
            default: 2
            }
        }
    }

    /// Every installed English voice, best-sounding first.
    static func available() -> [Option] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            // Personal Voice needs its own authorization flow; leave it out.
            .filter { !$0.voiceTraits.contains(.isPersonalVoice) }
            .map {
                Option(
                    identifier: $0.identifier,
                    name: $0.name,
                    language: $0.language,
                    quality: $0.quality
                )
            }
            .sorted {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                // Prefer the wearer's own region, then alphabetical.
                let preferred = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
                let lhs = preferred.hasPrefix($0.language) ? 0 : 1
                let rhs = preferred.hasPrefix($1.language) ? 0 : 1
                if lhs != rhs { return lhs < rhs }
                return $0.name < $1.name
            }
    }

    /// True when nothing better than the standard tier is installed, so the UI
    /// can point at the one Settings screen that fixes it.
    static var isStuckOnStandardQuality: Bool {
        available().first.map { $0.quality == .default } ?? true
    }

    /// The voice to speak with: the stored choice if it is still installed,
    /// otherwise the best one available.
    static func resolved() -> AVSpeechSynthesisVoice? {
        if let stored = UserDefaults.standard.string(forKey: preferenceKey),
           let voice = AVSpeechSynthesisVoice(identifier: stored) {
            return voice
        }
        if let best = available().first,
           let voice = AVSpeechSynthesisVoice(identifier: best.identifier) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: "en-US")
    }
}
