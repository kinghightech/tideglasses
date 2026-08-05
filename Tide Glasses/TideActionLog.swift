//
//  TideActionLog.swift
//  Tide Glasses
//
//  A record of what Tide has done on your behalf.
//
//  This never leaves the phone. It is not part of a chat thread, it is not in
//  the main memory, and nothing here is ever attached to a request — the AI
//  service has no idea any of it happened, because actions are executed
//  locally and never sent anywhere. It exists so there is somewhere to check
//  what was added, without having to open Calendar or Reminders to find out.
//
//  Look-ups are deliberately not recorded. "What do I have tomorrow" changed
//  nothing, and logging every question would bury the things that did.
//

import Combine
import Foundation

struct TideActionRecord: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case reminder
        case event
    }

    let id: UUID
    let kind: Kind
    let title: String
    /// When it is due or scheduled, not when it was created.
    let date: Date?
    let createdAt: Date

    init(id: UUID = UUID(), kind: Kind, title: String, date: Date?, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.title = title
        self.date = date
        self.createdAt = createdAt
    }
}

@MainActor
final class TideActionLog: ObservableObject {
    @Published private(set) var records: [TideActionRecord] = []

    /// Enough to answer "did that actually save?" without growing forever.
    private static let limit = 100

    private let fileURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = documents.appendingPathComponent("tide-actions.json")
        load()
    }

    func record(_ entry: TideActionRecord) {
        records.insert(entry, at: 0)
        if records.count > Self.limit {
            records.removeLast(records.count - Self.limit)
        }
        save()
    }

    func delete(_ entry: TideActionRecord) {
        records.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        records = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([TideActionRecord].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
