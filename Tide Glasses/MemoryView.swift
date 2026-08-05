//
//  MemoryView.swift
//  Tide Glasses
//
//  The main memory, in the open and editable.
//
//  Everything Tide knows about the wearer between chats is this one block of
//  text. Nothing is hidden, nothing is inferred, and the assistant cannot write
//  a word of it — lines get here by being spoken after "update memory", or by
//  being typed on this screen.
//

import SwiftUI

struct MemoryView: View {
    @EnvironmentObject private var memory: TideMemoryStore
    @FocusState private var isEditing: Bool
    @State private var isConfirmingClear = false

    /// Warn before the cap rather than at it, so there is room to tidy up.
    private static let warningThreshold = 0.85

    private var usage: Double {
        Double(memory.characterCount) / Double(TideMemoryStore.characterLimit)
    }

    private var counterColor: Color {
        if memory.characterCount >= TideMemoryStore.characterLimit { return Tide.disconnected }
        return usage >= Self.warningThreshold ? Tide.caution : Tide.secondaryText
    }

    var body: some View {
        ZStack {
            Tide.backdrop.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    editor
                    footer
                    if !memory.isEmpty { clearButton }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .keyboard) {
                    Spacer()
                }
                ToolbarItem(placement: .keyboard) {
                    Button("Done") { isEditing = false }
                        .foregroundStyle(Tide.accent)
                }
            }
        }
        .confirmationDialog(
            "Erase everything Tide remembers about you?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Erase memory", role: .destructive) { memory.clear() }
            Button("Cancel", role: .cancel) {}
        }
        .preferredColorScheme(.dark)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if memory.isEmpty && !isEditing {
                    Text("My name is Aahish.\nI'm allergic to peanuts.\nKeep answers short.")
                        .font(.system(size: 16))
                        .foregroundStyle(Tide.secondaryText.opacity(0.5))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 20)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $memory.text)
                    .font(.system(size: 16))
                    .foregroundStyle(Tide.primaryText)
                    .tint(Tide.accent)
                    .scrollContentBackground(.hidden)
                    .focused($isEditing)
                    .frame(minHeight: 210)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
            .cardSurface(cornerRadius: 18)

            HStack {
                Spacer()
                Text("\(memory.characterCount) / \(TideMemoryStore.characterLimit)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(counterColor)
            }
            .padding(.trailing, 4)
        }
        // The block rides along on every request, so it has to stay small.
        .onChange(of: memory.text) { _, value in
            if value.count > TideMemoryStore.characterLimit {
                memory.text = String(value.prefix(TideMemoryStore.characterLimit))
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            note(
                "Tide reads this before answering anything, in every chat.",
                icon: "brain"
            )
            note(
                "To add a line by voice, say “update memory” and then the fact.",
                icon: "mic"
            )
            note(
                "Tide can read this but never writes to it. Only you do.",
                icon: "lock"
            )
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private func note(_ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Tide.secondaryText)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Tide.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var clearButton: some View {
        Button(role: .destructive) {
            isConfirmingClear = true
        } label: {
            Text("Erase memory")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Tide.disconnected)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .cardSurface()
        }
        .padding(.top, 4)
    }
}
