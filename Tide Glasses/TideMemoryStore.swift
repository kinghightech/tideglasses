//
//  TideMemoryStore.swift
//  Tide Glasses
//
//  The main memory: a short block of facts about the wearer that goes out with
//  every question, in every chat.
//
//  Two rules hold this together:
//
//  1. Only the wearer writes it. Either by saying "update memory …" out loud,
//     or by typing in the editor. The model reads it and can never change it —
//     nothing it says is ever fed back in here.
//  2. It is capped. This block is prepended to every single request, so an
//     unbounded one would cost tokens on every question forever. Past the cap
//     an append is REFUSED rather than trimmed: quietly dropping a fact the
//     wearer asked to keep is worse than telling them memory is full.
//

import Combine
import SwiftUI

@MainActor
final class TideMemoryStore: ObservableObject {
    /// Roughly 250 tokens. Small enough to ride along on every request without
    /// being worth thinking about, long enough for a dozen real facts.
    static let characterLimit = 1000

    private static let storageKey = "tide.memory"

    @Published var text: String {
        didSet {
            guard text != oldValue else { return }
            UserDefaults.standard.set(text, forKey: Self.storageKey)
        }
    }

    init() {
        text = UserDefaults.standard.string(forKey: Self.storageKey) ?? ""
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var characterCount: Int { text.count }

    var remainingCharacters: Int { max(0, Self.characterLimit - text.count) }

    /// What to send with a request. Nil when there is nothing worth sending, so
    /// the edge function is not handed an empty block to reason about.
    var payload: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Adds one fact on its own line.
    ///
    /// Returns false when it would not fit, having changed nothing — the caller
    /// is expected to tell the wearer rather than let the save vanish.
    @discardableResult
    func append(_ fact: String) -> Bool {
        let line = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }

        // Saying the same thing twice should not make two lines.
        guard !containsLine(line) else { return true }

        let separator = isEmpty ? "" : "\n"
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines) + separator + line
        guard candidate.count <= Self.characterLimit else { return false }

        text = candidate
        return true
    }

    func clear() {
        text = ""
    }

    private func containsLine(_ line: String) -> Bool {
        text.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(line) == .orderedSame
        }
    }
}
