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
                world.ignoresSafeArea()
                playSurface
                overlay
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingProbe = true
                    } label: {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 38, height: 38)
                            .background(.black.opacity(0.34), in: Circle())
                            .overlay {
                                Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1)
                            }
                    }
                    .foregroundStyle(.white)
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
            game.resumeIfNeeded()
        }
        .onDisappear {
            touchBar.onSwipe = nil
            touchBar.onPosition = nil
            game.stop()
        }
    }

    // MARK: - World

    private var world: some View {
        ZStack {
            LinearGradient(
                colors: Self.palette(for: game.zone),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [Self.zoneGlow(for: game.zone), .clear],
                center: .topTrailing,
                startRadius: 10,
                endRadius: 480
            )

            TideAscentScene(
                altitude: game.altitude,
                position: game.position,
                obstacles: game.obstacles,
                zone: game.zone,
                phase: game.phase
            )
            .opacity(game.phase == .ready ? 0.08 : 1)

            if game.phase == .ready {
                Image("TideAscentSplash")
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity.combined(with: .scale(scale: 1.035)))
                    .overlay {
                        LinearGradient(
                            colors: [
                                .black.opacity(0.08),
                                .clear,
                                .black.opacity(0.14),
                                .black.opacity(0.7)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
            }

            LinearGradient(
                colors: [.black.opacity(0.16), .clear, .black.opacity(game.phase == .playing ? 0.24 : 0.46)],
                startPoint: .top,
                endPoint: .bottom
            )

            if game.phase == .over {
                Color(red: 0.08, green: 0.01, blue: 0.08)
                    .opacity(0.3)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.48), value: game.phase)
        .animation(.easeInOut(duration: 0.8), value: game.zone.rawValue)
        .allowsHitTesting(false)
    }

    private static func palette(for zone: TideDiveGame.Zone) -> [Color] {
        switch zone {
        case .seabed:
            [Color(red: 0.01, green: 0.03, blue: 0.11), Color(red: 0.02, green: 0.2, blue: 0.28), Color(red: 0.1, green: 0.03, blue: 0.2)]
        case .deep:
            [Color(red: 0.01, green: 0.08, blue: 0.2), Color(red: 0.02, green: 0.33, blue: 0.46), Color(red: 0.15, green: 0.05, blue: 0.28)]
        case .shallows:
            [Color(red: 0.04, green: 0.34, blue: 0.5), Color(red: 0.04, green: 0.65, blue: 0.65), Color(red: 0.02, green: 0.18, blue: 0.36)]
        case .surface:
            [Color(red: 0.72, green: 0.9, blue: 0.95), Color(red: 0.07, green: 0.58, blue: 0.75), Color(red: 0.02, green: 0.3, blue: 0.53)]
        case .sky:
            [Color(red: 0.18, green: 0.36, blue: 0.84), Color(red: 0.26, green: 0.76, blue: 0.96), Color(red: 0.92, green: 0.45, blue: 0.48)]
        case .space:
            [Color(red: 0.01, green: 0.01, blue: 0.08), Color(red: 0.1, green: 0.04, blue: 0.28), Color(red: 0.33, green: 0.04, blue: 0.36)]
        }
    }

    private static func zoneGlow(for zone: TideDiveGame.Zone) -> Color {
        switch zone {
        case .seabed, .deep: Color(red: 0.24, green: 0.86, blue: 1).opacity(0.46)
        case .shallows, .surface: Color(red: 0.18, green: 1, blue: 0.77).opacity(0.48)
        case .sky: Color(red: 1, green: 0.49, blue: 0.18).opacity(0.55)
        case .space: Color(red: 0.94, green: 0.12, blue: 0.76).opacity(0.5)
        }
    }

    /// Invisible full-screen controls. This remains separate from the renderer
    /// so the exact swipe/tap mechanics are unchanged by the 3D presentation.
    private var playSurface: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 18)
                        .onEnded { value in
                            let horizontal = value.translation.width
                            let vertical = value.translation.height
                            if abs(horizontal) >= abs(vertical) {
                                game.move(horizontal < 0 ? .forward : .backward)
                            } else {
                                // Match the physical strip: up moves left and
                                // down moves right. Horizontal swipes remain
                                // available because they are natural on a phone.
                                game.move(vertical < 0 ? .forward : .backward)
                            }
                        }
                )
                .onTapGesture { location in
                    guard game.phase == .playing else { game.start(); return }
                    game.move(location.x < geometry.size.width / 2 ? .forward : .backward)
                }
        }
    }

    // MARK: - Overlay

    private var overlay: some View {
        VStack(spacing: 0) {
            if game.phase != .ready {
                readout
            }
            Spacer()
            if game.phase != .playing {
                card
                    // iOS 26's floating tab bar overlays the tab content. This
                    // explicit clearance keeps every control above it on both
                    // the 15 Pro and the simulator.
                    .padding(.bottom, 96)
            }
        }
        .padding(.horizontal, 16)
        .animation(.spring(response: 0.48, dampingFraction: 0.83), value: game.phase)
        .allowsHitTesting(true)
    }

    private var readout: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("ALTITUDE")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .tracking(1.8)
                    .foregroundStyle(.white.opacity(0.58))
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(game.score)")
                        .font(.system(size: 29, weight: .black, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Text("M")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(Color(red: 0.38, green: 0.94, blue: 1))
                }
                .foregroundStyle(.white)
                Text(game.zone.rawValue)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(hudPanel)

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color(red: 1, green: 0.7, blue: 0.12))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Int(game.speed)) M/S")
                        .font(.system(size: 13, weight: .black, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                    Text("BEST \(game.best) M")
                        .font(.system(size: 9, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.58))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(hudPanel)
        }
        .padding(.top, 2)
    }

    private var hudPanel: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.black.opacity(0.42))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.34), .white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.28), radius: 14, y: 8)
    }

    private var card: some View {
        VStack(spacing: 11) {
            if game.phase == .over {
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(Color(red: 1, green: 0.27, blue: 0.14))
                        .frame(width: 26, height: 3)
                    Text(game.score == game.best && game.score > 0 ? "NEW RECORD" : "RUN ENDED")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .tracking(2.2)
                        .foregroundStyle(game.score == game.best && game.score > 0 ? Color.yellow : .white.opacity(0.72))
                    Rectangle()
                        .fill(Color(red: 1, green: 0.27, blue: 0.14))
                        .frame(width: 26, height: 3)
                }

                HStack(alignment: .lastTextBaseline, spacing: 5) {
                    Text("\(game.score)")
                        .font(.system(size: 54, weight: .black, design: .rounded).monospacedDigit())
                        .tracking(-2)
                    Text("M")
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .foregroundStyle(Color(red: 0.32, green: 0.94, blue: 1))
                }
                .foregroundStyle(.white)

                Text("You made it to \(game.zone.rawValue.lowercased()). Best run: \(game.best) m.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
            } else {
                VStack(spacing: -2) {
                    Text("ASCENT")
                        .font(.system(size: 32, weight: .black, design: .rounded).italic())
                        .tracking(-1.2)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, Color(red: 0.36, green: 0.96, blue: 1)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    Text("Outrun the ocean")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .tracking(2)
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.62))
                }

                Text("Thread five lanes from the seabed to orbit. Every metre gets faster.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
            }

            HStack(spacing: 0) {
                controlHint("SLIDE UP", detail: "LEFT", icon: "arrow.left")
                Divider()
                    .overlay(.white.opacity(0.16))
                    .frame(height: 34)
                controlHint("SLIDE DOWN", detail: "RIGHT", icon: "arrow.right")
            }
            .padding(.vertical, 9)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            Button {
                game.start()
            } label: {
                HStack(spacing: 9) {
                    Text(game.phase == .over ? "RUN IT BACK" : "LAUNCH RUN")
                    Image(systemName: "chevron.up.2")
                        .font(.system(size: 12, weight: .black))
                }
                .font(.system(size: 15, weight: .black, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    LinearGradient(
                        colors: [Color(red: 1, green: 0.2, blue: 0.11), Color(red: 1, green: 0.48, blue: 0.06)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                )
                .shadow(color: Color(red: 1, green: 0.22, blue: 0.08).opacity(0.42), radius: 18, y: 8)
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

            if !glasses.isConnected {
                Label("Tap either side or swipe to steer", systemImage: "iphone.gen3")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.56))
            } else if touchBar.position == nil {
                Label("Swipe your glasses strip once to wake it", systemImage: "eyeglasses")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.56))
            } else {
                Label("Glasses control online", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.35, green: 1, blue: 0.73).opacity(0.82))
            }
        }
        .padding(16)
        .frame(maxWidth: 420)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.34), Color.cyan.opacity(0.14), .white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(0.55), radius: 28, y: 16)
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    private func controlHint(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color(red: 0.35, green: 0.94, blue: 1))
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity)
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
