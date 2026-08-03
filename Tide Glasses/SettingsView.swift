//
//  SettingsView.swift
//  Tide Glasses
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var glasses: TideGlassesBluetoothManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("tide.ownerName") private var ownerName = ""
    @AppStorage("tide.autoConnect") private var autoConnect = true

    var body: some View {
        NavigationStack {
            ZStack {
                Tide.backdrop.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        panel("You") {
                            LabeledRow(title: "Name") {
                                TextField("", text: $ownerName, prompt: Text("Your name").foregroundStyle(Tide.secondaryText))
                                    .multilineTextAlignment(.trailing)
                                    .textInputAutocapitalization(.words)
                                    .foregroundStyle(Tide.primaryText)
                            }
                        }

                        panel("Glasses") {
                            LabeledRow(title: "Status") {
                                Text(glasses.isConnected ? "Connected" : "Disconnected")
                                    .foregroundStyle(glasses.isConnected ? Tide.connected : Tide.disconnected)
                            }
                            Divider().overlay(Tide.hairline)
                            LabeledRow(title: "Connect automatically") {
                                Toggle("", isOn: $autoConnect)
                                    .labelsHidden()
                                    .tint(Tide.accent)
                            }
                            if let name = glasses.discoveredName {
                                Divider().overlay(Tide.hairline)
                                LabeledRow(title: "Device") {
                                    Text(name).foregroundStyle(Tide.secondaryText)
                                }
                            }
                            if let firmware = glasses.firmwareRevision {
                                Divider().overlay(Tide.hairline)
                                LabeledRow(title: "Firmware") {
                                    Text(firmware)
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundStyle(Tide.secondaryText)
                                }
                            }
                        }

                        if glasses.isConnected {
                            Button(role: .destructive) {
                                glasses.disconnect()
                            } label: {
                                Text("Disconnect")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                                    .cardSurface()
                            }
                        }

                        Text("Photos and videos you import stay on this iPhone. Nothing is uploaded.")
                            .font(.system(size: 13))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Tide.secondaryText)
                            .padding(.top, 6)
                            .padding(.horizontal, 20)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tide.accent)
                }
            }
            .toolbarBackground(Tide.backdrop, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    private func panel<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Tide.secondaryText)
                .padding(.leading, 4)

            VStack(spacing: 12) {
                content()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .cardSurface(cornerRadius: 18)
        }
    }
}

private struct LabeledRow<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(Tide.primaryText)
            Spacer(minLength: 16)
            trailing
                .font(.system(size: 15))
        }
    }
}
