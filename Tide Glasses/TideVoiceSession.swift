//
//  TideVoiceSession.swift
//  Tide Glasses
//
//  The single-click AI trigger.
//
//  Measured on the device 2026-08-04: clicking the back button makes the
//  firmware open a fixed ~5 s listening window and announce both ends of it —
//
//      0x73  payload 03 01     microphone on
//      0x59  payload <40 B>    Opus frames, one per 20 ms
//      0x73  payload 0a 01     window closed  (~4.98 s after the start)
//
//  Five seconds is not a sentence. The window length belongs to the firmware,
//  and the only way to extend it is to put the glasses into speech-recognition
//  mode ourselves — a write that has previously left the front button broken.
//  So instead consecutive windows are STITCHED: after one closes there is a
//  short grace period, and another click inside it continues the same question
//  rather than starting a new one. Talk, tap, keep talking, stop tapping.
//
//  Everything here hangs off the read-only `onPacket` tap on the BLE manager.
//  No command is ever sent to the glasses, so the transfer path cannot be
//  affected by anything in this file.
//

import AVFoundation
import Combine
import SwiftUI
import UIKit

@MainActor
final class TideVoiceSession: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        /// Window closed; waiting to see whether another click continues it.
        case pausing
        case thinking
        case speaking
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var heardText: String?
    @Published private(set) var errorText: String?

    /// Frames captured so far, for the listening meter.
    @Published private(set) var capturedFrames = 0

    private let conversation: TideConversation
    private let transcriber = TideSpeechTranscriber()
    private let synthesizer = AVSpeechSynthesizer()

    private var opusBuffer = Data()
    private var watchdog: Task<Void, Never>?
    private var graceTimer: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// How long to wait after a window closes for another click to continue it.
    private static let gracePeriod: Duration = .seconds(2)

    /// The firmware's window is ~5 s. If the closing event is ever lost, close
    /// it ourselves rather than buffering forever.
    private static let windowLimit: Duration = .seconds(15)

    /// Roughly a fifth of a second of audio. Shorter than this is a stray press.
    private static let minimumFrames = 10

    /// One minute of stitched windows is already far past a spoken question.
    private static let maximumFrames = 3_000

    private var isTriggerEnabled: Bool {
        UserDefaults.standard.object(forKey: "tide.voiceTrigger") as? Bool ?? true
    }

    init(conversation: TideConversation) {
        self.conversation = conversation
        super.init()
        synthesizer.delegate = self

        // Set the category up front so activating it later — possibly while
        // backgrounded, under time pressure — is just a flag flip.
        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.duckOthers]
        )
    }

    // MARK: - Packet tap

    /// Called for every validated packet, in arrival order.
    nonisolated func observe(command: UInt8, payload: Data) {
        Task { @MainActor [weak self] in
            self?.handle(command: command, payload: payload)
        }
    }

    private func handle(command: UInt8, payload: Data) {
        switch command {
        case Frame.audio:
            // Append the payload whole: no trailing-zero trim (the zeros are
            // part of the fixed 40-byte frame) and no de-duplication (repeated
            // payloads are real frames). Both mistakes are documented in
            // AGENTS.md because both have already cost us a debugging session.
            guard phase == .listening, capturedFrames < Self.maximumFrames else { return }
            opusBuffer.append(payload)
            capturedFrames += 1

        case Frame.report:
            guard payload.count >= 2 else { return }
            switch payload[0] {
            case Event.microphone where payload[1] == 0x01:
                openWindow()
            case Event.microphone, Event.windowClosed:
                pauseWindow()
            default:
                break
            }

        default:
            break
        }
    }

    // MARK: - Listening

    private func openWindow() {
        guard isTriggerEnabled else { return }

        switch phase {
        case .pausing:
            // A click inside the grace period continues the same question.
            graceTimer?.cancel()
            graceTimer = nil
            phase = .listening
            startWatchdog()

        case .idle, .speaking:
            // Interrupting playback means "never mind, listen to me instead".
            if synthesizer.isSpeaking {
                synthesizer.stopSpeaking(at: .immediate)
            }
            beginBackgroundAssertion()
            opusBuffer = Data()
            capturedFrames = 0
            heardText = nil
            errorText = nil
            phase = .listening
            startWatchdog()

        case .listening, .thinking:
            break
        }
    }

    /// The firmware closed its window. Hold the audio briefly in case another
    /// click continues the sentence.
    private func pauseWindow() {
        guard phase == .listening else { return }
        watchdog?.cancel()
        watchdog = nil
        phase = .pausing

        graceTimer?.cancel()
        graceTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.gracePeriod)
            guard !Task.isCancelled else { return }
            self?.finishListening()
        }
    }

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.windowLimit)
            guard !Task.isCancelled else { return }
            self?.pauseWindow()
        }
    }

    private func finishListening() {
        guard phase == .pausing else { return }
        graceTimer = nil

        let captured = opusBuffer
        opusBuffer = Data()

        guard capturedFrames >= Self.minimumFrames else {
            settle()
            return
        }

        phase = .thinking
        Task { await resolve(captured) }
    }

    private func resolve(_ opus: Data) async {
        guard let pcm = TideOpusDecoder.decode(data: opus) else {
            fail("That recording could not be decoded.")
            return
        }

        let question: String
        do {
            question = try await transcriber.transcribe(pcm)
        } catch {
            fail(error.localizedDescription)
            return
        }

        // A click during transcription starts a new question; abandon this one.
        guard phase == .thinking else { return }
        heardText = question

        guard let answer = await conversation.send(question, image: nil).value else {
            // The conversation already shows the failure in the transcript.
            settle()
            return
        }
        guard phase == .thinking else { return }
        speak(answer)
    }

    private func fail(_ message: String) {
        errorText = message
        speak(message)
    }

    /// Back to rest, releasing the background assertion and audio route.
    private func settle() {
        phase = .idle
        watchdog?.cancel()
        watchdog = nil
        graceTimer?.cancel()
        graceTimer = nil
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
        endBackgroundAssertion()
    }

    // MARK: - Speaking

    /// Routes to whatever output is active — if the glasses are paired as a
    /// Bluetooth audio device, the answer comes out of the glasses. The `audio`
    /// background mode is what lets this play with the screen locked.
    private func speak(_ text: String) {
        try? AVAudioSession.sharedInstance().setActive(true)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        phase = .speaking
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        settle()
    }

    // MARK: - Background execution

    /// Transcribing, asking, and answering takes a few seconds. Without an
    /// assertion iOS suspends the app between BLE wake-ups and the answer never
    /// arrives.
    private func beginBackgroundAssertion() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "TideVoice") {
            [weak self] in
            self?.endBackgroundAssertion()
        }
    }

    private func endBackgroundAssertion() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Protocol values

    private enum Frame {
        static let audio: UInt8 = 0x59      // GPT_UPLOAD — the mic stream
        static let report: UInt8 = 0x73     // DATA_REPORTING
    }

    private enum Event {
        static let microphone: UInt8 = 0x03
        /// Not in any reference SDK; this firmware's end-of-window marker.
        static let windowClosed: UInt8 = 0x0A
    }
}

extension TideVoiceSession: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.phase == .speaking else { return }
            self.settle()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            // A cancel caused by a new click must not tear down the session
            // that click just started.
            guard let self, self.phase == .speaking else { return }
            self.settle()
        }
    }
}
