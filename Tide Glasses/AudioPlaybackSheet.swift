//
//  AudioPlaybackSheet.swift
//  Tide Glasses
//
//  Voice-memo style player for a recording imported from the glasses.
//

import SwiftUI

struct AudioPlaybackSheet: View {
    let entry: TideAlbumStore.Entry
    @ObservedObject var player: TideAudioPlayer
    @Environment(\.dismiss) private var dismiss

    private var isPlaying: Bool { player.isPlaying(entry.id) }

    var body: some View {
        ZStack {
            Tide.backdrop.ignoresSafeArea()

            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 38, height: 5)
                    .padding(.top, 10)

                Text("Voice recording")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Tide.secondaryText)
                    .padding(.top, 22)

                Text(entry.addedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Tide.primaryText)
                    .padding(.top, 4)

                waveform
                    .padding(.top, 26)
                    .padding(.horizontal, 28)

                HStack {
                    Text(timeString(player.isPlaying(entry.id) ? player.currentTime : 0))
                    Spacer()
                    Text(timeString(player.isPlaying(entry.id) ? player.duration : 0))
                }
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Tide.secondaryText)
                .padding(.horizontal, 28)
                .padding(.top, 8)

                if let error = player.errorText {
                    Text(error)
                        .font(.system(size: 13))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Tide.disconnected)
                        .padding(.horizontal, 32)
                        .padding(.top, 16)
                }

                Spacer(minLength: 0)

                Button {
                    player.toggle(url: entry.url, id: entry.id)
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(Tide.backdrop)
                        .frame(width: 78, height: 78)
                        .background(Tide.primaryText, in: Circle())
                }
                .padding(.bottom, 34)
            }
        }
        .presentationDetents([.height(400)])
        .presentationDragIndicator(.hidden)
        .preferredColorScheme(.dark)
        .onDisappear { player.stop() }
    }

    /// Simple level bars that fill as playback advances.
    private var waveform: some View {
        GeometryReader { geometry in
            let bars = 42
            let progress = isPlaying ? player.progress : 0
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<bars, id: \.self) { index in
                    let height = barHeight(index: index, of: bars, in: geometry.size.height)
                    Capsule()
                        .fill(Double(index) / Double(bars) <= progress
                              ? Tide.accent
                              : Color.white.opacity(0.18))
                        .frame(height: height)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(.linear(duration: 0.1), value: progress)
        }
        .frame(height: 64)
    }

    private func barHeight(index: Int, of total: Int, in maxHeight: CGFloat) -> CGFloat {
        // Deterministic pseudo-random shape so it looks like a waveform
        // without pretending to be a real analysis of the file.
        let seed = Double((index &* 2654435761) % 97) / 97.0
        return max(6, maxHeight * (0.25 + 0.75 * seed))
    }

    private func timeString(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        let total = Int(value.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
