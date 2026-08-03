//
//  GalleryView.swift
//  Tide Glasses
//
//  One-page gallery: automatic import from the glasses with live progress,
//  and a Photos-style grid of everything imported.
//

import AVKit
import SwiftUI

struct GalleryView: View {
    @EnvironmentObject private var glasses: TideGlassesBluetoothManager
    @EnvironmentObject private var media: TideGlassesMediaTransferManager
    @EnvironmentObject private var album: TideAlbumStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var isSelecting = false
    @State private var selectedIDs = Set<String>()
    @State private var viewerStart: ViewerStart?

    private let columns = [
        GridItem(.adaptive(minimum: 110), spacing: 3)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    importCard

                    if media.needsManualWiFiJoin
                        || (media.hotspotSSID != nil && media.deviceIP == nil && !media.isBusy) {
                        manualWiFiCard
                    }

                    albumSection
                }
                .frame(maxWidth: 760)
                .padding()
            }
            .background(Color.secondary.opacity(0.08))
            .navigationTitle("Gallery")
            .toolbar {
                if isSelecting, !selectedIDs.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .destructive) {
                            deleteSelected()
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
                if !album.entries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(isSelecting ? "Done" : "Select") {
                            isSelecting.toggle()
                            selectedIDs = []
                        }
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                // Returning from Settings after joining the glasses hotspot
                // manually: pick the session back up without another tap.
                if phase == .active {
                    media.resumeIfJoinedManually()
                }
            }
            .onAppear {
                // The phone may already be on the glasses network (joined by
                // hand or by another app) — import from it if so.
                media.resumeIfJoinedManually()
            }
            .fullScreenCover(item: $viewerStart) { start in
                MediaViewer(entries: viewableEntries, startIndex: start.index)
            }
        }
    }

    private var viewableEntries: [TideAlbumStore.Entry] {
        album.entries.filter { $0.kind == .photo || $0.kind == .video }
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Glasses import")
                        .font(.headline)
                    Text(media.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if glasses.isRequestingWiFiTransfer {
                        Text(glasses.wifiTransferStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if media.isBusy {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }

            if media.isImportingAll {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: media.importProgress)
                    if !media.importDetail.isEmpty {
                        Text(media.importDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let error = media.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button {
                    media.openGallery()
                } label: {
                    Label(
                        media.isBusy ? "Importing…" : "Import Glasses Data",
                        systemImage: "square.and.arrow.down"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!glasses.isConnected || media.isBusy)

                if media.hotspotSSID != nil {
                    Button {
                        media.endWiFiSession()
                    } label: {
                        Label("Stop", systemImage: "wifi.slash")
                    }
                    .buttonStyle(.bordered)
                }
            }

            if !glasses.isConnected {
                Text("Connect the AIMB-G2 from the Glasses tab first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .galleryCardStyle()
    }

    private var manualWiFiCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Wi-Fi connection help", systemImage: "arrow.clockwise.circle")
                .font(.headline)

            Text("Keep the glasses powered on and retry here. Tide Glass will enter the password and join the hotspot for you.")
                .foregroundStyle(.secondary)

            if let ssid = media.hotspotSSID {
                LabeledContent("Network", value: ssid)
                    .textSelection(.enabled)
            }
            if let password = media.hotspotPassword {
                LabeledContent("Password", value: password)
                    .textSelection(.enabled)
            }

            Button("Retry automatic connection") {
                media.retryAutomaticJoin()
            }
            .buttonStyle(.borderedProminent)
            .disabled(media.isBusy)

            Text("Still stuck? Open Settings ▸ Wi-Fi, join the network above with the password shown, then come back and continue.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("I joined in Settings — continue") {
                media.continueAfterManualJoin()
            }
            .buttonStyle(.bordered)
            .disabled(media.isBusy)
        }
        .galleryCardStyle()
    }

    private var albumSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if album.entries.isEmpty {
                ContentUnavailableView {
                    Label("Nothing imported yet", systemImage: "photo.stack")
                } description: {
                    Text("Connect your glasses and tap Import Glasses Data. Everything transfers automatically and appears here.")
                }
                .frame(minHeight: 240)
            } else {
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(album.entries) { entry in
                        AlbumTile(
                            entry: entry,
                            isSelecting: isSelecting,
                            isSelected: selectedIDs.contains(entry.id)
                        )
                        .onTapGesture {
                            handleTap(entry)
                        }
                    }
                }
            }
        }
    }

    private func handleTap(_ entry: TideAlbumStore.Entry) {
        if isSelecting {
            if selectedIDs.contains(entry.id) {
                selectedIDs.remove(entry.id)
            } else {
                selectedIDs.insert(entry.id)
            }
            return
        }
        guard let index = viewableEntries.firstIndex(where: { $0.id == entry.id }) else {
            return
        }
        viewerStart = ViewerStart(index: index)
    }

    private func deleteSelected() {
        for id in selectedIDs {
            if let entry = album.entries.first(where: { $0.id == id }) {
                album.delete(entry)
            }
        }
        selectedIDs = []
        isSelecting = false
    }
}

private struct ViewerStart: Identifiable {
    let id = UUID()
    let index: Int
}

private struct AlbumTile: View {
    let entry: TideAlbumStore.Entry
    let isSelecting: Bool
    let isSelected: Bool
    @State private var thumbnail: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color.secondary.opacity(0.15)
                        Image(systemName: placeholderSymbol)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if entry.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : .white)
                        .shadow(radius: 2)
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
            .task(id: entry.id) {
                if thumbnail == nil {
                    thumbnail = await Self.makeThumbnail(for: entry)
                }
            }
    }

    private var placeholderSymbol: String {
        switch entry.kind {
        case .video: "video.fill"
        case .audio: "waveform"
        default: "photo"
        }
    }

    private static func makeThumbnail(for entry: TideAlbumStore.Entry) async -> UIImage? {
        switch entry.kind {
        case .photo:
            return await UIImage(contentsOfFile: entry.url.path)?
                .byPreparingThumbnail(ofSize: CGSize(width: 400, height: 400))
        case .video:
            let asset = AVURLAsset(url: entry.url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 400, height: 400)
            let time = CMTime(seconds: 0.1, preferredTimescale: 600)
            guard let cgImage = try? await generator.image(at: time).image else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        default:
            return nil
        }
    }
}

private struct MediaViewer: View {
    let entries: [TideAlbumStore.Entry]
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

    init(entries: [TideAlbumStore.Entry], startIndex: Int) {
        self.entries = entries
        _index = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { position, entry in
                    page(for: entry)
                        .tag(position)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding()
        }
    }

    @ViewBuilder
    private func page(for entry: TideAlbumStore.Entry) -> some View {
        if entry.kind == .video {
            VideoPlayer(player: AVPlayer(url: entry.url))
        } else if let image = UIImage(contentsOfFile: entry.url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "photo")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
    }
}

private extension View {
    func galleryCardStyle() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 0.5)
            }
    }
}
