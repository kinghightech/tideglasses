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

    init() {
        let glasses = TideGlassesBluetoothManager()
        let album = TideAlbumStore()
        _glasses = StateObject(wrappedValue: glasses)
        _album = StateObject(wrappedValue: album)
        _media = StateObject(wrappedValue: TideGlassesMediaTransferManager(
            bluetooth: glasses,
            album: album
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(glasses)
                .environmentObject(media)
                .environmentObject(album)
        }
    }
}
