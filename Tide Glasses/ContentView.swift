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
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("tide.autoConnect") private var autoConnect = true
    @State private var selectedTab = 0
    @State private var hasStartedAutomatedWiFiTest = false

    private var isAutomatedWiFiTest: Bool {
        ProcessInfo.processInfo.arguments.contains("--tide-wifi-test")
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tag(0)
                .tabItem {
                    Label("Glasses", systemImage: "eyeglasses")
                }

            GalleryView()
                .tag(1)
                .tabItem {
                    Label("Gallery", systemImage: "photo.on.rectangle.angled")
                }

            AIView()
                .tag(2)
                .tabItem {
                    Label("AI", systemImage: "brain")
                }

            ActionsView()
                .tag(3)
                .tabItem {
                    Label("Actions", systemImage: "bolt")
                }

            GameView()
                .tag(4)
                .tabItem {
                    Label("Game", systemImage: "gamecontroller")
                }
        }
        .tint(Tide.accent)
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            // Reconnect the way the vendor app does: silently, whenever the
            // app comes forward.
            guard phase == .active, autoConnect else { return }
            glasses.reconnectIfNeeded()
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
