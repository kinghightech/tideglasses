//
//  TideSummarizer.swift
//  Tide Glasses
//
//  Turns a transcript into notes using Apple's on-device Foundation Models.
//
//  Nothing leaves the phone and there is no per-token cost. The transcript is
//  never sent to the AI service the rest of the app talks to — a recording of a
//  conversation is the last thing that should be uploaded.
//
//  The transcript will NOT simply fit in the prompt. The model has a context
//  window, and `GenerationError.exceededContextWindowSize` is a real case in
//  the SDK — a two-minute memo fits and an hour-long meeting does not. So long
//  transcripts are summarised in passes: each chunk on its own, then those
//  summaries combined. Each pass gets a FRESH session, because one session
//  accumulates every previous turn and would run into the same wall from the
//  other direction.
//

import Foundation
import FoundationModels

enum TideSummarizerError: LocalizedError {
    case unavailable(String)
    case empty
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .empty: "There is nothing here to summarise yet."
        case .failed(let detail): detail
        }
    }
}

enum TideSummarizer {
    /// Characters per pass. Deliberately conservative — the ceiling is in
    /// tokens, this is measured in characters, and being wrong costs a
    /// thrown error rather than a slightly longer summary.
    private static let chunkBudget = 3_000

    /// Deliberately framed as summarising, never as creating or writing
    /// "notes". Asking a small on-device model to "write notes" makes it answer
    /// with `Tool call: create_notes(content="…")` instead of prose — it reads
    /// the imperative as an app command and reaches for a tool it does not
    /// have. Observed on device; do not reword this back.
    private static let instructions = """
    You summarise transcripts. You are given the text of a recording and you \
    reply with a summary of it.

    You have no tools and cannot perform any action. Your entire reply is the \
    summary text itself — never a function call, never a tool call, never JSON, \
    never anything wrapped in quotes or parentheses.

    Be concise and concrete. Plain sentences, no markdown, no headings, no \
    preamble. Never invent anything that was not said. If the transcript is \
    garbled or too short to be useful, say exactly that in one sentence.
    """

    // MARK: - Availability

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Why the button cannot be used, phrased for the person holding the phone.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            nil
        case .unavailable(.deviceNotEligible):
            "This iPhone does not support Apple Intelligence, so on-device summaries are unavailable."
        case .unavailable(.appleIntelligenceNotEnabled):
            "Turn on Apple Intelligence in iOS Settings to summarise recordings."
        case .unavailable(.modelNotReady):
            "Apple Intelligence is still downloading its model. Try again shortly."
        case .unavailable:
            "On-device summaries are unavailable on this iPhone right now."
        @unknown default:
            "On-device summaries are unavailable on this iPhone right now."
        }
    }

    // MARK: - Summarising

    static func summarize(_ transcript: String) async throws -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TideSummarizerError.empty }
        if let reason = unavailableReason { throw TideSummarizerError.unavailable(reason) }

        let chunks = split(text)
        guard chunks.count > 1 else {
            return try await run(prompt: notesPrompt(for: chunks.first ?? text))
        }

        // Pass one: each part on its own.
        var partials: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let partial = try await run(prompt: """
            This is part \(index + 1) of \(chunks.count) of a longer recording. \
            Summarise just this part in a few sentences, keeping any names, \
            dates, numbers and commitments exactly as spoken.

            \(chunk)
            """)
            partials.append(partial)
        }

        // Pass two: fold the parts into one set of notes.
        return try await run(prompt: notesPrompt(for: partials.joined(separator: "\n\n")))
    }

    private static func notesPrompt(for body: String) -> String {
        """
        Summarise the transcript below in a few short paragraphs.

        Say what it was about. Then, only where the transcript actually \
        contains them, mention anything the speakers committed to doing and any \
        dates, times or names that were said. Leave out anything that did not \
        come up.

        Reply with the summary text and nothing else.

        Transcript:
        \(body)
        """
    }

    /// One prompt, one fresh session. Reusing a session across chunks would
    /// carry every earlier chunk along and defeat the point of splitting.
    private static func run(prompt: String, isRetry: Bool = false) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(to: prompt)
            let content = unwrapToolCall(response.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { throw TideSummarizerError.failed("The summary came back empty.") }

            // Unwrapping usually recovers the text, but if the shape survived
            // it, one blunter attempt is cheaper than showing someone a
            // function call.
            if looksLikeToolCall(content), !isRetry {
                return try await run(prompt: """
                \(prompt)

                Answer in plain English sentences only. Do not write a function \
                call. Do not write a tool call. Do not use parentheses or \
                quotation marks around your answer.
                """, isRetry: true)
            }
            return content
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error {
                throw TideSummarizerError.failed(
                    "That section was too long to summarise in one pass."
                )
            }
            throw TideSummarizerError.failed(error.localizedDescription)
        } catch {
            throw TideSummarizerError.failed(error.localizedDescription)
        }
    }

    // MARK: - Tool-call leakage

    /// The on-device model sometimes answers a summarisation request with a
    /// function call it invented — seen on device as:
    ///
    ///     Tool call: create_notes(content="Sarah introduces herself and …")
    ///
    /// The summary inside is fine; only the wrapper is wrong. Rather than show
    /// that to someone, the quoted argument is pulled back out.
    static func unwrapToolCall(_ text: String) -> String {
        guard looksLikeToolCall(text) else { return text }

        // Everything between the first and last double quote is the argument.
        guard let first = text.firstIndex(of: "\""),
              let last = text.lastIndex(of: "\""),
              first < last
        else { return text }

        let inner = String(text[text.index(after: first)..<last])
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return inner.isEmpty ? text : inner
    }

    static func looksLikeToolCall(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // "Tool call: …" / "Function call: …"
        if trimmed.range(
            of: #"^(tool|function)[ _]?call\s*:"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil { return true }
        // A bare "create_notes(content=…" with no preamble at all.
        if trimmed.range(
            of: #"^[A-Za-z_][A-Za-z0-9_]*\s*\(\s*[A-Za-z_][A-Za-z0-9_]*\s*="#,
            options: .regularExpression
        ) != nil { return true }
        return false
    }

    // MARK: - Splitting

    /// Splits on sentence ends so a chunk never stops mid-thought, which reads
    /// as a non-sequitur in the partial summary.
    private static func split(_ text: String) -> [String] {
        guard text.count > chunkBudget else { return [text] }

        var chunks: [String] = []
        var current = ""

        for sentence in sentences(in: text) {
            if current.count + sentence.count > chunkBudget, !current.isEmpty {
                chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
            current += sentence
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return chunks.isEmpty ? [text] : chunks
    }

    private static func sentences(in text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, _, _, _ in
            if let substring { result.append(substring) }
        }
        // A transcript with no sentence punctuation still has to be cut up.
        return result.isEmpty ? hardSplit(text) : result
    }

    private static func hardSplit(_ text: String) -> [String] {
        stride(from: 0, to: text.count, by: chunkBudget).map { start in
            let from = text.index(text.startIndex, offsetBy: start)
            let to = text.index(from, offsetBy: chunkBudget, limitedBy: text.endIndex) ?? text.endIndex
            return String(text[from..<to])
        }
    }
}
