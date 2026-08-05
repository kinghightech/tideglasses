//
//  TideConversation.swift
//  Tide Glasses
//
//  One open chat thread, and the streaming request that drives it.
//
//  Kept apart from the view so the voice path can reuse it: a spoken question is
//  the same thing as a typed one, just with a different way in and out. The
//  public surface here (messages / isStreaming / send / retry / cancel) is what
//  TideVoiceSession talks to, so it stays stable.
//
//  Two kinds of memory meet in this file:
//
//  * The thread itself — everything said in THIS chat, sent as `history`, and
//    written to disk so closing the app does not erase it.
//  * The main memory — a short block of facts about the wearer that goes out
//    with every question in every chat. Read on every request; written only
//    when the wearer says "update memory". Nothing the model says ever comes
//    back into it.
//

import Combine
import SwiftUI

struct TideAIMessage: Identifiable {
    enum Role {
        case user
        case assistant
    }

    /// Shown under a message that touched the main memory, so a save is never
    /// silent and a refused save is never mistaken for a successful one.
    enum MemoryNote: Equatable {
        case saved(String)
        case full
    }

    let id: UUID
    let role: Role
    var text: String
    var imageFilename: String?
    var failed = false
    var memoryNote: MemoryNote?

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        imageFilename: String? = nil,
        failed: Bool = false,
        memoryNote: MemoryNote? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.imageFilename = imageFilename
        self.failed = failed
        self.memoryNote = memoryNote
    }

    var isPending: Bool { role == .assistant && text.isEmpty && !failed }
}

@MainActor
final class TideConversation: ObservableObject {
    @Published private(set) var messages: [TideAIMessage] = []
    @Published private(set) var isStreaming = false
    @Published private(set) var threadID = UUID()

    private let chats: TideChatStore
    private let memory: TideMemoryStore
    private let client = TideAIClient()
    private var streamTask: Task<String?, Never>?

    /// Bumped whenever a stream starts, is cancelled, or the open thread
    /// changes. An in-flight request compares against it before touching
    /// anything, so an answer to a question you have already moved on from
    /// cannot write itself into the chat you are now looking at.
    private var streamGeneration = 0

    private var threadTitle = ""
    private var threadCreatedAt = Date()

    /// Kept so a failed answer can be retried without retyping.
    private var lastPrompt: String?
    private var lastImage: UIImage?

    /// How much of the thread to replay. The old cap of eight turns was four
    /// exchanges, which is nothing for a chat meant to run for days; the
    /// character budget is what actually keeps the bill down.
    private static let historyTurnLimit = 20
    private static let historyCharacterBudget = 6_000

    init(chats: TideChatStore, memory: TideMemoryStore) {
        self.chats = chats
        self.memory = memory

        // Pick up wherever the last conversation left off.
        if let latest = chats.threads.first {
            adopt(latest)
        }
    }

    var isEmpty: Bool { messages.isEmpty }

    var canRetry: Bool { !isStreaming && messages.last?.failed == true }

    func image(for message: TideAIMessage) -> UIImage? {
        message.imageFilename.flatMap { chats.image(named: $0) }
    }

    // MARK: - Threads

    /// Starts a fresh chat. Doing this on an already-empty one changes nothing,
    /// so tapping New Chat twice does not leave a trail of blank threads.
    func newThread() {
        guard !messages.isEmpty else { return }
        cancel()
        persist()
        reset()
    }

    func open(_ thread: TideChatThread) {
        guard thread.id != threadID else { return }
        cancel()
        persist()
        adopt(thread)
    }

    /// Called after a thread is deleted from the list. If it was the open one,
    /// there is nothing left to show.
    func forgetIfCurrent(_ thread: TideChatThread) {
        guard thread.id == threadID else { return }
        cancel()
        reset()
    }

    private func adopt(_ thread: TideChatThread) {
        threadID = thread.id
        threadTitle = thread.title
        threadCreatedAt = thread.createdAt
        messages = thread.messages.map { stored in
            TideAIMessage(
                id: stored.id,
                role: stored.role == "user" ? .user : .assistant,
                text: stored.text,
                imageFilename: stored.imageFilename,
                failed: stored.failed,
                memoryNote: stored.savedFact.map { .saved($0) }
            )
        }
    }

    private func reset() {
        threadID = UUID()
        threadTitle = ""
        threadCreatedAt = Date()
        messages = []
        lastPrompt = nil
        lastImage = nil
    }

    /// Writes the thread out. Called when a question is asked and when an
    /// answer settles — never per streamed fragment, which would rewrite the
    /// whole file dozens of times for one reply.
    func persist() {
        guard !messages.isEmpty else { return }

        if threadTitle.isEmpty, let first = messages.first(where: { $0.role == .user }) {
            threadTitle = TideChatThread.title(from: first.text)
        }

        // An answer still being written is not worth keeping. Backgrounding the
        // app mid-stream would otherwise save the empty placeholder, and
        // reopening that chat would show a typing indicator that never stops.
        let keeping = messages.filter { !$0.isPending }
        guard !keeping.isEmpty else { return }

        chats.save(TideChatThread(
            id: threadID,
            title: threadTitle,
            createdAt: threadCreatedAt,
            updatedAt: Date(),
            messages: keeping.map { message in
                TideStoredMessage(
                    id: message.id,
                    role: message.role == .user ? "user" : "assistant",
                    text: message.text,
                    imageFilename: message.imageFilename,
                    failed: message.failed,
                    savedFact: {
                        if case .saved(let fact) = message.memoryNote { return fact }
                        return nil
                    }()
                )
            }
        ))
    }

    // MARK: - Asking

    /// The returned task yields the finished answer, or nil if it failed.
    /// Typing callers ignore it; the voice path awaits it so it can speak.
    ///
    /// `onFragment` receives each piece of the answer as it streams in, which
    /// is how the voice path starts speaking the first sentence before the
    /// model has written the last one.
    @discardableResult
    func send(
        _ question: String,
        image: UIImage?,
        onFragment: (@MainActor (String) -> Void)? = nil
    ) -> Task<String?, Never> {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || image != nil else {
            return Task { nil }
        }

        // A photo on its own is a question in itself.
        let prompt = trimmed.isEmpty ? "What is this?" : trimmed

        // Memory is written here, on the phone, before anything is sent — the
        // model is never asked whether to save and never sees the decision.
        let request = TideMemoryTrigger.memoryRequest(in: prompt)
        var note: TideAIMessage.MemoryNote?
        if let fact = request.fact {
            note = memory.append(fact) ? .saved(fact) : .full
        }

        messages.append(TideAIMessage(
            role: .user,
            text: prompt,
            imageFilename: image.flatMap { chats.storeImage($0) },
            memoryNote: note
        ))
        lastPrompt = prompt
        lastImage = image
        persist()

        return startStream(prompt: request.question, image: image, onFragment: onFragment)
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
        streamGeneration += 1
        isStreaming = false

        // An answer cut off before its first word has nothing to show.
        if messages.last?.isPending == true {
            messages.removeLast()
        }
    }

    // MARK: - Streaming

    private func startStream(
        prompt: String,
        image: UIImage?,
        onFragment: (@MainActor (String) -> Void)? = nil
    ) -> Task<String?, Never> {
        let history = historyForRequest()
        let memoryPayload = memory.payload
        messages.append(TideAIMessage(role: .assistant, text: ""))
        isStreaming = true

        streamGeneration += 1
        let generation = streamGeneration

        let task = Task { [weak self] () -> String? in
            guard let self else { return nil }
            do {
                for try await fragment in self.client.stream(
                    question: prompt,
                    image: image,
                    history: history,
                    memory: memoryPayload
                ) {
                    guard self.isCurrent(generation) else { return nil }
                    self.append(fragment)
                    onFragment?(fragment)
                }
                return self.finish(generation)
            } catch {
                self.fail(with: TideAIClient.describe(error), generation: generation)
                return nil
            }
        }
        streamTask = task
        return task
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == streamGeneration
    }

    /// Prior turns as plain text, newest-first until the budget runs out, then
    /// flipped back into order.
    ///
    /// The question being asked right now is deliberately excluded: it has
    /// already been appended to `messages`, and the edge function adds it as
    /// the final user message itself. Including it here sent every question
    /// twice.
    ///
    /// Images are not replayed — re-sending photos on every follow-up would
    /// blow the size limit and cost a fortune.
    private func historyForRequest() -> [TideAITurn] {
        var turns: [TideAITurn] = []
        var budget = Self.historyCharacterBudget

        for message in messages.dropLast().reversed() {
            guard !message.failed, !message.text.isEmpty else { continue }
            guard turns.count < Self.historyTurnLimit else { break }
            guard message.text.count <= budget else { break }

            budget -= message.text.count
            turns.append(TideAITurn(
                role: message.role == .user ? "user" : "assistant",
                content: message.text
            ))
        }
        return turns.reversed()
    }

    private func append(_ fragment: String) {
        guard let index = messages.indices.last, messages[index].role == .assistant else { return }
        messages[index].text += fragment
    }

    /// Returns the completed answer, or nil when there was nothing to show.
    private func finish(_ generation: Int) -> String? {
        guard isCurrent(generation) else { return nil }
        isStreaming = false
        streamTask = nil

        guard let index = messages.indices.last else { return nil }

        // A 200 with no content still leaves the person staring at nothing.
        if messages[index].isPending {
            messages[index].text = "The AI sent an empty answer."
            messages[index].failed = true
            persist()
            return nil
        }
        persist()
        return messages[index].failed ? nil : messages[index].text
    }

    private func fail(with message: String, generation: Int) {
        guard isCurrent(generation) else { return }
        isStreaming = false
        streamTask = nil

        guard let index = messages.indices.last, messages[index].role == .assistant else { return }
        messages[index].text = message
        messages[index].failed = true
        persist()
    }
}
