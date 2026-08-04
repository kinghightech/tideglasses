//
//  SettingsView.swift
//  Tide Glasses
//

import AVFoundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var glasses: TideGlassesBluetoothManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("tide.ownerName") private var ownerName = ""
    @AppStorage("tide.autoConnect") private var autoConnect = true
    @AppStorage("tide.voiceTrigger") private var voiceTrigger = true
    @AppStorage("tide.voiceVision") private var voiceVision = true
    @AppStorage(TideVoiceCatalog.preferenceKey) private var voiceIdentifier = ""

    @State private var previewSynthesizer = AVSpeechSynthesizer()
    private var voices: [TideVoiceCatalog.Option] { TideVoiceCatalog.available() }

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

                        panel("Assistant") {
                            LabeledRow(title: "Back button starts AI") {
                                Toggle("", isOn: $voiceTrigger)
                                    .labelsHidden()
                                    .tint(Tide.accent)
                            }
                            Divider().overlay(Tide.hairline)
                            LabeledRow(title: "Send a photo with questions") {
                                Toggle("", isOn: $voiceVision)
                                    .labelsHidden()
                                    .tint(Tide.accent)
                            }
                            Text("Lets Tide see what you are looking at. Adds a couple of seconds to each answer.")
                                .font(.system(size: 13))
                                .foregroundStyle(Tide.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Divider().overlay(Tide.hairline)
                            LabeledRow(title: "Voice") {
                                Picker("", selection: $voiceIdentifier) {
                                    // Empty tag means "track the best installed
                                    // voice", so downloading a better one in iOS
                                    // Settings takes effect with no fiddling here.
                                    Text("Automatic").tag("")
                                    ForEach(voices) { voice in
                                        Text("\(voice.name) · \(voice.qualityLabel)")
                                            .tag(voice.identifier)
                                    }
                                }
                                .labelsHidden()
                                .tint(Tide.secondaryText)
                            }
                            if voiceIdentifier.isEmpty, let best = voices.first {
                                LabeledRow(title: "Using") {
                                    Text("\(best.name) · \(best.qualityLabel)")
                                        .foregroundStyle(Tide.secondaryText)
                                }
                            }
                            Divider().overlay(Tide.hairline)
                            Button(action: previewVoice) {
                                HStack(spacing: 7) {
                                    Image(systemName: "play.circle.fill")
                                    Text("Hear this voice")
                                }
                                .font(.system(size: 15))
                                .foregroundStyle(Tide.accent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            if TideVoiceCatalog.isStuckOnStandardQuality {
                                // Apple renamed "Spoken Content" to "Read & Speak" in iOS 26.
                                Text("Only the standard voice is installed. For a far more natural one, open iOS Settings → Accessibility → Read & Speak → Voices → English and tap the cloud beside a Premium voice such as Ava or Zoe.")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Tide.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
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
            .onAppear {
                // Fall back to Automatic if a previously chosen voice has been
                // uninstalled. Otherwise leave the choice — including the
                // empty "Automatic" default — exactly as it is.
                if !voiceIdentifier.isEmpty,
                   !voices.contains(where: { $0.identifier == voiceIdentifier }) {
                    voiceIdentifier = ""
                }
            }
            .onDisappear { previewSynthesizer.stopSpeaking(at: .immediate) }
        }
        .preferredColorScheme(.dark)
    }

    /// Speaks a sample through the currently selected voice, on the same route
    /// the assistant uses — so if the glasses are the audio output, it comes
    /// out of the glasses.
    private func previewVoice() {
        previewSynthesizer.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(
            string: "Hello. This is how I will read your answers back to you."
        )
        utterance.voice = voiceIdentifier.isEmpty
            ? TideVoiceCatalog.resolved()
            : AVSpeechSynthesisVoice(identifier: voiceIdentifier)
        previewSynthesizer.speak(utterance)
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
