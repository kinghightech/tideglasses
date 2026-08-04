//
//  TideConversation.swift
//  Tide Glasses
//
//  Holds one thread of AI messages and drives the streaming request. Kept
//  apart from the view so the voice path can reuse it later: a spoken question
//  is the same thing as a typed one, just with a different way in and out.
//

import Combine
import SwiftUI

struct TideAIMessage: Identifiable {
    enum Role {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    var text: String
    var image: UIImage?
    var failed = false

    var isPending: Bool { role == .assistant && text.isEmpty && !failed }
}

@MainActor
final class TideConversation: ObservableObject {
    @Published private(set) var messages: [TideAIMessage] = []
    @Published private(set) var isStreaming = false

    private let client = TideAIClient()
    private var streamTask: Task<String?, Never>?

    /// Kept so a failed answer can be retried without retyping.
    private var lastPrompt: String?
    private var lastImage: UIImage?

    var isEmpty: Bool { messages.isEmpty }

    var canRetry: Bool { !isStreaming && messages.last?.failed == true }

    /// The returned task yields the finished answer, or nil if it failed.
    /// Typing callers ignore it; the voice path awaits it so it can speak.
    @discardableResult
    func send(_ question: String, image: UIImage?) -> Task<String?, Never> {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || image != nil else {
            return Task { nil }
        }

        // A photo on its own is a question in itself.
        let prompt = trimmed.isEmpty ? "What is this?" : trimmed

        messages.append(TideAIMessage(role: .user, text: prompt, image: image))
        lastPrompt = prompt
        lastImage = image
        return startStream(prompt: prompt, image: image)
    }

    @discardableResult
    func retry() -> Task<String?, Never> {
        guard let prompt = lastPrompt else { return Task { nil } }
        if messages.last?.role == .assistant {
            messages.removeLast()
        }
        return startStream(prompt: prompt, image: lastImage)
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false

        // An answer cut off before its first word has nothing to show.
        if messages.last?.isPending == true {
            messages.removeLast()
        }
    }

    func clear() {
        cancel()
        messages = []
        lastPrompt = nil
        lastImage = nil
    }

    // MARK: - Streaming

    private func startStream(prompt: String, image: UIImage?) -> Task<String?, Never> {
        let history = historyForRequest()
        messages.append(TideAIMessage(role: .assistant, text: ""))
        isStreaming = true

        let task = Task { [weak self] () -> String? in
            guard let self else { return nil }
            do {
                for try await fragment in self.client.stream(
                    question: prompt,
                    image: image,
                    history: history
                ) {
                    self.append(fragment)
                }
                return self.finish()
            } catch {
                self.fail(with: TideAIClient.describe(error))
                return nil
            }
        }
        streamTask = task
        return task
    }

    /// Prior turns as plain text. Images are not replayed — the function caps
    /// history at eight turns and re-sending photos would blow the size limit.
    private func historyForRequest() -> [TideAITurn] {
        messages
            .filter { !$0.failed && !$0.text.isEmpty }
            .map { TideAITurn(role: $0.role == .user ? "user" : "assistant", content: $0.text) }
    }

    private func append(_ fragment: String) {
        guard let index = messages.indices.last, messages[index].role == .assistant else { return }
        messages[index].text += fragment
    }

    /// Returns the completed answer, or nil when there was nothing to show.
    private func finish() -> String? {
        isStreaming = false
        streamTask = nil

        guard let index = messages.indices.last else { return nil }

        // A 200 with no content still leaves the person staring at nothing.
        if messages[index].isPending {
            messages[index].text = "The AI sent an empty answer."
            messages[index].failed = true
            return nil
        }
        return messages[index].failed ? nil : messages[index].text
    }

    private func fail(with message: String) {
        isStreaming = false
        streamTask = nil

        guard let index = messages.indices.last, messages[index].role == .assistant else { return }
        messages[index].text = message
        messages[index].failed = true
    }
}
