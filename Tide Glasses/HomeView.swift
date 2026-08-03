//
//  HomeView.swift
//  Tide Glasses
//

import Combine
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var glasses: TideGlassesBluetoothManager
    @EnvironmentObject private var media: TideGlassesMediaTransferManager
    @AppStorage("tide.ownerName") private var ownerName = ""
    @State private var showSettings = false

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

                    hero
                        .padding(.top, 4)

                    statusStack
                        .padding(.horizontal, 20)
                        .padding(.top, 4)

                    actionGrid
                        .padding(.horizontal, 20)
                        .padding(.top, 22)
                }
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(glasses)
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

    private var statusStack: some View {
        HStack(spacing: 10) {
            GlassPill {
                Circle()
                    .fill(glasses.isConnected ? Tide.connected : Tide.disconnected)
                    .frame(width: 8, height: 8)

                Text(statusTitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Tide.primaryText)
            }

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
            .buttonStyle(.plain)
            .disabled(!glasses.canRefreshBattery)
        }
        .frame(maxWidth: .infinity)
    }

    private var statusTitle: String {
        if glasses.isConnected { return "Connected" }
        if glasses.isConnecting { return "Connecting" }
        if glasses.isScanning { return "Searching" }
        return "Disconnected"
    }

    private var actionGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
            spacing: 14
        ) {
            ActionTile(
                title: "Import photos",
                systemImage: "square.and.arrow.down",
                enabled: glasses.isConnected
            ) {
                media.openGallery()
            }

            ActionTile(
                title: glasses.isTakingPhoto ? "Capturing…" : "Take a photo",
                systemImage: "camera",
                enabled: glasses.canTakePhoto
            ) {
                glasses.takePhoto()
            }

            ActionTile(
                title: glasses.isConnected ? "Disconnect" : "Connect",
                systemImage: glasses.isConnected ? "bolt.horizontal" : "antenna.radiowaves.left.and.right",
                enabled: glasses.isConnected || glasses.canScan
            ) {
                if glasses.isConnected {
                    glasses.disconnect()
                } else {
                    glasses.startScan()
                }
            }

            ActionTile(title: "Settings", systemImage: "gearshape", enabled: true) {
                showSettings = true
            }
        }
    }
}

private struct ActionTile: View {
    let title: String
    let systemImage: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(Tide.accent)
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Tide.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .cardSurface(cornerRadius: 20)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}
