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
//  Five seconds is not always a sentence, and the window length belongs to the
//  firmware — the only way to extend it is to put the glasses into
//  speech-recognition mode ourselves, a write that has previously left the
//  front button broken. So consecutive windows are STITCHED instead: after one
//  closes there is a one-second grace period, and another click inside it
//  continues the same question rather than starting a new one. Say nothing and
//  it sends as normal.
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
    private let camera: TideGlassesPhotoCapture

    /// Whether to send a photo with spoken questions, so the assistant can see
    /// what the wearer is looking at. Costs a couple of seconds per question.
    private var isVisionEnabled: Bool {
        UserDefaults.standard.object(forKey: "tide.voiceVision") as? Bool ?? true
    }

    private var opusBuffer = Data()
    private var watchdog: Task<Void, Never>?
    private var graceTimer: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// Answer-in-progress state. `AVSpeechSynthesizer` queues utterances
    /// itself, so sentences can be handed over as they arrive; the count is
    /// what tells us when the last one has actually finished playing.
    private var splitter = TideSentenceSplitter()
    private var utterancesInFlight = 0
    private var isAnswerComplete = false

    /// True once the audio route has been claimed. The session is then left
    /// active for the lifetime of the app — see `prepareAudioRoute()`.
    private var hasActivatedAudio = false

    /// How long to wait after a window closes for another click to continue it.
    private static let gracePeriod: Duration = .seconds(1)

    /// The firmware's window is ~5 s. If the closing event is ever lost, close
    /// it ourselves rather than buffering forever.
    private static let windowLimit: Duration = .seconds(12)

    /// Roughly a fifth of a second of audio. Shorter than this is a stray press.
    private static let minimumFrames = 10

    /// A minute of stitched windows is already far past a spoken question.
    private static let maximumFrames = 3_000

    private var isTriggerEnabled: Bool {
        UserDefaults.standard.object(forKey: "tide.voiceTrigger") as? Bool ?? true
    }

    init(conversation: TideConversation, bluetooth: TideGlassesBluetoothManager) {
        self.conversation = conversation
        self.camera = TideGlassesPhotoCapture(bluetooth: bluetooth)
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Packet tap

    /// Called for every validated packet, in arrival order.
    nonisolated func observe(command: UInt8, payload: Data) {
        Task { @MainActor [weak self] in
            self?.handle(command: command, payload: payload)
        }
    }

    private func handle(command: UInt8, payload: Data) {
        // The camera reads the same stream. It ignores everything that is not
        // part of a capture it started.
        camera.handle(command: command, payload: payload)

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
                beginListening()
            case Event.microphone, Event.windowClosed:
                pauseListening()
            default:
                break
            }

        default:
            break
        }
    }

    // MARK: - Listening

    private func beginListening() {
        guard isTriggerEnabled else { return }

        switch phase {
        case .pausing:
            // A click inside the grace period continues the same question:
            // keep the buffer, just start listening again.
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
            // Anything queued for the previous answer was just cancelled.
            utterancesInFlight = 0
            isAnswerComplete = false
            phase = .listening
            startWatchdog()

        case .listening, .thinking:
            break
        }
    }

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.windowLimit)
            guard !Task.isCancelled else { return }
            self?.pauseListening()
        }
    }

    /// The firmware closed its window. Hold the audio for a moment in case
    /// another click continues the sentence.
    private func pauseListening() {
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

        // Start the camera immediately and transcribe at the same time. The
        // pull takes a couple of seconds; running it alongside transcription
        // hides most of that. It is started only now, never during listening —
        // AI-photo mode and speech-recognition mode conflict on this firmware.
        let photo: Task<UIImage?, Never>? = isVisionEnabled
            ? Task { [camera] in try? await camera.captureImage() }
            : nil

        let question: String
        do {
            question = try await transcriber.transcribe(pcm)
        } catch {
            photo?.cancel()
            fail(error.localizedDescription)
            return
        }

        // A click during transcription starts a new question; abandon this one.
        guard phase == .thinking else {
            photo?.cancel()
            return
        }
        heardText = question

        // A failed capture is not a failed question — send it without the
        // photo rather than refusing to answer.
        let image = await photo?.value

        guard phase == .thinking else { return }

        splitter = TideSentenceSplitter()
        utterancesInFlight = 0
        isAnswerComplete = false

        // Speak each sentence the moment it is complete, rather than waiting
        // for the whole answer. The model streams, so this is most of a second
        // off the time to the first spoken word.
        let answer = await conversation.send(question, image: image) { [weak self] fragment in
            guard let self, self.isAnswering else { return }
            for sentence in self.splitter.feed(fragment) {
                self.speak(sentence)
            }
        }.value

        guard isAnswering else { return }

        if answer != nil, let remainder = splitter.flush() {
            speak(remainder)
        }
        isAnswerComplete = true

        // Nothing was ever queued — an empty or failed answer. The conversation
        // already shows the failure in the transcript.
        if utterancesInFlight == 0 {
            settle()
        }
    }

    /// True while this answer still owns the session. A new click flips the
    /// phase and everything in flight for the old question is dropped.
    private var isAnswering: Bool {
        phase == .thinking || phase == .speaking
    }

    /// Failures are shown, never spoken. Talking at someone because a
    /// transcription came back empty is worse than saying nothing.
    private func fail(_ message: String) {
        errorText = message
        settle()
    }

    private func settle() {
        phase = .idle
        watchdog?.cancel()
        watchdog = nil
        graceTimer?.cancel()
        graceTimer = nil
        utterancesInFlight = 0
        isAnswerComplete = false
        endBackgroundAssertion()
    }

    // MARK: - Speaking

    /// Claims the audio route once and keeps it.
    ///
    /// Activating and then deactivating the session around every answer makes
    /// iOS acquire and release the route each time — and a pair of Bluetooth
    /// glasses chimes on each acquisition. One activation per app launch, never
    /// deactivated, keeps it silent. `.mixWithOthers` means holding it does not
    /// stop anything else the phone is playing.
    private func prepareAudioRoute() {
        guard !hasActivatedAudio else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.mixWithOthers, .duckOthers]
        )
        try? session.setActive(true)
        hasActivatedAudio = true
    }

    /// Queues one sentence. Routes to whatever output is active — if the
    /// glasses are paired as a Bluetooth audio device, the answer comes out of
    /// the glasses. The `audio` background mode is what lets this play with the
    /// screen locked.
    private func speak(_ text: String) {
        prepareAudioRoute()

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = TideVoiceCatalog.resolved()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterancesInFlight += 1
        phase = .speaking
        synthesizer.speak(utterance)
    }

    /// Called as each queued sentence finishes or is cancelled. The answer is
    /// only over when the stream has ended *and* nothing is still playing —
    /// speech regularly outruns the model, so either one alone is wrong.
    private func utteranceEnded() {
        utterancesInFlight = max(0, utterancesInFlight - 1)
        guard isAnswerComplete, utterancesInFlight == 0, phase == .speaking else { return }
        settle()
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
            self?.utteranceEnded()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            // A cancel caused by a new click must not tear down the session
            // that click just started — `utteranceEnded` checks the phase.
            self?.utteranceEnded()
        }
    }
}
