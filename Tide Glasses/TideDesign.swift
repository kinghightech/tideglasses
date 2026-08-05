//
//  TideDesign.swift
//  Tide Glasses
//
//  Dark, restrained, system-native. No glow, no rounded "bubble" type —
//  status is carried by small, familiar indicators the way iOS does it.
//

import SwiftUI

enum Tide {
    /// #111111
    static let backdrop = Color(red: 0.067, green: 0.067, blue: 0.067)
    static let card = Color(white: 0.105)
    static let hairline = Color.white.opacity(0.10)
    static let primaryText = Color(white: 0.97)
    static let secondaryText = Color(white: 0.55)
    static let accent = Color(red: 0.35, green: 0.55, blue: 0.95)
    static let connected = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let disconnected = Color(red: 1.00, green: 0.27, blue: 0.23)
    /// Approaching a limit — not wrong yet, but worth looking at.
    static let caution = Color(red: 0.95, green: 0.70, blue: 0.25)

    static func greeting(for date: Date = Date()) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 0..<12: "Good morning,"
        case 12..<17: "Good afternoon,"
        case 17..<22: "Good evening,"
        default: "Good night,"
        }
    }

    /// Apple's battery glyph for a given level.
    static func batterySymbol(level: Int?, charging: Bool) -> String {
        guard let level else { return "battery.0percent" }
        if charging { return "battery.100percent.bolt" }
        switch level {
        case 88...100: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

struct CardSurface: ViewModifier {
    var cornerRadius: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .background(Tide.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Tide.hairline, lineWidth: 0.8)
            }
    }
}

extension View {
    func cardSurface(cornerRadius: CGFloat = 22) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius))
    }
}

/// Frosted capsule used for the status and battery readouts.
struct GlassPill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 7) {
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.20), Color.white.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
        }
        .environment(\.colorScheme, .dark)
    }
}
