//
//  TideSentenceSplitter.swift
//  Tide Glasses
//
//  The model's answer arrives a few characters at a time. Waiting for all of it
//  before speaking wastes about a second; speaking every fragment as it lands
//  would stutter. This hands back whole sentences, so the first one can be
//  spoken while the model is still writing the rest.
//
//  Deliberately conservative: when in doubt it holds the text back rather than
//  splitting mid-thought. Whatever is left over at the end is flushed.
//

import Foundation

struct TideSentenceSplitter {
    /// Below this, a terminator is treated as an abbreviation or a list marker
    /// and merged into the following text instead of spoken on its own.
    private static let minimumLength = 10

    private var pending = ""

    /// Adds streamed text and returns any sentences that are now complete.
    mutating func feed(_ fragment: String) -> [String] {
        pending += fragment

        var sentences: [String] = []
        while let sentence = takeSentence() {
            sentences.append(sentence)
        }
        return sentences
    }

    /// Whatever has not been spoken yet, once the stream is finished.
    mutating func flush() -> String? {
        let remainder = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        return remainder.isEmpty ? nil : remainder
    }

    private mutating func takeSentence() -> String? {
        let characters = Array(pending)

        for index in characters.indices {
            let character = characters[index]
            guard character == "." || character == "!"
                    || character == "?" || character == "\n" else { continue }

            // A terminator only counts once whitespace follows it. Waiting for
            // that character is what stops "3." being split out of "3.5" — at
            // the end of the buffer we simply do not know yet.
            guard index + 1 < characters.count else { return nil }
            guard characters[index + 1].isWhitespace else { continue }

            // "3. 5" is still a decimal read aloud; "U.S. " is an abbreviation.
            let previous = index > 0 ? characters[index - 1] : " "
            if character == ".", previous.isNumber || previous.isUppercase { continue }

            let candidate = String(characters[0...index])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Too short to stand alone — keep scanning so it merges forward.
            guard candidate.count >= Self.minimumLength else { continue }

            pending = String(characters[(index + 1)...])
            return candidate
        }
        return nil
    }
}
