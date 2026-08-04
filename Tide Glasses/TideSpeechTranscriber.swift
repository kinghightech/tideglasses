//
//  TideSpeechTranscriber.swift
//  Tide Glasses
//
//  Turns a decoded utterance from the glasses into text.
//
//  On-device recognition is required, not preferred. This app exists so the
//  wearer's surroundings do not get shipped to a vendor; quietly falling back
//  to Apple's servers would send every spoken word off the phone. If on-device
//  is unavailable we say so instead.
//

import AVFoundation
import Speech

enum TideTranscriptionError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    case onDeviceUnavailable
    case noSpeechFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "Speech recognition is off. Enable it for Tide Glass in Settings."
        case .recognizerUnavailable:
            "Speech recognition is not available on this device right now."
        case .onDeviceUnavailable:
            """
            Offline speech recognition is not installed, and Tide will not send \
            your voice to Apple's servers. Add English under \
            Settings → General → Keyboard → Dictation Languages.
            """
        case .noSpeechFound:
            "I did not catch that."
        case .failed(let message):
            message
        }
    }
}

struct TideSpeechTranscriber {
    /// One recogniser for the life of the app.
    ///
    /// Building a new `SFSpeechRecognizer` per question makes iOS load the
    /// on-device model again each time, which is seconds of dead air before a
    /// single word is recognised. Held here so it stays warm.
    private static let shared = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    /// Loads the model ahead of the first question instead of during it.
    static func prewarm() {
        _ = shared
        Task { _ = await requestAuthorization() }
    }

    /// Asked for once, the first time the wearer uses the trigger.
    static func requestAuthorization() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Transcribes an utterance. `onPartial` fires with the text so far, as it
    /// is recognised — the camera trigger uses it to start the shutter without
    /// waiting for the final result.
    func transcribe(
        _ buffer: AVAudioPCMBuffer,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        guard await Self.requestAuthorization() else {
            throw TideTranscriptionError.notAuthorized
        }
        guard let recognizer = Self.shared, recognizer.isAvailable else {
            throw TideTranscriptionError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw TideTranscriptionError.onDeviceUnavailable
        }

        // A file request is far more tolerant of unusual formats than the
        // buffer API, and 16 kHz mono from a pair of glasses is unusual.
        let url = try Self.writeWAV(buffer)
        defer { try? FileManager.default.removeItem(at: url) }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        // Partials cost nothing and let the caller act on words as they land
        // rather than after the whole pass finishes.
        request.shouldReportPartialResults = true

        let started = Date()
        let text = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            // recognitionTask can call back more than once; resume exactly once.
            let hasResumed = Resumed()
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if hasResumed.claim() {
                        continuation.resume(throwing: TideTranscriptionError.failed(
                            error.localizedDescription
                        ))
                    }
                    return
                }
                guard let result else { return }
                guard result.isFinal else {
                    onPartial?(result.bestTranscription.formattedString)
                    return
                }
                if hasResumed.claim() {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
        TideDiagnostics.log(String(
            format: "transcribed %.1fs of audio in %.2fs",
            Double(buffer.frameLength) / buffer.format.sampleRate,
            Date().timeIntervalSince(started)
        ))

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TideTranscriptionError.noSpeechFound }
        return trimmed
    }

    /// 16-bit PCM WAV. `AVAudioFile` converts from the decoder's float format.
    private static func writeWAV(_ buffer: AVAudioPCMBuffer) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tide-utterance-\(UUID().uuidString).wav")

        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: buffer.format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        try file.write(from: buffer)
        return url
    }
}

/// One-shot latch, so a callback that fires twice cannot resume a continuation
/// twice — that would crash.
private final class Resumed: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
