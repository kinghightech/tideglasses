//
//  ActionsView.swift
//  Tide Glasses
//
//  Permissions, phrasings, and a record of what Tide has done.
//
//  Access is granted here rather than the first time it is needed, because the
//  first time it is needed the phone is usually in a pocket with the screen
//  locked — a system prompt cannot appear, and the wearer would hear a refusal
//  with no way to act on it.
//

import EventKit
import SwiftUI

struct ActionsView: View {
    @EnvironmentObject private var actions: TideActionRunner
    @EnvironmentObject private var log: TideActionLog

    @State private var isConfirmingClear = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ZStack {
                Tide.backdrop.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        access
                        phrasings
                        history
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Actions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Tide.backdrop, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        // Permission can be changed in iOS Settings while the app is away.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { actions.refreshStatuses() }
        }
        .onAppear { actions.refreshStatuses() }
    }

    // MARK: - Access

    private var access: some View {
        panel("Access") {
            AccessRow(
                title: "Reminders",
                icon: "checklist",
                status: actions.reminderStatus
            ) {
                Task { await actions.requestReminderAccess() }
            }

            Divider().overlay(Tide.hairline)

            AccessRow(
                title: "Calendar",
                icon: "calendar",
                status: actions.calendarStatus
            ) {
                Task { await actions.requestCalendarAccess() }
            }

            Text("Asked for once. Everything runs on this iPhone — what is in your calendar is never sent to the AI.")
                .font(.system(size: 13))
                .foregroundStyle(Tide.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Phrasings

    private var phrasings: some View {
        panel("Say this") {
            ForEach(Array(Self.examples.enumerated()), id: \.offset) { index, example in
                if index > 0 { Divider().overlay(Tide.hairline) }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: example.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(Tide.accent)
                        .frame(width: 18)
                    Text("“\(example.phrase)”")
                        .font(.system(size: 14))
                        .foregroundStyle(Tide.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }

            Text("Start with “remind” or “calendar” and Tide handles it here instead of asking the AI.")
                .font(.system(size: 13))
                .foregroundStyle(Tide.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let examples: [(phrase: String, icon: String)] = [
        ("Remind me to call Mom tomorrow at six.", "checklist"),
        ("What reminders do I have?", "list.bullet"),
        ("Calendar, what do I have tomorrow?", "calendar"),
        ("Calendar, add lunch tomorrow at noon.", "calendar.badge.plus"),
    ]

    // MARK: - History

    private var history: some View {
        panel("Recent") {
            if log.records.isEmpty {
                Text("Nothing yet. Reminders and events you create will be listed here.")
                    .font(.system(size: 14))
                    .foregroundStyle(Tide.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(log.records.enumerated()), id: \.element.id) { index, record in
                    if index > 0 { Divider().overlay(Tide.hairline) }
                    RecordRow(record: record) { log.delete(record) }
                }

                Divider().overlay(Tide.hairline)

                Button(role: .destructive) {
                    isConfirmingClear = true
                } label: {
                    Text("Clear history")
                        .font(.system(size: 15))
                        .foregroundStyle(Tide.disconnected)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .confirmationDialog(
            "Clear this list?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) { log.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your actual reminders and calendar events are not touched.")
        }
    }

    // MARK: - Layout

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

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .cardSurface(cornerRadius: 18)
        }
    }
}

// MARK: - Rows

private struct AccessRow: View {
    let title: String
    let icon: String
    let status: EKAuthorizationStatus
    let grant: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(granted ? Tide.connected : Tide.secondaryText)
                .frame(width: 22)

            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(Tide.primaryText)

            Spacer(minLength: 12)

            if granted {
                Label("Allowed", systemImage: "checkmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Tide.connected)
            } else if blocked {
                // Once refused, only iOS Settings can undo it.
                Link("Open Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Tide.accent)
            } else {
                Button("Allow", action: grant)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Tide.accent)
            }
        }
    }

    private var granted: Bool { status == .fullAccess }

    private var blocked: Bool {
        status == .denied || status == .restricted || status == .writeOnly
    }
}

private struct RecordRow: View {
    let record: TideActionRecord
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: record.kind == .reminder ? "checklist" : "calendar")
                .font(.system(size: 14))
                .foregroundStyle(Tide.accent)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(.system(size: 15))
                    .foregroundStyle(Tide.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Tide.secondaryText)
            }

            Spacer(minLength: 8)

            Button(action: delete) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tide.secondaryText.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove from this list")
        }
    }

    private var subtitle: String {
        guard let date = record.date else { return "No date" }
        return TideActionRunner.spoken(date).capitalizedFirstWord
    }
}

private extension String {
    /// "tomorrow at 6 PM" → "Tomorrow at 6 PM", for a written list.
    var capitalizedFirstWord: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
