//
//  OnboardingView.swift
//  Tide Glasses
//

import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var glasses: TideGlassesBluetoothManager
    @AppStorage("tide.ownerName") private var ownerName = ""
    @AppStorage("tide.onboarded") private var onboarded = false

    @State private var step = 0
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        ZStack {
            Tide.backdrop.ignoresSafeArea()

            VStack(spacing: 0) {
                if step == 0 {
                    nameStep.transition(.asymmetric(
                        insertion: .opacity,
                        removal: .opacity.combined(with: .offset(x: -40))
                    ))
                } else {
                    pairingStep.transition(.opacity.combined(with: .offset(x: 40)))
                }
            }
            .animation(.smooth(duration: 0.45), value: step)
        }
        .preferredColorScheme(.dark)
        .onChange(of: glasses.isConnected) { _, connected in
            guard connected, step == 1 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                withAnimation(.smooth) { onboarded = true }
            }
        }
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            Text("What should we\ncall you?")
                .font(.system(size: 36, weight: .bold))
                .tracking(-0.8)
                .foregroundStyle(Tide.primaryText)
                .padding(.top, 12)

            Text("Used to greet you on your home screen. It stays on this iPhone.")
                .font(.system(size: 15))
                .foregroundStyle(Tide.secondaryText)
                .padding(.top, 10)

            TextField("", text: $draftName, prompt: Text("Your name").foregroundStyle(Tide.secondaryText))
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Tide.primaryText)
                .focused($nameFocused)
                .submitLabel(.continue)
                .onSubmit(advance)
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
                .cardSurface(cornerRadius: 18)
                .padding(.top, 28)

            Spacer()

            Button(action: advance) {
                Text("Continue")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Tide.backdrop)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(Tide.primaryText, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            }
            .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(draftName.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 28)
        .onAppear {
            draftName = ownerName
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { nameFocused = true }
        }
    }

    private var pairingStep: some View {
        VStack(spacing: 0) {
            Spacer()

            Image("GlassesHomeNormal")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .opacity(glasses.isConnected ? 1 : 0.85)

            Text(glasses.isConnected ? "Paired" : "Turn on your glasses")
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(Tide.primaryText)
                .padding(.top, 26)

            Text(pairingDetail)
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .foregroundStyle(Tide.secondaryText)
                .padding(.top, 10)
                .padding(.horizontal, 20)

            Spacer()

            if !glasses.isConnected {
                Button {
                    glasses.startScan()
                } label: {
                    HStack(spacing: 10) {
                        if glasses.isScanning || glasses.isConnecting {
                            ProgressView().controlSize(.small).tint(Tide.backdrop)
                        }
                        Text(scanButtonTitle)
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(Tide.backdrop)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(Tide.primaryText, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                }
                .disabled(glasses.isScanning || glasses.isConnecting || !glasses.canScan)
                .padding(.bottom, 20)
            }
        }
        .padding(.horizontal, 28)
        .onAppear {
            if !glasses.isConnected, !glasses.isScanning { glasses.startScan() }
        }
    }

    private var pairingDetail: String {
        if glasses.isConnected { return "You're all set. Opening your home screen." }
        if glasses.isConnecting { return "Connecting to your glasses." }
        if glasses.isScanning { return "Keep the glasses powered on and nearby." }
        return "Power them on and keep them close to this iPhone."
    }

    private var scanButtonTitle: String {
        if glasses.isConnecting { return "Connecting" }
        if glasses.isScanning { return "Searching" }
        return "Find my glasses"
    }

    private func advance() {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        ownerName = trimmed
        nameFocused = false
        withAnimation(.smooth) { step = 1 }
    }
}
