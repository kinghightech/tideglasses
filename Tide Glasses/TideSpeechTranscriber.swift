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
    /// Asked for once, the first time the wearer uses the trigger.
    static func requestAuthorization() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String {
        guard await Self.requestAuthorization() else {
            throw TideTranscriptionError.notAuthorized
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
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
        request.shouldReportPartialResults = false

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
                guard let result, result.isFinal else { return }
                if hasResumed.claim() {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }

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
