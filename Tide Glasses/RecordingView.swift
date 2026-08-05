//
//  RecordingView.swift
//  Tide Glasses
//
//  A recording, its transcript, and the notes made from it.
//
//  Replaces the small playback sheet: a transcript is something you read and
//  scroll, and a detent-height popup is the wrong shape for it.
//
//  The transcript and the summary are kept apart on purpose. A summary is a
//  lossy reading of what was said; the words themselves stay available whether
//  or not one was ever asked for.
//

import SwiftUI

struct RecordingView: View {
    let entry: TideAlbumStore.Entry
    @ObservedObject var player: TideAudioPlayer

    @EnvironmentObject private var transcripts: TideTranscriptStore
    @Environment(\.dismiss) private var dismiss

    @State private var stage: TideTranscriptionStage?
    @State private var isSummarizing = false
    @State private var errorText: String?
    @State private var showingSummary = false

    private var notes: TideRecordingNotes? { transcripts.notes(for: entry.filename) }
    private var isPlaying: Bool { player.isPlaying(entry.id) }
    private var isWorking: Bool { stage != nil || isSummarizing }

    private var elapsed: TimeInterval { isPlaying ? player.currentTime : 0 }

    var body: some View {
        NavigationStack {
            ZStack {
                Tide.backdrop.ignoresSafeArea()

                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 16) {
                            player_
                            if let error = errorText { errorCard(error) }
                            body_
                        }
                        .frame(maxWidth: 760)
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .padding(.bottom, 20)
                    }

                    controls
                }
            }
            .navigationTitle("Recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tide.accent)
                }
                if notes != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if let text = notes?.fullText {
                                Button {
                                    UIPasteboard.general.string = text
                                } label: {
                                    Label("Copy transcript", systemImage: "doc.on.doc")
                                }
                            }
                            if let summary = notes?.summary {
                                Button {
                                    UIPasteboard.general.string = summary
                                } label: {
                                    Label("Copy notes", systemImage: "doc.on.doc")
                                }
                            }
                            Button(role: .destructive) {
                                transcripts.delete(for: entry.filename)
                            } label: {
                                Label("Delete transcript", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .foregroundStyle(Tide.accent)
                    }
                }
            }
            .toolbarBackground(Tide.backdrop, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onDisappear { player.stop() }
    }

    // MARK: - Player

    private var player_: some View {
        VStack(spacing: 12) {
            Text(entry.addedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Tide.secondaryText)

            waveform

            HStack {
                Text(timeString(elapsed))
                Spacer()
                Text(timeString(isPlaying ? player.duration : 0))
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(Tide.secondaryText)

            Button {
                player.toggle(url: entry.url, id: entry.id)
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Tide.backdrop)
                    .frame(width: 62, height: 62)
                    .background(Tide.primaryText, in: Circle())
            }
            .padding(.top, 2)

            if let error = player.errorText {
                Text(error)
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Tide.disconnected)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 18)
        .cardSurface(cornerRadius: 20)
    }

    private var waveform: some View {
        GeometryReader { geometry in
            let bars = 42
            let progress = isPlaying ? player.progress : 0
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<bars, id: \.self) { index in
                    Capsule()
                        .fill(Double(index) / Double(bars) <= progress
                              ? Tide.accent
                              : Color.white.opacity(0.18))
                        .frame(height: barHeight(index: index, of: bars, in: geometry.size.height))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(.linear(duration: 0.1), value: progress)
        }
        .frame(height: 54)
    }

    private func barHeight(index: Int, of total: Int, in maxHeight: CGFloat) -> CGFloat {
        // Deterministic pseudo-random shape so it looks like a waveform
        // without pretending to be a real analysis of the file.
        let seed = Double((index &* 2654435761) % 97) / 97.0
        return max(5, maxHeight * (0.25 + 0.75 * seed))
    }

    // MARK: - Body

    @ViewBuilder
    private var body_: some View {
        if let notes {
            if let summary = notes.summary, showingSummary {
                summaryCard(summary, at: notes.summarizedAt)
            } else {
                transcriptCard(notes)
            }
        } else if let stage {
            progressCard(stage)
        } else {
            emptyCard
        }
    }

    private var emptyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Tide.accent)

            Text("No transcript yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Tide.primaryText)

            Text("Tide can write out everything said in this recording, on this iPhone. Nothing is uploaded.")
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .foregroundStyle(Tide.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 24)
        .cardSurface(cornerRadius: 20)
    }

    private func progressCard(_ stage: TideTranscriptionStage) -> some View {
        VStack(spacing: 12) {
            ProgressView(value: fraction(of: stage))
                .tint(Tide.accent)

            Text(label(for: stage))
                .font(.system(size: 14))
                .foregroundStyle(Tide.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 22)
        .cardSurface(cornerRadius: 20)
    }

    private func fraction(of stage: TideTranscriptionStage) -> Double {
        switch stage {
        case .preparing: 0
        case .installingModel(let value): value
        case .listening(let value): value
        }
    }

    private func label(for stage: TideTranscriptionStage) -> String {
        switch stage {
        case .preparing:
            "Getting ready…"
        case .installingModel:
            "Downloading the speech model. This happens once, and needs a connection."
        case .listening(let value):
            "Transcribing… \(Int(value * 100))%"
        }
    }

    /// Each line is tappable and jumps playback to where it was said. The line
    /// being spoken is highlighted as it plays.
    private func transcriptCard(_ notes: TideRecordingNotes) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Transcript", detail: "\(notes.wordCount) words")

            ForEach(notes.segments) { segment in
                Button {
                    player.seek(url: entry.url, id: entry.id, to: segment.start)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Text(timeString(segment.start))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(Tide.secondaryText.opacity(0.8))
                            .frame(width: 40, alignment: .leading)
                            .padding(.top, 2)

                        Text(segment.text)
                            .font(.system(size: 16))
                            .foregroundStyle(isCurrent(segment) ? Tide.primaryText : Tide.primaryText.opacity(0.72))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(
                        isCurrent(segment) ? Tide.accent.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface(cornerRadius: 20)
        .animation(.easeOut(duration: 0.15), value: elapsed)
    }

    private func isCurrent(_ segment: TideTranscriptSegment) -> Bool {
        isPlaying && segment.contains(player.currentTime)
    }

    private func summaryCard(_ summary: String, at date: Date?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Notes", detail: date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")

            Text(summary)
                .font(.system(size: 16))
                .foregroundStyle(Tide.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Text("Written on this iPhone by Apple Intelligence, from the transcript.")
                .font(.system(size: 12))
                .foregroundStyle(Tide.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface(cornerRadius: 20)
    }

    private func header(_ title: String, detail: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Tide.secondaryText)
            Spacer()
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Tide.secondaryText.opacity(0.8))
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Tide.caution)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Tide.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Tide.caution.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 10) {
            if let notes {
                if notes.summary != nil {
                    Picker("", selection: $showingSummary) {
                        Text("Transcript").tag(false)
                        Text("Notes").tag(true)
                    }
                    .pickerStyle(.segmented)
                } else {
                    actionButton(
                        title: isSummarizing ? "Summarising…" : "Summarise with Apple Intelligence",
                        icon: "sparkles",
                        busy: isSummarizing,
                        enabled: !isWorking && TideSummarizer.isAvailable
                    ) {
                        summarize(notes)
                    }

                    if let reason = TideSummarizer.unavailableReason {
                        Text(reason)
                            .font(.system(size: 12))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Tide.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                actionButton(
                    title: stage == nil ? "Transcribe" : "Transcribing…",
                    icon: "text.viewfinder",
                    busy: stage != nil,
                    enabled: !isWorking
                ) {
                    transcribe()
                }
            }
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Tide.hairline).frame(height: 0.8)
        }
    }

    private func actionButton(
        title: String,
        icon: String,
        busy: Bool,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small).tint(Tide.backdrop)
                } else {
                    Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                }
                Text(title).font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(Tide.backdrop)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(enabled ? Tide.accent : Tide.card, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
    }

    // MARK: - Work

    private func transcribe() {
        errorText = nil
        stage = .preparing

        Task {
            do {
                let segments = try await TideTranscriber.transcribe(url: entry.url) { update in
                    stage = update
                }
                transcripts.save(
                    TideRecordingNotes(segments: segments, transcribedAt: Date()),
                    for: entry.filename
                )
            } catch {
                errorText = error.localizedDescription
            }
            stage = nil
        }
    }

    private func summarize(_ notes: TideRecordingNotes) {
        errorText = nil
        isSummarizing = true

        Task {
            do {
                let summary = try await TideSummarizer.summarize(notes.fullText)
                var updated = notes
                updated.summary = summary
                updated.summarizedAt = Date()
                transcripts.save(updated, for: entry.filename)
                showingSummary = true
            } catch {
                errorText = error.localizedDescription
            }
            isSummarizing = false
        }
    }

    private func timeString(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        let total = Int(value.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
