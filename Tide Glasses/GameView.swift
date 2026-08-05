//
//  GameView.swift
//  Tide Glasses
//
//  Ascent, plus the probe that works out how to steer it.
//
//  The strip on the arm of the glasses is the intended controller. Whether it
//  reaches the phone at all is not yet known, so this screen does two things:
//  it plays with on-screen controls regardless, and it shows every unexplained
//  BLE report as it arrives so the mapping can be read off real hardware.
//

import SwiftUI

struct GameView: View {
    @EnvironmentObject private var touchBar: TideGlassesTouchBar
    @EnvironmentObject private var glasses: TideGlassesBluetoothManager
    @StateObject private var game = TideDiveGame()

    @State private var showingProbe = false

    var body: some View {
        NavigationStack {
            ZStack {
                sky.ignoresSafeArea()
                field
                overlay
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingProbe = true
                    } label: {
                        Image(systemName: "dot.radiowaves.left.and.right")
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityLabel("Touch strip probe")
                }
            }
            .sheet(isPresented: $showingProbe) {
                TouchBarProbeView()
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // A swipe starts and restarts; position steers while playing. Both
            // are needed — the strip cannot press a button.
            touchBar.onSwipe = { [weak game] swipe in
                guard let game, game.phase != .playing else { return }
                game.move(swipe)
            }
            touchBar.onPosition = { [weak game] fraction in
                game?.steer(toward: fraction)
            }
            touchBar.startWatchingSystemVolume()
        }
        .onDisappear {
            touchBar.onSwipe = nil
            touchBar.onPosition = nil
            game.stop()
        }
    }

    // MARK: - World

    /// The whole point of the climb: the colour of the world changes with it.
    private var sky: LinearGradient {
        LinearGradient(
            colors: Self.palette(for: game.altitude),
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private static func palette(for altitude: Double) -> [Color] {
        switch TideDiveGame.Zone.at(altitude) {
        case .seabed:
            [Color(red: 0.02, green: 0.09, blue: 0.16), Color(red: 0.01, green: 0.04, blue: 0.08)]
        case .deep:
            [Color(red: 0.03, green: 0.16, blue: 0.30), Color(red: 0.01, green: 0.07, blue: 0.15)]
        case .shallows:
            [Color(red: 0.10, green: 0.40, blue: 0.58), Color(red: 0.04, green: 0.20, blue: 0.36)]
        case .surface:
            [Color(red: 0.55, green: 0.80, blue: 0.88), Color(red: 0.13, green: 0.45, blue: 0.62)]
        case .sky:
            [Color(red: 0.25, green: 0.52, blue: 0.86), Color(red: 0.60, green: 0.80, blue: 0.94)]
        case .space:
            [Color(red: 0.02, green: 0.02, blue: 0.08), Color(red: 0.06, green: 0.04, blue: 0.18)]
        }
    }

    private var field: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let laneWidth = size.width / Double(TideDiveGame.laneCount)
            let diverY = size.height * 0.72
            // Screen pixels per world metre. Tuned so a spawn gap reads as a
            // comfortable gliding distance rather than a wall.
            let scale = size.height / 420

            Canvas { context, _ in
                drawParticles(in: &context, size: size)

                for obstacle in game.obstacles {
                    let y = diverY - (obstacle.altitude - game.altitude) * scale
                    guard y > -80, y < size.height + 80 else { continue }
                    let x = (Double(obstacle.lane) + 0.5) * laneWidth

                    var symbol = context.resolve(Image(systemName: obstacle.kind.symbol))
                    symbol.shading = .color(.white.opacity(0.92))
                    context.draw(symbol, at: CGPoint(x: x, y: y))
                }

                let diverX = (game.position + 0.5) * laneWidth
                var diver = context.resolve(Image(systemName: "figure.open.water.swim"))
                diver.shading = .color(.white)
                context.draw(diver, at: CGPoint(x: diverX, y: diverY))
            }
            .animation(.easeOut(duration: 0.12), value: game.position)
            // Swipe or tap anywhere: the game has to be playable without the
            // glasses, both to test it and to have it be a game at all.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 18)
                    .onEnded { value in
                        game.move(value.translation.width < 0 ? .forward : .backward)
                    }
            )
            .onTapGesture { location in
                guard game.phase == .playing else { game.start(); return }
                game.move(location.x < size.width / 2 ? .forward : .backward)
            }
        }
    }

    /// Bubbles below the surface, stars above it. Positions come from the
    /// altitude itself, so they drift downward as the diver climbs without
    /// needing any state of their own.
    private func drawParticles(in context: inout GraphicsContext, size: CGSize) {
        let isSpace = game.altitude > 1050
        let count = 26

        for index in 0..<count {
            let seed = Double((index &* 2654435761) % 1000) / 1000
            let x = seed * size.width
            let drift = isSpace ? 0.18 : 0.55
            let y = (size.height + 40)
                - ((game.altitude * drift + seed * 900).truncatingRemainder(dividingBy: size.height + 80))
            let radius = isSpace ? 1.0 + seed * 1.4 : 1.5 + seed * 3.5

            context.fill(
                Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)),
                with: .color(.white.opacity(isSpace ? 0.45 + seed * 0.5 : 0.12 + seed * 0.16))
            )
        }
    }

    // MARK: - Overlay

    private var overlay: some View {
        VStack(spacing: 0) {
            readout
            Spacer()
            if game.phase != .playing { card }
            Spacer().frame(height: game.phase == .playing ? 0 : 40)
        }
        .padding(.horizontal, 20)
    }

    private var readout: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(game.score) m")
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                Text(game.zone.rawValue)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("BEST")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.6))
                Text("\(game.best) m")
                    .font(.system(size: 16, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(.top, 6)
        .shadow(radius: 6)
    }

    private var card: some View {
        VStack(spacing: 12) {
            Text(game.phase == .over ? "You hit something" : "Ascent")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)

            if game.phase == .over {
                Text("You reached \(game.score) m — \(game.zone.rawValue.lowercased())")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.8))
            } else {
                Text("Start on the seabed and get as high as you can.")
                    .font(.system(size: 15))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.8))
            }

            VStack(spacing: 5) {
                controlHint(
                    "Slide up the strip",
                    detail: "move left",
                    icon: "arrow.left"
                )
                controlHint(
                    "Slide down the strip",
                    detail: "move right",
                    icon: "arrow.right"
                )
                controlHint(
                    "Or swipe this screen",
                    detail: "works without the glasses",
                    icon: "hand.draw"
                )
            }
            .padding(.top, 2)

            Button {
                game.start()
            } label: {
                Text(game.phase == .over ? "Go again" : "Dive in")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)

            if !glasses.isConnected {
                Text("Glasses not connected — on-screen controls still work.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            } else if touchBar.position == nil {
                Text("Swipe the strip on your glasses once to wake it up. Tap the antenna icon to check what is arriving.")
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(22)
        .frame(maxWidth: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.8)
        }
    }

    private func controlHint(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 16)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.85))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Probe

/// Shows what the glasses actually send while the strip is swiped.
///
/// This exists because the reference enum has been wrong about this firmware
/// before — it predicted an event for the back button that never appears. The
/// only reliable source is the hardware.
private struct TouchBarProbeView: View {
    @EnvironmentObject private var touchBar: TideGlassesTouchBar
    @EnvironmentObject private var glasses: TideGlassesBluetoothManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Tide.backdrop.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        instructions
                        verdict
                        readings
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Touch strip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.foregroundStyle(Tide.accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { touchBar.clearReadings() }
                        .foregroundStyle(Tide.secondaryText)
                }
            }
            .toolbarBackground(Tide.backdrop, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    private var instructions: some View {
        panel("Teach it the strip") {
            step(1, "Connect the glasses, and play some music — the strip may only do anything while audio is running.")
            step(2, "Tap Learn forward, then swipe the strip forward three or four times.")
            step(3, "Tap Learn backward, then swipe backward the same number of times.")
            step(4, "Tap Finish. Whichever byte moved one way then the other becomes the control.")

            Text("Nothing is filtered — every packet the glasses send is listed below exactly as it arrived.")
                .font(.system(size: 13))
                .foregroundStyle(Tide.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var verdict: some View {
        panel("Status") {
            row("Glasses", glasses.isConnected ? "Connected" : "Not connected",
                good: glasses.isConnected)

            if let position = touchBar.position {
                row(
                    "Strip position",
                    touchBar.rawLevel.map { level in
                        let range = touchBar.levelRange
                        return "\(level) of \(range?.upperBound ?? 16)  (\(Int(position * 100))%)"
                    } ?? "\(Int(position * 100))%",
                    good: true
                )
                ProgressView(value: position)
                    .tint(Tide.accent)
                Text("Swipe the strip — this bar should follow your finger. Up the strip is the left lane.")
                    .font(.system(size: 12))
                    .foregroundStyle(Tide.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                row("Strip position", "No volume report yet", good: false)
            }

            row("Packets seen", "\(touchBar.readings.count)", good: !touchBar.readings.isEmpty)
            row("System volume changes", "\(touchBar.systemVolumeChanges)",
                good: touchBar.systemVolumeChanges > 0)
            row("Swipes recognised", "\(touchBar.swipeCount)", good: touchBar.swipeCount > 0)

            if let mapping = touchBar.mapping {
                Text(mapping.describe)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Tide.connected)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = touchBar.learningNote {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(Tide.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            learnControls
        }
    }

    @ViewBuilder
    private var learnControls: some View {
        switch touchBar.learning {
        case .idle:
            HStack(spacing: 10) {
                Button("Learn forward") { touchBar.beginLearning(.forward) }
                    .buttonStyle(.borderedProminent)
                Button("Learn backward") { touchBar.beginLearning(.backward) }
                    .buttonStyle(.bordered)
                if touchBar.mapping != nil {
                    Button("Forget") { touchBar.forgetMapping() }
                        .foregroundStyle(Tide.disconnected)
                }
            }
            .font(.system(size: 14))

        case .forward, .backward:
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    touchBar.learning == .forward
                        ? "Swipe FORWARD now — \(touchBar.learnedForwardSamples) recorded"
                        : "Swipe BACKWARD now — \(touchBar.learnedBackwardSamples) recorded",
                    systemImage: "dot.radiowaves.left.and.right"
                )
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Tide.accent)

                Button("Finish") { touchBar.endLearning() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var readings: some View {
        panel("Every packet, unfiltered") {
            if touchBar.readings.isEmpty {
                Text("Nothing yet. If this stays empty while you swipe with music playing, the strip never reaches the phone at all.")
                    .font(.system(size: 13))
                    .foregroundStyle(Tide.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(touchBar.readings) { reading in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("cmd \(reading.label)")
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundStyle(Tide.primaryText)
                            Spacer()
                            Text(reading.at.formatted(date: .omitted, time: .standard))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Tide.secondaryText.opacity(0.7))
                        }
                        Text(reading.hex.isEmpty ? "(empty)" : reading.hex)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Tide.accent)
                    }
                    .padding(.vertical, 3)
                    Divider().overlay(Tide.hairline)
                }
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(number)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Tide.accent)
                .frame(width: 14, alignment: .leading)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Tide.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func row(_ title: String, _ value: String, good: Bool) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(Tide.primaryText)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(good ? Tide.connected : Tide.secondaryText)
        }
    }

    private func panel<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Tide.secondaryText)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .cardSurface(cornerRadius: 18)
        }
    }
}
