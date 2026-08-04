//
//  TideAudioPlayer.swift
//  Tide Glasses
//
//  Playback for voice recordings imported from the glasses. Purely local —
//  it only reads files already sitting in the app's album directory.
//
//  Two paths: AVAudioPlayer for normal container formats, and a raw-PCM
//  fallback for the bare/odd WAV headers small devices often write. Failures
//  are surfaced instead of swallowed.
//

import AVFoundation
import Combine
import SwiftUI

@MainActor
final class TideAudioPlayer: NSObject, ObservableObject {
    @Published private(set) var playingID: String?
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var errorText: String?

    private var player: AVAudioPlayer?
    private var engine: AVAudioEngine?
    private var engineNode: AVAudioPlayerNode?
    private var engineStart: TimeInterval = 0
    private var ticker: Timer?

    func isPlaying(_ id: String) -> Bool { playingID == id }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    func toggle(url: URL, id: String) {
        if playingID == id {
            stop()
        } else {
            play(url: url, id: id)
        }
    }

    func play(url: URL, id: String) {
        stop()
        errorText = nil

        guard FileManager.default.fileExists(atPath: url.path) else {
            errorText = "That recording is missing from the app's storage."
            return
        }

        activateSession()

        // Path 1: the glasses' own recording format — a bare stream of
        // fixed-size Opus packets that no AVFoundation reader opens.
        if TideOpusDecoder.looksLikeGlassesOpus(url: url),
           let buffer = TideOpusDecoder.decode(url: url),
           playBuffer(buffer, id: id) {
            return
        }

        // Path 2: a container format AVAudioPlayer understands.
        if let player = try? AVAudioPlayer(contentsOf: url) {
            player.delegate = self
            player.prepareToPlay()
            if player.play() {
                self.player = player
                duration = player.duration
                playingID = id
                startTicking()
                return
            }
        }

        // Path 3: treat the file as raw 16 kHz mono 16-bit PCM, skipping a
        // RIFF header if one is present. Covers the minimal WAV headers that
        // recorders like this write.
        if playRawPCM(url: url, id: id) { return }

        errorText = "This recording is in a format the player could not read."
        deactivateSession()
    }

    /// Plays an already-decoded buffer through the engine.
    private func playBuffer(_ buffer: AVAudioPCMBuffer, id: String) -> Bool {
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: buffer.format)

        do {
            try engine.start()
        } catch {
            errorText = "Audio engine could not start: \(error.localizedDescription)"
            return false
        }

        node.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { @MainActor [weak self] in self?.stop() }
        }
        node.play()

        self.engine = engine
        self.engineNode = node
        self.engineStart = Date().timeIntervalSince1970
        duration = Double(buffer.frameLength) / buffer.format.sampleRate
        playingID = id
        startTicking()
        return true
    }

    private func playRawPCM(url: URL, id: String) -> Bool {
        guard let data = try? Data(contentsOf: url), data.count > 64 else { return false }

        var offset = 0
        if data.count > 44, data.prefix(4) == Data("RIFF".utf8) {
            // Find the "data" chunk rather than assuming 44 bytes.
            if let range = data.range(of: Data("data".utf8), in: 12..<min(data.count, 4096)) {
                offset = range.upperBound + 4
            } else {
                offset = 44
            }
        }
        guard offset < data.count else { return false }

        let sampleRate = 16000.0
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else { return false }

        let payload = data.subdata(in: offset..<data.count)
        let frameCount = AVAudioFrameCount(payload.count / 2)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.int16ChannelData else { return false }

        buffer.frameLength = frameCount
        payload.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return }
            channel[0].update(from: base, count: Int(frameCount))
        }

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
        } catch {
            errorText = "Audio engine could not start: \(error.localizedDescription)"
            return false
        }

        node.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { @MainActor [weak self] in self?.stop() }
        }
        node.play()

        self.engine = engine
        self.engineNode = node
        self.engineStart = Date().timeIntervalSince1970
        duration = Double(frameCount) / sampleRate
        playingID = id
        startTicking()
        return true
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        player?.stop()
        player = nil
        engineNode?.stop()
        engine?.stop()
        engineNode = nil
        engine = nil
        playingID = nil
        currentTime = 0
        deactivateSession()
    }

    private func activateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    private func deactivateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func startTicking() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let player = self.player {
                    self.currentTime = player.currentTime
                } else if self.engine != nil {
                    self.currentTime = min(
                        self.duration,
                        Date().timeIntervalSince1970 - self.engineStart
                    )
                }
            }
        }
    }
}

extension TideAudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.stop() }
    }
}
