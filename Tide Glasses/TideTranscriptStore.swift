//
//  TideTranscriptStore.swift
//  Tide Glasses
//
//  Transcripts and their summaries, kept beside the recordings they belong to.
//
//  Transcribing a long recording is not instant, so it is done once and the
//  result written down. The summary is stored separately from the transcript
//  and never replaces it — the original words stay available whether or not a
//  summary was ever asked for.
//
//  Local only. None of this is ever attached to an AI request.
//

import Combine
import Foundation

struct TideRecordingNotes: Codable, Equatable {
    var segments: [TideTranscriptSegment]
    var transcribedAt: Date
    var summary: String?
    var summarizedAt: Date?

    /// The transcript as one block, for reading and for summarising.
    var fullText: String {
        segments.map(\.text).joined(separator: " ")
    }

    var wordCount: Int {
        fullText.split(whereSeparator: \.isWhitespace).count
    }
}

@MainActor
final class TideTranscriptStore: ObservableObject {
    /// Keyed by the recording's filename, which is what the album uses as its
    /// stable identifier.
    @Published private(set) var notes: [String: TideRecordingNotes] = [:]

    private let directory: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("TideTranscripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    func notes(for filename: String) -> TideRecordingNotes? {
        notes[filename]
    }

    func save(_ entry: TideRecordingNotes, for filename: String) {
        notes[filename] = entry
        write(entry, for: filename)
    }

    func delete(for filename: String) {
        notes[filename] = nil
        try? FileManager.default.removeItem(at: url(for: filename))
    }

    // MARK: - Disk

    private func url(for filename: String) -> URL {
        // The recording's own name plus .json, with path separators made safe.
        let safe = filename.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safe).json")
    }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let entry = try? decoder.decode(TideRecordingNotes.self, from: data)
            else { continue }
            // Strip the ".json" to recover the recording's filename.
            notes[file.deletingPathExtension().lastPathComponent] = entry
        }
    }

    private func write(_ entry: TideRecordingNotes, for filename: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry) else { return }
        try? data.write(to: url(for: filename), options: .atomic)
    }
}
