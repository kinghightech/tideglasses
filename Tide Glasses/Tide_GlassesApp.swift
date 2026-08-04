//
//  Tide_GlassesApp.swift
//  Tide Glasses
//
//  Created by Aahish Abbani on 8/2/26.
//

import SwiftUI

@main
struct Tide_GlassesApp: App {
    @StateObject private var glasses: TideGlassesBluetoothManager
    @StateObject private var media: TideGlassesMediaTransferManager
    @StateObject private var album: TideAlbumStore
    @StateObject private var conversation: TideConversation
    @StateObject private var voice: TideVoiceSession

    init() {
        let glasses = TideGlassesBluetoothManager()
        let album = TideAlbumStore()
        let conversation = TideConversation()
        let voice = TideVoiceSession(conversation: conversation, bluetooth: glasses)

        _glasses = StateObject(wrappedValue: glasses)
        _album = StateObject(wrappedValue: album)
        _conversation = StateObject(wrappedValue: conversation)
        _voice = StateObject(wrappedValue: voice)
        _media = StateObject(wrappedValue: TideGlassesMediaTransferManager(
            bluetooth: glasses,
            album: album
        ))

        // Read-only tap on the BLE stream. The voice session watches for the
        // back button's listening window; it never sends anything, so the
        // transfer path is unaffected whatever it does.
        glasses.onPacket = { [weak voice] command, payload in
            voice?.observe(command: command, payload: payload)
        }
    }

    @AppStorage("tide.onboarded") private var onboarded = false

    var body: some Scene {
        WindowGroup {
            Group {
                if onboarded {
                    ContentView()
                } else {
                    OnboardingView()
                }
            }
            .environmentObject(glasses)
            .environmentObject(media)
            .environmentObject(album)
            .environmentObject(conversation)
            .environmentObject(voice)
        }
    }
}
