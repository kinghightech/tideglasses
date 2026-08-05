//
//  ChatListView.swift
//  Tide Glasses
//
//  Every saved chat, and the way into the main memory.
//
//  Threads are ordered by when they were last touched, so the one being carried
//  on sits at the top whether it was continued by typing or by talking through
//  the glasses.
//

import SwiftUI

struct ChatListView: View {
    @EnvironmentObject private var chats: TideChatStore
    @EnvironmentObject private var conversation: TideConversation
    @EnvironmentObject private var memory: TideMemoryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Tide.backdrop.ignoresSafeArea()

                List {
                    Section {
                        NavigationLink {
                            MemoryView()
                        } label: {
                            memoryRow
                        }
                    }
                    .listRowBackground(Tide.card)

                    Section {
                        if chats.threads.isEmpty {
                            Text("Chats you have will be kept here.")
                                .font(.system(size: 14))
                                .foregroundStyle(Tide.secondaryText)
                                .padding(.vertical, 6)
                        }

                        ForEach(chats.threads) { thread in
                            Button {
                                conversation.open(thread)
                                dismiss()
                            } label: {
                                row(for: thread)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete(perform: delete)
                    } header: {
                        if !chats.threads.isEmpty {
                            Text("Chats")
                                .font(.system(size: 12, weight: .semibold))
                                .tracking(1.2)
                                .foregroundStyle(Tide.secondaryText)
                        }
                    }
                    .listRowBackground(Tide.card)
                }
                .scrollContentBackground(.hidden)
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tide.accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        conversation.newThread()
                        dismiss()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .foregroundStyle(Tide.accent)
                }
            }
            .toolbarBackground(Tide.backdrop, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    private var memoryRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "brain")
                .font(.system(size: 15))
                .foregroundStyle(Tide.accent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text("Memory")
                    .font(.system(size: 16))
                    .foregroundStyle(Tide.primaryText)
                Text(memorySummary)
                    .font(.system(size: 13))
                    .foregroundStyle(Tide.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private var memorySummary: String {
        guard !memory.isEmpty else { return "Nothing saved yet" }
        let lines = memory.text
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
        return lines == 1 ? "1 thing remembered" : "\(lines) things remembered"
    }

    private func row(for thread: TideChatThread) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(thread.displayTitle)
                    .font(.system(size: 16))
                    .foregroundStyle(Tide.primaryText)
                    .lineLimit(1)

                if thread.id == conversation.threadID {
                    Text("Open")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Tide.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Tide.accent.opacity(0.15), in: Capsule())
                }
            }

            Text(thread.updatedAt.formatted(.relative(presentation: .named)))
                .font(.system(size: 13))
                .foregroundStyle(Tide.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 3)
    }

    /// Deleting the chat that is currently open leaves nothing to show, so the
    /// conversation starts a fresh one rather than displaying a dead thread.
    private func delete(at offsets: IndexSet) {
        // Resolve every thread before deleting any of them. Deleting shifts
        // the array, so reading `threads[index]` inside the loop would target
        // the wrong rows and eventually run off the end.
        for thread in offsets.map({ chats.threads[$0] }) {
            chats.delete(thread)
            conversation.forgetIfCurrent(thread)
        }
    }
}
