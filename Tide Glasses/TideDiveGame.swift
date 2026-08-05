//
//  TideDiveGame.swift
//  Tide Glasses
//
//  Ascent: a diver leaves the seabed and keeps going until they hit something.
//
//  The world is one number — altitude in metres — and everything else is drawn
//  relative to it. Obstacles hold a fixed world position and appear to fall
//  because the diver is rising past them.
//
//  Movement is deliberately in discrete lanes rather than free sliding. The
//  glasses' touch strip reports one event per swipe, so the input is already
//  discrete; lanes make the control feel exact instead of approximate.
//

import Combine
import SwiftUI

@MainActor
final class TideDiveGame: ObservableObject {
    enum Phase: Equatable {
        case ready
        case playing
        case over
    }

    struct Obstacle: Identifiable, Equatable {
        let id = UUID()
        let lane: Int
        /// Where it sits in the world, in metres from the seabed.
        let altitude: Double
        let kind: Kind

        enum Kind: CaseIterable {
            case rock
            case jellyfish
            case fish
            case bird
            case satellite

            /// What belongs at a given height. Nobody meets a satellite at
            /// forty metres.
            static func forAltitude(_ altitude: Double) -> Kind {
                switch altitude {
                case ..<250: [.rock, .fish].randomElement() ?? .rock
                case ..<650: [.jellyfish, .fish].randomElement() ?? .jellyfish
                case ..<1000: [.jellyfish, .fish].randomElement() ?? .fish
                case ..<1800: .bird
                default: .satellite
                }
            }

            var symbol: String {
                switch self {
                case .rock: "mountain.2.fill"
                case .jellyfish: "drop.fill"
                case .fish: "fish.fill"
                case .bird: "bird.fill"
                case .satellite: "antenna.radiowaves.left.and.right"
                }
            }
        }
    }

    /// Where the world changes character. Also what the banner reads.
    enum Zone: String {
        case seabed = "Seabed"
        case deep = "The deep"
        case shallows = "Shallows"
        case surface = "Surface"
        case sky = "Sky"
        case space = "Space"

        static func at(_ altitude: Double) -> Zone {
            switch altitude {
            case ..<120: .seabed
            case ..<450: .deep
            case ..<850: .shallows
            case ..<1050: .surface
            case ..<2000: .sky
            default: .space
            }
        }
    }

    static let laneCount = 5

    @Published private(set) var phase: Phase = .ready

    /// The diver's position across the lanes, 0 to laneCount - 1.
    ///
    /// Continuous rather than snapped, because the strip is a slider with
    /// seventeen steps and the world has five lanes. Rounding to a lane threw
    /// most of that resolution away — a whole swipe from level 9 to 6 left the
    /// diver in the same place, which reads as the control being broken.
    @Published private(set) var position = Double(laneCount / 2)
    @Published private(set) var altitude: Double = 0
    @Published private(set) var obstacles: [Obstacle] = []
    @Published private(set) var best = 0

    private var ticker: Timer?
    private var lastTick: TimeInterval = 0
    private var nextSpawn: Double = 0

    /// Metres per second at the seabed, and how much faster it gets.
    private static let baseSpeed: Double = 55
    private static let speedGain: Double = 0.014
    private static let topSpeed: Double = 190

    /// How far ahead obstacles are placed, and how often.
    private static let spawnAhead: Double = 620
    private static let spawnEvery: Double = 105

    /// How close counts as a hit, in metres.
    private static let hitWindow: Double = 16

    private static let bestKey = "tide.game.best"

    var zone: Zone { Zone.at(altitude) }
    var score: Int { Int(altitude) }
    var speed: Double { min(Self.topSpeed, Self.baseSpeed + altitude * Self.speedGain) }

    init() {
        best = UserDefaults.standard.integer(forKey: Self.bestKey)
    }

    // MARK: - Control

    func start() {
        position = Double(Self.laneCount / 2)
        altitude = 0
        obstacles = []
        nextSpawn = 260
        phase = .playing
        lastTick = Date.timeIntervalSinceReferenceDate
        startTicking()
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
    }

    /// Tab views can disappear without the game object being destroyed. The
    /// old screen stopped its timer on disappear but never started it again,
    /// leaving a run visibly frozen when the wearer returned to the Game tab.
    func resumeIfNeeded() {
        guard phase == .playing, ticker == nil else { return }
        lastTick = Date.timeIntervalSinceReferenceDate
        startTicking()
    }

    /// Forward on the strip goes left, backward goes right.
    func move(_ swipe: TideGlassesTouchBar.Swipe) {
        guard phase == .playing else {
            // A swipe is also how you start and restart, so the game never
            // needs the phone to be taken out of a pocket.
            start()
            return
        }
        switch swipe {
        case .forward: position = max(0, position - 1)
        case .backward: position = min(Double(Self.laneCount - 1), position + 1)
        }
    }

    /// Steers from the strip's absolute position, 0 (bottom) to 1 (top).
    ///
    /// Absolute rather than one-lane-per-change on purpose. The strip is a
    /// slider that saturates at both ends: at maximum volume no further
    /// "forward" report is ever sent, so a step-based control leaves the diver
    /// unable to go left until the wearer swipes back down. Mapping position to
    /// position has no dead zone — at the top of the strip you simply are in
    /// the leftmost lane, and moving back down works immediately.
    func steer(toward fraction: Double) {
        guard phase == .playing else { return }
        let clamped = min(max(fraction, 0), 1)
        // Up the strip means left, matching "volume up goes left".
        position = (1 - clamped) * Double(Self.laneCount - 1)
    }

    // MARK: - Loop

    private func startTicking() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.step() }
        }
        ticker = timer
        // Keep the course moving while a finger is down on the screen. A
        // default-mode timer pauses during gesture tracking and feels broken.
        RunLoop.main.add(timer, forMode: .common)
    }

    private func step() {
        guard phase == .playing else { return }

        let now = Date.timeIntervalSinceReferenceDate
        // Clamped so a stall — backgrounding, a long frame — cannot teleport
        // the diver through an obstacle.
        let delta = min(0.05, now - lastTick)
        lastTick = now

        altitude += speed * delta

        if altitude + Self.spawnAhead > nextSpawn {
            spawn(at: nextSpawn)
            nextSpawn += Self.spawnEvery
        }

        // Anything below is behind us and will never be seen again.
        obstacles.removeAll { $0.altitude < altitude - 60 }

        // Overlap rather than lane equality, now that the diver sits between
        // lanes. Slightly under half a lane, so threading a gap is possible.
        if obstacles.contains(where: {
            abs(Double($0.lane) - position) < 0.45
                && abs($0.altitude - altitude) < Self.hitWindow
        }) {
            end()
        }
    }

    /// Places obstacles in a row, always leaving at least one lane open.
    private func spawn(at altitude: Double) {
        let blocked = Int.random(in: 1...(Self.laneCount - 2))
        var lanes = Array(0..<Self.laneCount).shuffled().prefix(blocked)

        // Never seal off the lane the diver is in without a way out: leave the
        // lane they are closest to open often enough to be fair.
        let occupied = Int(position.rounded())
        if lanes.contains(occupied), Bool.random() {
            lanes = lanes.filter { $0 != occupied }
        }

        for slot in lanes {
            obstacles.append(Obstacle(
                lane: slot,
                altitude: altitude,
                kind: Obstacle.Kind.forAltitude(altitude)
            ))
        }
    }

    private func end() {
        phase = .over
        stop()
        if score > best {
            best = score
            UserDefaults.standard.set(best, forKey: Self.bestKey)
        }
    }
}
