//
//  ContentView.swift
//  Tide Glasses
//
//  Created by Aahish Abbani on 8/2/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var glasses: TideGlassesBluetoothManager
    @EnvironmentObject private var media: TideGlassesMediaTransferManager
    @State private var selectedTab = 0
    @State private var hasStartedAutomatedWiFiTest = false

    private var isAutomatedWiFiTest: Bool {
        ProcessInfo.processInfo.arguments.contains("--tide-wifi-test")
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            GlassesDashboardView()
                .tag(0)
                .tabItem {
                    Label("Glasses", systemImage: "eyeglasses")
                }

            GalleryView()
                .tag(1)
                .tabItem {
                    Label("Gallery", systemImage: "photo.on.rectangle.angled")
                }
        }
        .onChange(of: glasses.canRequestWiFiTransfer) { _, isReady in
            guard isAutomatedWiFiTest,
                  isReady,
                  !hasStartedAutomatedWiFiTest else { return }

            hasStartedAutomatedWiFiTest = true
            selectedTab = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                media.openGallery()
            }
        }
    }
}

private struct GlassesDashboardView: View {
    @EnvironmentObject private var glasses: TideGlassesBluetoothManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    connectionCard

                    if glasses.discoveredName != nil {
                        deviceCard
                    }

                    if glasses.isConnected {
                        batteryCard
                        cameraCard
                        identityCard
                        compatibilityCard
                        safetyCard
                    }
                }
                .frame(maxWidth: 680)
                .padding()
            }
            .background(Color.secondary.opacity(0.08))
            .navigationTitle("Tide Glass")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Live glasses status", systemImage: "eyeglasses")
                .font(.title2.bold())

            Text("Connect to your AIMB-G2, verify its HeyCyan services, and monitor battery and charging state.")
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Circle()
                    .fill(glasses.isConnected ? .green : glasses.isScanning ? .orange : .secondary)
                    .frame(width: 9, height: 9)
                Text(glasses.status)
                    .font(.subheadline.weight(.medium))
            }
        }
        .cardStyle()
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connection")
                .font(.headline)

            LabeledContent("Mac/iPhone Bluetooth", value: glasses.bluetoothStateDescription)

            HStack {
                Button {
                    glasses.startScan()
                } label: {
                    Label(glasses.isScanning ? "Searching…" : "Search for glasses", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!glasses.canScan || glasses.isScanning || glasses.isConnected)

                if glasses.isScanning {
                    Button("Stop") {
                        glasses.stopScan()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                if glasses.isConnected {
                    Button("Disconnect", role: .destructive) {
                        glasses.disconnect()
                    }
                }
            }

            if let error = glasses.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .cardStyle()
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Discovered glasses")
                .font(.headline)

            LabeledContent("Name", value: glasses.discoveredName ?? "Unknown")
            if let rssi = glasses.rssi {
                LabeledContent("Signal", value: "\(rssi) dBm")
            }

            if !glasses.isConnected {
                Button {
                    glasses.connect()
                } label: {
                    Label("Connect", systemImage: "link")
                }
                .buttonStyle(.borderedProminent)
                .disabled(glasses.isConnecting)
            }
        }
        .cardStyle()
    }

    private var batteryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Glasses battery")
                        .font(.headline)
                    Text(batterySubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: glasses.isCharging == true ? "bolt.fill" : batterySymbol)
                    .font(.title2)
                    .foregroundStyle(batteryColor)
            }

            if let level = glasses.batteryLevel {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(level)%")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    if glasses.isCharging == true {
                        Text("Charging")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    Spacer()
                }

                ProgressView(value: Double(level), total: 100)
                    .tint(batteryColor)
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(glasses.isRefreshingBattery ? "Requesting battery status…" : "Waiting for battery status…")
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                glasses.refreshBattery()
            } label: {
                Label(glasses.isRefreshingBattery ? "Refreshing…" : "Refresh battery", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(!glasses.canRefreshBattery)
        }
        .cardStyle()
    }

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Device identity")
                .font(.headline)

            LabeledContent("Hardware", value: glasses.hardwareRevision ?? "Reading…")
            LabeledContent("Firmware", value: glasses.firmwareRevision ?? "Reading…")
            LabeledContent("Services found", value: "\(glasses.serviceUUIDs.count)")
        }
        .cardStyle()
    }

    private var cameraCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Camera")
                        .font(.headline)
                    Text(photoSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: glasses.lastPhotoCapture == nil ? "camera" : "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(glasses.lastPhotoCapture == nil ? Color.secondary : Color.green)
            }

            Button {
                glasses.takePhoto()
            } label: {
                Label(glasses.isTakingPhoto ? "Taking photo…" : "Take photo", systemImage: "camera.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!glasses.canTakePhoto)

            Text("This captures one full-quality photo onto the glasses. Open the Gallery tab to view and import it over Wi-Fi.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let reply = glasses.lastPhotoProtocolReply {
                LabeledContent("Glasses reply", value: reply)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .cardStyle()
    }

    private var compatibilityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("HeyCyan compatibility")
                    .font(.headline)
                Spacer()
                Text(glasses.isCompatibilityConfirmed ? "CONFIRMED" : "CHECKING")
                    .font(.caption.bold())
                    .foregroundStyle(glasses.isCompatibilityConfirmed ? .green : .orange)
            }

            CompatibilityRow(
                title: "AIMB-G2 identity",
                detail: glasses.discoveredName ?? "Waiting for name",
                passed: glasses.hasCompatibleName
            )
            CompatibilityRow(
                title: "Main service",
                detail: "AE30 command and data map",
                passed: glasses.hasMainServiceMap
            )
            CompatibilityRow(
                title: "HeyCyan small-data channel",
                detail: "6E40FFF0 / 6E400002 / 6E400003",
                passed: glasses.hasSmallDataChannel
            )
            CompatibilityRow(
                title: "Serial data channel",
                detail: "DE5BF728 / DE5BF72A / DE5BF729",
                passed: glasses.hasSerialDataChannel
            )
        }
        .cardStyle()
    }

    private var safetyCard: some View {
        Label {
            Text("Tide Glass enables battery status, one-photo capture, and Wi-Fi media import. Deletion, video, audio, restart, firmware, and device-setting commands remain disabled.")
        } icon: {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.blue)
        }
        .font(.footnote)
        .cardStyle()
    }

    private var batterySubtitle: String {
        guard let updated = glasses.lastBatteryUpdate else {
            return "Live status from the HeyCyan battery channel"
        }
        return "Updated \(updated.formatted(date: .omitted, time: .shortened))"
    }

    private var photoSubtitle: String {
        guard let captured = glasses.lastPhotoCapture else {
            return glasses.photoStatus
        }
        return "Captured at \(captured.formatted(date: .omitted, time: .shortened))"
    }

    private var batteryColor: Color {
        if glasses.isCharging == true { return .green }
        guard let level = glasses.batteryLevel else { return .secondary }
        if level <= 20 { return .red }
        if level <= 40 { return .orange }
        return .green
    }

    private var batterySymbol: String {
        guard let level = glasses.batteryLevel else { return "battery.0percent" }
        switch level {
        case 76...100: return "battery.100percent"
        case 51...75: return "battery.75percent"
        case 26...50: return "battery.50percent"
        case 1...25: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

private struct CompatibilityRow: View {
    let title: String
    let detail: String
    let passed: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: passed ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(passed ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 0.5)
            }
    }
}
