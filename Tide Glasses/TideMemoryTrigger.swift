//
//  TideMemoryTrigger.swift
//  Tide Glasses
//
//  Decides whether a message was asking Tide to remember something.
//
//  Same shape as the camera trigger in TideVoiceSession: the phone decides,
//  locally, before anything is sent. The model is never asked whether to save a
//  fact and can never write to memory on its own — a spoken phrase is the only
//  thing that puts a line in there.
//
//  The word "remember" is deliberately NOT a trigger. It belongs to Tide
//  Remember, the separate store for where things were put, so that it can own
//  the word later without anyone relearning the wording.
//

import Foundation

enum TideMemoryTrigger {
    /// Phrases that mean "put this in your memory".
    ///
    /// Longer variants come first so "update my memory" is not matched by
    /// "update memory" and left with a stray "my".
    static let phrases = [
        "update my memory", "update the memory", "update memory",
        "add to my memory", "add to memory",
        "save to my memory", "save to memory",
        "remember this in memory",
        "use my memory", "use memory",
    ]

    /// Punctuation and space left behind once a phrase is cut out.
    private static let noise = CharacterSet(charactersIn: " \t\n,.;:!?-—")

    /// Splits a message into the fact to store and the question to ask.
    ///
    /// The question comes back **unchanged**. Cutting the phrase out of what
    /// gets sent is what mangled sentences in the camera trigger — "take a
    /// photo of this plant" became "plant" — and the model simply ignores the
    /// instruction anyway. The strip only decides what gets *stored*.
    ///
    /// A phrase is only honoured at the start or the end of the message. In the
    /// middle it is far more likely to be someone talking *about* memory
    /// ("how do I update memory on my laptop") than asking for a save.
    static func memoryRequest(in text: String) -> (fact: String?, question: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, text) }

        for phrase in phrases {
            if let range = trimmed.range(of: phrase, options: [.caseInsensitive, .anchored]) {
                return (fact(from: String(trimmed[range.upperBound...])), text)
            }
        }

        // Trailing punctuation first, so "…, update memory." still matches.
        let tail = trimmed.trimmingCharacters(in: noise)
        for phrase in phrases {
            let options: String.CompareOptions = [.caseInsensitive, .anchored, .backwards]
            if let range = tail.range(of: phrase, options: options) {
                return (fact(from: String(tail[..<range.lowerBound])), text)
            }
        }

        return (nil, text)
    }

    /// Tidies the leftover into something worth reading back in a list.
    /// Returns nil when nothing but the bare command was said.
    private static func fact(from remainder: String) -> String? {
        var value = remainder.trimmingCharacters(in: noise)

        // "update memory that my name is …" → "my name is …"
        for filler in ["that ", "this ", "about "] {
            if value.lowercased().hasPrefix(filler) {
                value = String(value.dropFirst(filler.count)).trimmingCharacters(in: noise)
                break
            }
        }

        guard !value.isEmpty else { return nil }
        return finished(sentence: capitalizedFirst(value))
    }

    /// Capitalises the opening letter, but leaves "iPhone" and "eBay" alone —
    /// a lowercase letter followed by an uppercase one is a brand, not a typo.
    private static func capitalizedFirst(_ value: String) -> String {
        let characters = Array(value)
        guard let first = characters.first, first.isLowercase else { return value }
        if characters.count > 1, characters[1].isUppercase { return value }
        return first.uppercased() + String(characters.dropFirst())
    }

    private static func finished(sentence: String) -> String {
        guard let last = sentence.last, !".!?".contains(last) else { return sentence }
        return sentence + "."
    }
}
