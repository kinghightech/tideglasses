//
//  AIView.swift
//  Tide Glasses
//
//  Chat with the assistant. Text for now, with a photo attachment so the vision
//  path can be exercised before the glasses are wired in — the same request
//  shape the single-click AI trigger will use.
//

import PhotosUI
import SwiftUI

struct AIView: View {
    @EnvironmentObject private var album: TideAlbumStore
    @EnvironmentObject private var conversation: TideConversation
    @EnvironmentObject private var voice: TideVoiceSession

    @State private var draft = ""
    @State private var attachment: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var isPickingFromLibrary = false
    @State private var isPickingFromAlbum = false
    @State private var isShowingChats = false
    @FocusState private var isComposerFocused: Bool

    private var canSend: Bool {
        !conversation.isStreaming
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachment != nil)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Tide.backdrop.ignoresSafeArea()

                VStack(spacing: 0) {
                    transcript
                    voiceBanner
                    composer
                }
            }
            .navigationTitle("Tide AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isShowingChats = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .foregroundStyle(Tide.accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        conversation.newThread()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .foregroundStyle(conversation.isEmpty ? Tide.secondaryText : Tide.accent)
                    .disabled(conversation.isEmpty)
                }
            }
            .sheet(isPresented: $isShowingChats) {
                ChatListView()
            }
            .photosPicker(
                isPresented: $isPickingFromLibrary,
                selection: $photoItem,
                matching: .images
            )
            .sheet(isPresented: $isPickingFromAlbum) {
                AlbumPhotoPicker(entries: albumPhotos) { image in
                    attachment = image
                }
            }
            .onChange(of: photoItem) { _, item in
                loadFromLibrary(item)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var albumPhotos: [TideAlbumStore.Entry] {
        album.entries.filter { $0.kind == .photo }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if conversation.isEmpty {
                        emptyState
                    }

                    ForEach(conversation.messages) { message in
                        MessageBubble(message: message, image: conversation.image(for: message))
                            .id(message.id)
                    }

                    if conversation.canRetry {
                        Button {
                            conversation.retry()
                        } label: {
                            Label("Try again", systemImage: "arrow.clockwise")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Tide.accent)
                    }

                    // Scroll anchor — keeps the newest line above the composer.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: conversation.messages.count) { _, _ in
                scroll(proxy)
            }
            .onChange(of: conversation.messages.last?.text) { _, _ in
                scroll(proxy)
            }
        }
    }

    private static let bottomAnchor = "tide.ai.bottom"

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Tide.accent)

            Text("Ask Tide anything")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Tide.primaryText)

            Text("Click the back button on your glasses to talk, or type below. Attach a photo and it will tell you what it is looking at.")
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .foregroundStyle(Tide.secondaryText)
        }
        .padding(.horizontal, 36)
        .padding(.top, 70)
    }

    // MARK: - Voice

    /// Shows what the back-button trigger is doing. Silent when idle, so the
    /// screen stays a plain chat until the glasses have something to say.
    @ViewBuilder
    private var voiceBanner: some View {
        if voice.phase != .idle || voice.errorText != nil {
            HStack(spacing: 10) {
                Image(systemName: voiceIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(voice.errorText != nil ? Tide.disconnected : Tide.accent)
                    .symbolEffect(.pulse, isActive: voice.phase == .listening)

                Text(voiceLabel)
                    .font(.system(size: 14))
                    .foregroundStyle(Tide.primaryText)

                Spacer()

                if voice.phase == .speaking {
                    Button("Stop") { voice.stopSpeaking() }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Tide.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .cardSurface(cornerRadius: 16)
            .frame(maxWidth: 760)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeOut(duration: 0.2), value: voice.phase)
        }
    }

    private var voiceIcon: String {
        if voice.errorText != nil { return "exclamationmark.triangle.fill" }
        return switch voice.phase {
        case .listening: "waveform"
        case .pausing: "hand.tap.fill"
        case .thinking: "ellipsis"
        case .looking: "camera.fill"
        case .speaking: "speaker.wave.2.fill"
        case .idle: "eyeglasses"
        }
    }

    private var voiceLabel: String {
        if let error = voice.errorText, voice.phase == .idle { return error }
        return switch voice.phase {
        case .listening: "Listening through your glasses…"
        case .pausing: "Click again to keep talking"
        case .looking: "Taking a look…"
        case .thinking: voice.heardText.map { "“\($0)”" } ?? "Thinking…"
        case .speaking: "Speaking"
        case .idle: ""
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 10) {
            if let attachment {
                attachmentPreview(attachment)
            }

            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button {
                        isPickingFromLibrary = true
                    } label: {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                    }

                    Button {
                        isPickingFromAlbum = true
                    } label: {
                        Label("Glasses Album", systemImage: "eyeglasses")
                    }
                    .disabled(albumPhotos.isEmpty)
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Tide.secondaryText)
                        .frame(width: 38, height: 38)
                }

                TextField("Ask something…", text: $draft, axis: .vertical)
                    .font(.system(size: 16))
                    .foregroundStyle(Tide.primaryText)
                    .tint(Tide.accent)
                    .lineLimit(1...5)
                    .focused($isComposerFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Tide.card, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 19, style: .continuous)
                            .strokeBorder(Tide.hairline, lineWidth: 0.8)
                    }
                    .onSubmit(send)

                sendButton
            }
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Tide.hairline)
                .frame(height: 0.8)
        }
    }

    private var sendButton: some View {
        Button {
            if conversation.isStreaming {
                conversation.cancel()
            } else {
                send()
            }
        } label: {
            Image(systemName: conversation.isStreaming ? "stop.fill" : "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Tide.backdrop)
                .frame(width: 38, height: 38)
                .background(
                    canSend || conversation.isStreaming ? Tide.accent : Tide.card,
                    in: Circle()
                )
        }
        .disabled(!canSend && !conversation.isStreaming)
    }

    private func attachmentPreview(_ image: UIImage) -> some View {
        HStack(spacing: 10) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            Text("Photo attached")
                .font(.system(size: 14))
                .foregroundStyle(Tide.secondaryText)

            Spacer()

            Button {
                attachment = nil
                photoItem = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(Tide.secondaryText)
            }
        }
        .padding(8)
        .cardSurface(cornerRadius: 16)
    }

    // MARK: - Actions

    private func send() {
        guard canSend else { return }
        conversation.send(draft, image: attachment)
        draft = ""
        attachment = nil
        photoItem = nil
    }

    private func loadFromLibrary(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                attachment = image
            }
        }
    }
}

// MARK: - Bubble

private struct MessageBubble: View {
    let message: TideAIMessage
    let image: UIImage?

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 5) {
            HStack(alignment: .bottom, spacing: 0) {
                if message.role == .user { Spacer(minLength: 44) }

                VStack(alignment: .leading, spacing: 9) {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 230, maxHeight: 230)
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }

                    if message.isPending {
                        TypingDots()
                    } else if !message.text.isEmpty {
                        Text(message.text)
                            .font(.system(size: 16))
                            .foregroundStyle(message.failed ? Tide.disconnected : Tide.primaryText)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(bubbleFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(message.role == .user ? .clear : Tide.hairline, lineWidth: 0.8)
                }

                if message.role == .assistant { Spacer(minLength: 44) }
            }

            if let note = message.memoryNote {
                MemoryChip(note: note)
            }
        }
    }

    private var bubbleFill: Color {
        if message.failed { return Tide.disconnected.opacity(0.14) }
        return message.role == .user ? Tide.accent.opacity(0.85) : Tide.card
    }
}

/// Confirms in the transcript that a line went into the main memory — or that
/// it did not, because memory is full. A save that happened invisibly would be
/// indistinguishable from one that silently failed.
private struct MemoryChip: View {
    let note: TideAIMessage.MemoryNote

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isFull ? "exclamationmark.triangle.fill" : "brain")
                .font(.system(size: 11, weight: .medium))

            Text(label)
                .font(.system(size: 12))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(isFull ? Tide.caution : Tide.secondaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            (isFull ? Tide.caution : Tide.secondaryText).opacity(0.12),
            in: Capsule()
        )
        .padding(.trailing, 4)
    }

    private var isFull: Bool { note == .full }

    private var label: String {
        switch note {
        case .saved(let fact): "Saved to memory: \(fact)"
        case .full: "Memory is full. Edit it to make room."
        }
    }
}

/// Three dots while the model is still on its first word.
private struct TypingDots: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Tide.secondaryText)
                    .frame(width: 6, height: 6)
                    .opacity(opacity(for: index))
            }
        }
        .frame(height: 19)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 3
            }
        }
    }

    private func opacity(for index: Int) -> Double {
        let distance = abs(phase - Double(index))
        return 0.3 + 0.7 * max(0, 1 - distance)
    }
}

// MARK: - Album picker

/// Photos already imported from the glasses. Read-only — this never adds to or
/// deletes from the album.
private struct AlbumPhotoPicker: View {
    let entries: [TideAlbumStore.Entry]
    let onPick: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 3)]

    var body: some View {
        NavigationStack {
            ZStack {
                Tide.backdrop.ignoresSafeArea()

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(entries) { entry in
                            Button {
                                if let image = UIImage(contentsOfFile: entry.url.path) {
                                    onPick(image)
                                }
                                dismiss()
                            } label: {
                                thumbnail(for: entry)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(3)
                }
            }
            .navigationTitle("Glasses Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func thumbnail(for entry: TideAlbumStore.Entry) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = UIImage(contentsOfFile: entry.url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Tide.card
                }
            }
            .clipped()
    }
}
