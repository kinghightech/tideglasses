//
//  HomeView.swift
//  Tide Glasses
//

import Combine
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var glasses: TideGlassesBluetoothManager
    @EnvironmentObject private var media: TideGlassesMediaTransferManager
    @EnvironmentObject private var memory: TideMemoryStore
    @AppStorage("tide.ownerName") private var ownerName = ""
    @State private var showSettings = false
    @State private var findPhase: TideFindPhase = .idle
    @State private var findResetTask: Task<Void, Never>?

    /// Battery refreshes on its own while the home screen is visible.
    private let batteryTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var firstName: String {
        ownerName.split(separator: " ").first.map(String.init) ?? ownerName
    }

    private var isCharging: Bool { glasses.isCharging == true }

    var body: some View {
        ZStack {
            Tide.backdrop.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.horizontal, 20)

                    // The glasses need room to breathe on both sides — cramped
                    // against the greeting above and the pills below, the whole
                    // screen reads as one dense block.
                    hero
                        .padding(.top, 18)

                    statusStack
                        .padding(.horizontal, 20)
                        .padding(.top, 22)

                    captureRow
                        .padding(.horizontal, 20)
                        .padding(.top, 28)

                    actionGrid
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                }
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(glasses)
                .environmentObject(memory)
        }
        .onAppear(perform: refreshBattery)
        .onReceive(batteryTimer) { _ in refreshBattery() }
        .onChange(of: glasses.isConnected) { _, connected in
            if connected { refreshBattery() }
        }
    }

    private func refreshBattery() {
        guard glasses.canRefreshBattery else { return }
        glasses.refreshBattery()
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Tide.greeting())
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Tide.secondaryText)
                Text(firstName.isEmpty ? "Welcome" : firstName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Tide.primaryText)
            }

            Spacer()

            Button {
                showSettings = true
            } label: {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(Tide.secondaryText)
            }
            .accessibilityLabel("Settings")
        }
    }

    /// The glasses, as large as the screen allows. GeometryReader keeps the
    /// oversized image from widening the page — it can hang off the edge
    /// without pushing any other content sideways.
    private var hero: some View {
        GeometryReader { geometry in
            // Both dimensions must be set: giving only a width lets the
            // container's height cap the image and quietly shrink it.
            let size = geometry.size.width * 1.26
            Image(isCharging ? "GlassesHomeCharging" : "GlassesHomeNormal")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .position(x: geometry.size.width * 0.60, y: geometry.size.height / 2)
                .opacity(glasses.isConnected ? 1 : 0.6)
                .animation(.easeInOut(duration: 0.35), value: isCharging)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(height: 250)
    }

    // MARK: - Status

    /// Status on the left, battery on the right. The status pill is also the
    /// connection control now — tapping "Connected" drops the link, tapping
    /// "Disconnected" goes looking for the glasses. That replaces the tile that
    /// used to do it, so there is one obvious place to manage the connection
    /// instead of two.
    private var statusStack: some View {
        HStack(spacing: 10) {
            Button(action: toggleConnection) {
                GlassPill {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)

                    Text(statusTitle)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Tide.primaryText)
                }
            }
            .buttonStyle(PressableSurface())
            .disabled(!canToggleConnection)
            .accessibilityLabel(statusTitle)
            .accessibilityHint(
                glasses.isConnected ? "Double tap to disconnect" : "Double tap to connect"
            )

            Button {
                glasses.refreshBattery()
            } label: {
                GlassPill {
                    Image(systemName: Tide.batterySymbol(level: glasses.batteryLevel, charging: isCharging))
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(isCharging ? Tide.connected : Tide.primaryText)

                    if glasses.isRefreshingBattery {
                        Text("…")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Tide.secondaryText)
                    } else if let level = glasses.batteryLevel {
                        Text("\(level)%")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Tide.primaryText)
                            .contentTransition(.numericText())
                            .animation(.snappy, value: level)
                    } else {
                        Text("—")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Tide.secondaryText)
                    }
                }
            }
            .buttonStyle(PressableSurface())
            .disabled(!glasses.canRefreshBattery)
            .accessibilityLabel("Battery")
        }
        .frame(maxWidth: .infinity)
    }

    private var statusTitle: String {
        if glasses.isConnected { return "Connected" }
        if glasses.isConnecting { return "Connecting" }
        if glasses.isScanning { return "Searching" }
        return "Disconnected"
    }

    private var statusColor: Color {
        if glasses.isConnected { return Tide.connected }
        if glasses.isConnecting || glasses.isScanning { return Tide.caution }
        return Tide.disconnected
    }

    /// Mid-connection there is nothing useful to ask for, so the pill goes inert
    /// rather than offering an action that would be ignored.
    private var canToggleConnection: Bool {
        glasses.isConnected || glasses.canScan
    }

    private func toggleConnection() {
        if glasses.isConnected {
            glasses.disconnect()
        } else {
            glasses.startScan()
        }
    }

    // MARK: - Actions

    /// The three capture actions, compact and side by side.
    ///
    /// Only the photo one does anything. `photoMode` (`0x41` payload
    /// `02 01 01`) is the single capture byte that has been proven on the
    /// device; there is no known mode value for video, and audio recordings are
    /// started by holding the button on the glasses — the app has only ever
    /// imported the files afterwards. Guessing a mode byte is how the front
    /// button got broken once already.
    ///
    /// So video and audio are drawn as ordinary buttons and simply do nothing
    /// when tapped. They are placeholders for the layout, deliberately: wiring
    /// them up is a three-line change once the bytes are captured off the Mac
    /// rig, and nothing here should be sending unproven commands in the
    /// meantime.
    private var captureRow: some View {
        HStack(spacing: 14) {
            CaptureTile(
                title: glasses.isTakingPhoto ? "Capturing…" : "Take a photo",
                systemImage: "camera",
                enabled: glasses.canTakePhoto
            ) {
                glasses.takePhoto()
            }

            CaptureTile(title: "Take a video", systemImage: "video") {}

            CaptureTile(title: "Record audio", systemImage: "mic") {}
        }
    }

    private var actionGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
            spacing: 14
        ) {
            ActionTile(
                title: "Import photos",
                subtitle: "From your glasses",
                systemImage: "square.and.arrow.down",
                enabled: glasses.isConnected
            ) {
                media.openGallery()
            }

            ActionTile(
                title: "Find my glasses",
                subtitle: findSubtitle,
                systemImage: "speaker.wave.3",
                enabled: glasses.isConnected
            ) {
                playFindSound()
            }

            ActionTile(
                title: "Settings",
                subtitle: "Voice, memory, device",
                systemImage: "gearshape",
                enabled: true
            ) {
                showSettings = true
            }
        }
        .sensoryFeedback(trigger: findPhase) { _, phase in
            phase == .beeping ? .impact(weight: .light) : nil
        }
    }

    private var findSubtitle: String {
        switch findPhase {
        case .idle: "Play a sound"
        case .beeping: "Beeping…"
        case .failed: "Not ready"
        }
    }

    /// The glasses beep for a moment and stop on their own, so there is nothing
    /// to cancel — the label just needs to fall back once the sound is over.
    private func playFindSound() {
        findPhase = glasses.playFindDeviceSound() ? .beeping : .failed
        guard let duration = findPhase.duration else { return }

        findResetTask?.cancel()
        findResetTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            findPhase = .idle
        }
    }
}

// MARK: - Pieces

/// Narrow tile for the three-across capture row. Centred, because three
/// left-aligned labels at this width read as a ragged column rather than a set.
private struct CaptureTile: View {
    let title: String
    let systemImage: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Tide.accent)

                Spacer(minLength: 12)

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Tide.primaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .padding(.horizontal, 8)
            .padding(.vertical, 14)
            .cardSurface(cornerRadius: 18)
        }
        .buttonStyle(PressableSurface())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

private struct ActionTile: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Tide.accent)
                    .frame(height: 24, alignment: .leading)

                Spacer(minLength: 16)

                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tide.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Tide.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .padding(16)
            .cardSurface(cornerRadius: 20)
        }
        .buttonStyle(PressableSurface())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// A press that is felt rather than announced. `.plain` alone gives no feedback
/// at all, which on a card this large reads as a dead tap.
private struct PressableSurface: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
