//
//  TideChatStore.swift
//  Tide Glasses
//
//  Chat threads, kept on disk so the assistant stops forgetting everything the
//  moment the app closes.
//
//  Layout mirrors TideAlbumStore: one JSON file per thread under
//  Documents/TideChats, with attached photos written alongside in Images/.
//
//  Photos in a chat used to live only in memory — TideGlassesPhotoCapture hands
//  back a UIImage and never touches the filesystem. Keeping threads means they
//  now get written down, otherwise a reopened chat is a column of blank
//  bubbles. They stay on this phone, same as everything in the album, and
//  deleting a thread deletes its pictures with it.
//

import Combine
import SwiftUI

struct TideStoredMessage: Codable, Identifiable, Equatable {
    let id: UUID
    let role: String              // "user" | "assistant"
    var text: String
    var imageFilename: String?
    var failed: Bool
    /// The line this message put into the main memory, if it asked to.
    var savedFact: String?
    /// A calendar or reminder action. Persisted so a reopened chat keeps
    /// holding it back from the AI, rather than leaking it on the next reply.
    var isLocalAction: Bool?

    init(
        id: UUID = UUID(),
        role: String,
        text: String,
        imageFilename: String? = nil,
        failed: Bool = false,
        savedFact: String? = nil,
        isLocalAction: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.imageFilename = imageFilename
        self.failed = failed
        self.savedFact = savedFact
        self.isLocalAction = isLocalAction
    }
}

struct TideChatThread: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [TideStoredMessage]

    init(
        id: UUID = UUID(),
        title: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [TideStoredMessage] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }

    var isEmpty: Bool { messages.isEmpty }

    /// What to show in the list before a title has been derived.
    var displayTitle: String { title.isEmpty ? "New chat" : title }

    /// Titles come from the first thing the wearer said, trimmed to fit a row.
    static func title(from question: String) -> String {
        let cleaned = question
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard cleaned.count > 40 else { return cleaned }

        let cut = cleaned.prefix(40)
        // Prefer breaking on a word rather than mid-syllable.
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > 20 {
            return cut[..<space] + "…"
        }
        return cut + "…"
    }
}

@MainActor
final class TideChatStore: ObservableObject {
    @Published private(set) var threads: [TideChatThread] = []

    private let directory: URL
    private let imageDirectory: URL

    /// Decoded photos, so scrolling a thread does not re-read JPEGs off disk on
    /// every frame. Bounded by NSCache, which evicts under memory pressure.
    private let imageCache = NSCache<NSString, UIImage>()

    init() {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        directory = documents.appendingPathComponent("TideChats", isDirectory: true)
        imageDirectory = directory.appendingPathComponent("Images", isDirectory: true)

        try? FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        reload()
    }

    // MARK: - Threads

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        threads = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(TideChatThread.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func thread(id: UUID) -> TideChatThread? {
        threads.first { $0.id == id }
    }

    /// Writes a thread and moves it to the top of the list. Empty threads are
    /// not written — a chat you opened and never used should not clutter the
    /// list or leave a file behind.
    func save(_ thread: TideChatThread) {
        guard !thread.isEmpty else { return }

        var updated = thread
        updated.updatedAt = Date()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(updated) else { return }
        try? data.write(to: url(for: updated.id), options: .atomic)

        threads.removeAll { $0.id == updated.id }
        threads.insert(updated, at: 0)
    }

    func delete(_ thread: TideChatThread) {
        for message in thread.messages {
            guard let filename = message.imageFilename else { continue }
            try? FileManager.default.removeItem(at: imageDirectory.appendingPathComponent(filename))
            imageCache.removeObject(forKey: filename as NSString)
        }
        try? FileManager.default.removeItem(at: url(for: thread.id))
        threads.removeAll { $0.id == thread.id }
    }

    func deleteAll() {
        for thread in threads { delete(thread) }
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - Images

    /// Writes an attached photo and returns the filename to record on the
    /// message. Downscaled first: a library photo can be 12 megapixels, which
    /// is far more than either the model or a chat bubble will ever use.
    func storeImage(_ image: UIImage) -> String? {
        let resized = image.tide_resized(maxDimension: 1024) ?? image
        guard let data = resized.jpegData(compressionQuality: 0.7) else { return nil }

        let filename = "\(UUID().uuidString).jpg"
        do {
            try data.write(to: imageDirectory.appendingPathComponent(filename), options: .atomic)
        } catch {
            return nil
        }
        imageCache.setObject(resized, forKey: filename as NSString)
        return filename
    }

    func image(named filename: String) -> UIImage? {
        if let cached = imageCache.object(forKey: filename as NSString) { return cached }
        guard let image = UIImage(contentsOfFile: imageDirectory.appendingPathComponent(filename).path)
        else { return nil }
        imageCache.setObject(image, forKey: filename as NSString)
        return image
    }
}
