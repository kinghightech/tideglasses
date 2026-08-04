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
    private var streamTask: Task<Void, Never>?

    /// Kept so a failed answer can be retried without retyping.
    private var lastPrompt: String?
    private var lastImage: UIImage?

    var isEmpty: Bool { messages.isEmpty }

    var canRetry: Bool { !isStreaming && messages.last?.failed == true }

    func send(_ question: String, image: UIImage?) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || image != nil else { return }

        // A photo on its own is a question in itself.
        let prompt = trimmed.isEmpty ? "What is this?" : trimmed

        messages.append(TideAIMessage(role: .user, text: prompt, image: image))
        lastPrompt = prompt
        lastImage = image
        startStream(prompt: prompt, image: image)
    }

    func retry() {
        guard let prompt = lastPrompt else { return }
        if messages.last?.role == .assistant {
            messages.removeLast()
        }
        startStream(prompt: prompt, image: lastImage)
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

    private func startStream(prompt: String, image: UIImage?) {
        let history = historyForRequest()
        messages.append(TideAIMessage(role: .assistant, text: ""))
        isStreaming = true

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await fragment in self.client.stream(
                    question: prompt,
                    image: image,
                    history: history
                ) {
                    self.append(fragment)
                }
                self.finish()
            } catch {
                self.fail(with: TideAIClient.describe(error))
            }
        }
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

    private func finish() {
        isStreaming = false
        streamTask = nil

        // A 200 with no content still leaves the person staring at nothing.
        if let index = messages.indices.last, messages[index].isPending {
            messages[index].text = "The AI sent an empty answer."
            messages[index].failed = true
        }
    }

    private func fail(with message: String) {
        isStreaming = false
        streamTask = nil

        guard let index = messages.indices.last, messages[index].role == .assistant else { return }
        messages[index].text = message
        messages[index].failed = true
    }
}
