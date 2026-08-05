//
//  TideGlassesTouchBar.swift
//  Tide Glasses
//
//  The swipe strip on the arm of the glasses, as a game controller.
//
//  NOTHING IS FILTERED HERE. The first version of this file accepted only
//  command 0x73 and hid every event it considered "already known", which is
//  precisely the mistake that hid the back button for a whole session:
//  `button_watch.py` filtered on a prefix that matched the frame header and
//  dropped every event it was meant to find. The reports were arriving the
//  whole time. So this records every packet, whatever it is, and the mapping is
//  learned from real swipes rather than assumed from the vendor enum — which
//  has already been wrong about this firmware once.
//
//  Read-only. Like the voice session, this only ever listens; no command is
//  sent to the glasses, so the transfer path cannot be affected.
//

import AVFoundation
import Combine
import SwiftUI

@MainActor
final class TideGlassesTouchBar: ObservableObject {
    enum Swipe: Equatable {
        /// Forward on the strip — the direction that turns volume up.
        case forward
        case backward
    }

    /// One packet, kept verbatim.
    struct Reading: Identifiable {
        let id = UUID()
        let at: Date
        let command: UInt8
        let payload: Data

        var hex: String {
            payload.map { String(format: "%02X", $0) }.joined(separator: " ")
        }

        var label: String {
            String(format: "0x%02X", command)
        }
    }

    /// Which byte of which packet carries the strip's position, worked out by
    /// watching the wearer swipe rather than guessed from a reference enum.
    struct Mapping: Codable, Equatable {
        var command: UInt8
        var event: UInt8
        var byteIndex: Int
        /// True when swiping forward makes the value go up.
        var forwardIncreases: Bool

        var describe: String {
            String(
                format: "cmd 0x%02X, event 0x%02X, byte %d, forward %@",
                command, event, byteIndex, forwardIncreases ? "increases" : "decreases"
            )
        }
    }

    enum Learning: Equatable {
        case idle
        case forward
        case backward
    }

    @Published private(set) var readings: [Reading] = []
    @Published private(set) var lastSwipe: Swipe?
    @Published private(set) var swipeCount = 0

    /// Where the strip is sitting, 0 (bottom) to 1 (top), decoded from the
    /// volume report. Nil until one has arrived.
    @Published private(set) var position: Double?
    @Published private(set) var rawLevel: Int?
    @Published private(set) var levelRange: ClosedRange<Int>?

    /// Absolute position, which is what the game steers with.
    var onPosition: ((Double) -> Void)?
    @Published private(set) var mapping: Mapping?
    @Published private(set) var learning: Learning = .idle
    @Published private(set) var learnedForwardSamples = 0
    @Published private(set) var learnedBackwardSamples = 0
    @Published private(set) var learningNote: String?

    /// System volume, watched as a fallback in case the strip only reaches the
    /// phone as an audio change and never as a BLE report.
    @Published private(set) var systemVolume: Float = 0
    @Published private(set) var systemVolumeChanges = 0

    var onSwipe: ((Swipe) -> Void)?

    private static let historyLimit = 60
    private static let mappingKey = "tide.touchbar.mapping"

    /// Last value seen for each (command, event, byte) triple, so a change can
    /// be spotted without knowing in advance which one matters.
    private var lastValues: [String: Int] = [:]
    private var forwardCaptures: [(key: String, delta: Int)] = []
    private var backwardCaptures: [(key: String, delta: Int)] = []

    private var volumeObservation: NSKeyValueObservation?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.mappingKey),
           let stored = try? JSONDecoder().decode(Mapping.self, from: data) {
            mapping = stored
        }
    }

    // MARK: - Packets

    nonisolated func observe(command: UInt8, payload: Data) {
        Task { @MainActor [weak self] in
            self?.handle(command: command, payload: payload)
        }
    }

    private func handle(command: UInt8, payload: Data) {
        record(command: command, payload: payload)

        guard !payload.isEmpty else { return }
        let event = payload[0]

        // The strip, decoded from a real capture (2026-08-05). Handled before
        // the learned-mapping path because it is known rather than guessed.
        if learning == .idle, command == Self.report, event == Self.volumeEvent,
           decodeVolume(payload) {
            return
        }

        // Note every byte that moved, for every packet. Cheap, and it means the
        // learner never has to be told where to look.
        var changes: [(key: String, delta: Int)] = []
        for index in payload.indices {
            let key = Self.key(command: command, event: event, byte: index)
            let value = Int(payload[index])
            if let previous = lastValues[key], previous != value {
                changes.append((key, value - previous))
            }
            lastValues[key] = value
        }

        switch learning {
        case .forward:
            forwardCaptures.append(contentsOf: changes)
            learnedForwardSamples += changes.isEmpty ? 0 : 1
            return
        case .backward:
            backwardCaptures.append(contentsOf: changes)
            learnedBackwardSamples += changes.isEmpty ? 0 : 1
            return
        case .idle:
            break
        }

        guard let mapping,
              mapping.command == command,
              mapping.event == event,
              payload.indices.contains(mapping.byteIndex)
        else { return }

        let key = Self.key(command: command, event: event, byte: mapping.byteIndex)
        guard let delta = changes.first(where: { $0.key == key })?.delta, delta != 0 else { return }

        let wentUp = delta > 0
        emit(wentUp == mapping.forwardIncreases ? .forward : .backward)
    }

    private static func key(command: UInt8, event: UInt8, byte: Int) -> String {
        "\(command)-\(event)-\(byte)"
    }

    // MARK: - The volume report

    private static let report: UInt8 = 0x73
    private static let volumeEvent: UInt8 = 0x12

    /// Measured on the device, from a capture of the strip being swiped:
    ///
    ///     12  01 00 10 09  02 00 0F 0B  03 00 10 0A  01
    ///     │   └─ music ─┘  └─ call ──┘  └─ system ┘  └─ active mode
    ///     │      mode min max CURRENT
    ///     └─ VOLUME_CHANGE
    ///
    /// Three `[mode, min, max, current]` groups. Across every captured line
    /// only the music level moved; call sat at 0x0B and system at 0x0A
    /// throughout, including after the trailing mode byte changed from 01 to
    /// 03. So the music group is the strip.
    ///
    /// Min and max are read from the packet rather than hard-coded, since a
    /// different firmware may not use 0…16.
    private func decodeVolume(_ payload: Data) -> Bool {
        guard payload.count > 4 else { return false }

        let minimum = Int(payload[2])
        let maximum = Int(payload[3])
        let level = Int(payload[4])
        guard maximum > minimum, (minimum...maximum).contains(level) else { return false }

        rawLevel = level
        levelRange = minimum...maximum

        let fraction = Double(level - minimum) / Double(maximum - minimum)
        if let previous = position, abs(previous - fraction) > 0.0001 {
            emit(fraction > previous ? .forward : .backward)
        }
        position = fraction
        onPosition?(fraction)
        return true
    }

    private func emit(_ swipe: Swipe) {
        lastSwipe = swipe
        swipeCount += 1
        onSwipe?(swipe)
    }

    private func record(command: UInt8, payload: Data) {
        readings.insert(Reading(at: Date(), command: command, payload: payload), at: 0)
        if readings.count > Self.historyLimit {
            readings.removeLast(readings.count - Self.historyLimit)
        }
    }

    func clearReadings() {
        readings = []
        lastValues = [:]
        swipeCount = 0
        lastSwipe = nil
    }

    // MARK: - Learning the mapping

    func beginLearning(_ direction: Learning) {
        learning = direction
        learningNote = nil
        switch direction {
        case .forward:
            forwardCaptures = []
            learnedForwardSamples = 0
        case .backward:
            backwardCaptures = []
            learnedBackwardSamples = 0
        case .idle:
            break
        }
    }

    /// Stops capturing and, once both directions have been seen, works out
    /// which byte actually tracks the strip.
    func endLearning() {
        learning = .idle
        guard !forwardCaptures.isEmpty, !backwardCaptures.isEmpty else {
            learningNote = forwardCaptures.isEmpty && backwardCaptures.isEmpty
                ? "Nothing changed while you swiped. The strip may not reach the phone at all."
                : "Only one direction was recorded. Learn both to work out which way is which."
            return
        }

        // The right byte is the one that consistently moves one way on a
        // forward swipe and the other way on a backward swipe.
        var scores: [String: (forward: Int, backward: Int)] = [:]
        for capture in forwardCaptures {
            scores[capture.key, default: (0, 0)].forward += capture.delta > 0 ? 1 : -1
        }
        for capture in backwardCaptures {
            scores[capture.key, default: (0, 0)].backward += capture.delta > 0 ? 1 : -1
        }

        let candidates = scores
            .filter { $0.value.forward != 0 && $0.value.backward != 0 }
            // Opposite signs: it went one way, then the other.
            .filter { ($0.value.forward > 0) != ($0.value.backward > 0) }
            .sorted { abs($0.value.forward) + abs($0.value.backward) > abs($1.value.forward) + abs($1.value.backward) }

        guard let best = candidates.first,
              let parsed = Self.parse(key: best.key)
        else {
            learningNote = "Something arrived, but no single byte moved one way then the other. Try again with three clear swipes each way."
            return
        }

        let learned = Mapping(
            command: parsed.command,
            event: parsed.event,
            byteIndex: parsed.byte,
            forwardIncreases: best.value.forward > 0
        )
        mapping = learned
        learningNote = "Learned: \(learned.describe)"

        if let data = try? JSONEncoder().encode(learned) {
            UserDefaults.standard.set(data, forKey: Self.mappingKey)
        }
    }

    func forgetMapping() {
        mapping = nil
        learningNote = nil
        forwardCaptures = []
        backwardCaptures = []
        learnedForwardSamples = 0
        learnedBackwardSamples = 0
        UserDefaults.standard.removeObject(forKey: Self.mappingKey)
    }

    private static func parse(key: String) -> (command: UInt8, event: UInt8, byte: Int)? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let command = UInt8(exactly: parts[0]),
              let event = UInt8(exactly: parts[1])
        else { return nil }
        return (command, event, parts[2])
    }

    // MARK: - System volume fallback

    /// Watches the output volume without touching the audio session.
    ///
    /// Observation only, deliberately. The voice path claims the session once
    /// at launch and never releases it, because re-acquiring a Bluetooth route
    /// chimes audibly; taking it over here would bring that noise back.
    func startWatchingSystemVolume() {
        guard volumeObservation == nil else { return }
        let session = AVAudioSession.sharedInstance()
        systemVolume = session.outputVolume

        volumeObservation = session.observe(\.outputVolume, options: [.new]) {
            [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard abs(value - self.systemVolume) > 0.0001 else { return }
                let wentUp = value > self.systemVolume
                self.systemVolume = value
                self.systemVolumeChanges += 1

                // Only steers when nothing better has been learned.
                if self.mapping == nil, self.learning == .idle {
                    self.emit(wentUp ? .forward : .backward)
                }
            }
        }
    }

    func stopWatchingSystemVolume() {
        volumeObservation?.invalidate()
        volumeObservation = nil
    }
}
