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
    @StateObject private var chats: TideChatStore
    @StateObject private var memory: TideMemoryStore
    @StateObject private var conversation: TideConversation
    @StateObject private var voice: TideVoiceSession

    init() {
        let glasses = TideGlassesBluetoothManager()
        let album = TideAlbumStore()
        let chats = TideChatStore()
        let memory = TideMemoryStore()
        let conversation = TideConversation(chats: chats, memory: memory)
        let voice = TideVoiceSession(conversation: conversation, bluetooth: glasses)

        _glasses = StateObject(wrappedValue: glasses)
        _album = StateObject(wrappedValue: album)
        _chats = StateObject(wrappedValue: chats)
        _memory = StateObject(wrappedValue: memory)
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
    @Environment(\.scenePhase) private var scenePhase

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
            .environmentObject(chats)
            .environmentObject(memory)
            .environmentObject(conversation)
            .environmentObject(voice)
            // A thread is written when a question is asked and when its answer
            // settles, so this only catches a chat abandoned mid-answer.
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { conversation.persist() }
            }
        }
    }
}
