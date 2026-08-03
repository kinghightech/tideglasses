//
//  TideAlbum.swift
//  Tide Glasses
//
//  In-app album of imported media. Files live in Documents/TideAlbum;
//  removing one here never touches the iOS Photos library copy.
//

import Combine
import SwiftUI

@MainActor
final class TideAlbumStore: ObservableObject {
    struct Entry: Identifiable, Hashable {
        let filename: String
        let url: URL
        let kind: TideGlassesMediaItem.Kind
        let addedAt: Date

        var id: String { filename }
    }

    @Published private(set) var entries: [Entry] = []

    private let directory: URL

    init() {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        directory = documents.appendingPathComponent("TideAlbum", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        refresh()
    }

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        entries = files
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map { url in
                let date = (try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                return Entry(
                    filename: url.lastPathComponent,
                    url: url,
                    kind: Self.kind(for: url.lastPathComponent),
                    addedAt: date
                )
            }
            .sorted { $0.addedAt > $1.addedAt }
    }

    func contains(filename: String) -> Bool {
        entries.contains { $0.filename == filename }
    }

    func add(fileURL: URL, filename: String) throws {
        let destination = directory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: fileURL, to: destination)
        refresh()
    }

    func delete(_ entry: Entry) {
        try? FileManager.default.removeItem(at: entry.url)
        refresh()
    }

    private static func kind(for filename: String) -> TideGlassesMediaItem.Kind {
        switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic": .photo
        case "mp4", "mov", "m4v": .video
        case "opus", "wav", "m4a", "aac": .audio
        default: .unknown
        }
    }
}

