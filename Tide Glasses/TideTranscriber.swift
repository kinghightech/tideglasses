//
//  TideTranscriber.swift
//  Tide Glasses
//
//  Turns an imported recording into a timed transcript, on this iPhone.
//
//  Uses SpeechAnalyzer (iOS 26), which Apple built for long recordings and
//  conversations rather than short dictation — the same engine behind
//  transcription in Notes and Voice Memos. It runs locally and costs nothing
//  per minute; the only network use is a one-time model download.
//
//  IMPORTANT: `SpeechAnalyzer(inputAudioFile:)` is the obvious entry point and
//  it does NOT work here. The glasses write **bare Opus** — a flat run of
//  40-byte packets with no container — which AVAudioFile cannot open at all.
//  That is the whole reason TideOpusDecoder exists. So the buffer overload is
//  used instead, fed from the decoder, which also means video and WAV imports
//  come through the same path for free.
//

import AVFoundation
import Foundation
import Speech

struct TideTranscriptSegment: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let start: TimeInterval
    let end: TimeInterval

    init(id: UUID = UUID(), text: String, start: TimeInterval, end: TimeInterval) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
    }

    func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }
}

enum TideTranscriptionStage: Equatable {
    case preparing
    case installingModel(Double)
    case listening(Double)
}

enum TideTranscriberError: LocalizedError {
    case localeUnsupported
    case cannotRead
    case modelUnavailable(String)
    case nothingHeard

    var errorDescription: String? {
        switch self {
        case .localeUnsupported:
            "Transcription is not available for this language on this iPhone."
        case .cannotRead:
            "That recording could not be read for transcription."
        case .modelUnavailable(let detail):
            "The transcription model could not be installed. \(detail)"
        case .nothingHeard:
            "No speech was found in this recording."
        }
    }
}

enum TideTranscriber {
    /// Audio handed to the analyser in slices, so progress can be reported on
    /// a long recording instead of the screen sitting still for a minute.
    private static let chunkSeconds = 1.0

    static func transcribe(
        url: URL,
        onStage: @escaping @Sendable @MainActor (TideTranscriptionStage) -> Void
    ) async throws -> [TideTranscriptSegment] {
        await onStage(.preparing)

        let locale = try await resolvedLocale()
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        try await installModelIfNeeded(for: transcriber, locale: locale, onStage: onStage)

        guard let source = decode(url: url) else { throw TideTranscriberError.cannotRead }
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        )
        let audio = convert(source, to: analyzerFormat) ?? source

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Results arrive while the audio is still being fed in, so collection
        // has to run alongside the feed rather than after it.
        let collector = Task {
            var found: [TideTranscriptSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                found.append(TideTranscriptSegment(
                    text: text,
                    start: result.range.start.seconds,
                    end: result.range.end.seconds
                ))
            }
            return found
        }

        let stream = inputStream(for: audio, onStage: onStage)
        _ = try await analyzer.analyzeSequence(stream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        let segments = try await collector.value
        guard !segments.isEmpty else { throw TideTranscriberError.nothingHeard }
        return segments.sorted { $0.start < $1.start }
    }

    // MARK: - Model

    private static func resolvedLocale() async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let preferred = Locale.current

        // Match on language + region first, then language alone — a device set
        // to en_CA should not fall back to a different language entirely.
        if let exact = supported.first(where: { $0.identifier(.bcp47) == preferred.identifier(.bcp47) }) {
            return exact
        }
        if let language = preferred.language.languageCode?.identifier,
           let sameLanguage = supported.first(where: { $0.language.languageCode?.identifier == language }) {
            return sameLanguage
        }
        if let english = supported.first(where: { $0.language.languageCode?.identifier == "en" }) {
            return english
        }
        throw TideTranscriberError.localeUnsupported
    }

    /// Apple ships the speech model at system level rather than in the app, so
    /// the first transcription on a device may need to fetch it. Offline and
    /// not yet installed means no transcript — worth saying plainly.
    private static func installModelIfNeeded(
        for transcriber: SpeechTranscriber,
        locale: Locale,
        onStage: @escaping @Sendable @MainActor (TideTranscriptionStage) -> Void
    ) async throws {
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            return
        }

        do {
            guard let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) else { return }

            await onStage(.installingModel(0))
            let progress = request.progress
            let watcher = Task {
                while !Task.isCancelled, !progress.isFinished {
                    await onStage(.installingModel(progress.fractionCompleted))
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            defer { watcher.cancel() }

            try await request.downloadAndInstall()
        } catch {
            throw TideTranscriberError.modelUnavailable(error.localizedDescription)
        }
    }

    // MARK: - Audio

    private static func decode(url: URL) -> AVAudioPCMBuffer? {
        // The glasses' own format first — nothing in AVFoundation opens it.
        if TideOpusDecoder.looksLikeGlassesOpus(url: url),
           let buffer = TideOpusDecoder.decode(url: url) {
            return buffer
        }

        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: buffer)) != nil
        else { return nil }
        return buffer
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        to format: AVAudioFormat?
    ) -> AVAudioPCMBuffer? {
        guard let format, format != buffer.format else { return nil }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }

    private static func inputStream(
        for buffer: AVAudioPCMBuffer,
        onStage: @escaping @Sendable @MainActor (TideTranscriptionStage) -> Void
    ) -> AsyncStream<AnalyzerInput> {
        let format = buffer.format
        let total = buffer.frameLength
        let chunk = AVAudioFrameCount(format.sampleRate * chunkSeconds)

        return AsyncStream { continuation in
            var offset: AVAudioFrameCount = 0
            while offset < total {
                let count = min(chunk, total - offset)
                if let slice = buffer.tide_slice(from: offset, count: count) {
                    let time = CMTime(
                        seconds: Double(offset) / format.sampleRate,
                        preferredTimescale: 1000
                    )
                    continuation.yield(AnalyzerInput(buffer: slice, bufferStartTime: time))
                }
                offset += count

                let fraction = Double(offset) / Double(total)
                Task { @MainActor in onStage(.listening(fraction)) }
            }
            continuation.finish()
        }
    }

}

extension AVAudioPCMBuffer {
    /// Copies a window of frames into a new buffer. Handles both sample
    /// formats the decoder and AVAudioFile can hand back. Used to feed the
    /// analyser in slices, and by the player to start from a tapped line.
    func tide_slice(from offset: AVAudioFrameCount, count: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard offset + count <= frameLength,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)
        else { return nil }
        output.frameLength = count

        let channels = Int(format.channelCount)
        if let source = floatChannelData, let destination = output.floatChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel] + Int(offset), count: Int(count))
            }
            return output
        }
        if let source = int16ChannelData, let destination = output.int16ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel] + Int(offset), count: Int(count))
            }
            return output
        }
        return nil
    }
}
