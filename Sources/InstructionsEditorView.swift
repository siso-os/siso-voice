//
//  InstructionsEditorView.swift
//  SISO Voice (freeflow fork) — Instructions & Account page (§3.5)
//
//  The cleanup-prompt editor card: draft state, dirty dot, Save / Reset, a model
//  badge, and supported-token hint chips. Pure SwiftUI, macOS 13+.
//
//  IN-CODE NOTE: the prompt edited here feeds the cleanup pass, which routes
//  downstream through Bifrost → MiniMax. This view ONLY stores the text via
//  `InstructionsStore`; the cleanup-pass read-wiring is a separate task.
//

import SwiftUI

// MARK: - InstructionsEditorView

struct InstructionsEditorView: View {
    @ObservedObject var store: InstructionsStore

    /// Draft text the user is editing; persisted only on Save.
    @State private var draft: String
    /// Brief "Saved · just now" confirmation, shown right after a save.
    @State private var showSavedFlash = false

    init(store: InstructionsStore) {
        self.store = store
        _draft = State(initialValue: store.saved)
    }

    private var isDirty: Bool { store.isDirty(draft) }

    var body: some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s4) {
            header
            SISOCard {
                VStack(alignment: .leading, spacing: SISOTheme.Metrics.s3) {
                    InstructionsPromptTextEditor(text: $draft)
                    SISOHairline()
                    hintChips
                    actionRow
                }
            }
            tokenLegend
        }
        // Keep the draft in sync if the store is reset/saved externally.
        .onChange(of: store.saved) { newValue in
            if !isDirty { draft = newValue }
        }
    }

    // MARK: Header (title + model badge)

    private var header: some View {
        HStack(alignment: .center, spacing: SISOTheme.Metrics.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cleanup instructions")
                    .sisoText(.cardTitle, color: SISOTheme.Colors.textPrimary)
                Text("System prompt for the dictation cleanup pass.")
                    .sisoText(.caption, color: SISOTheme.Colors.textMuted)
            }
            Spacer(minLength: SISOTheme.Metrics.s3)
            modelBadge
        }
    }

    /// Model pill — `Capsule` per spec (e.g. "MiniMax via Bifrost").
    private var modelBadge: some View {
        HStack(spacing: SISOTheme.Metrics.s1 + 2) {
            Image(systemName: "cpu")
                .font(.system(size: 10, weight: .medium))
            Text(modelLabel)
                .sisoText(.pill, color: SISOTheme.Colors.textSecondary)
        }
        .foregroundColor(SISOTheme.Colors.textSecondary)
        .padding(.horizontal, SISOTheme.Metrics.s3)
        .padding(.vertical, 4)
        .background(Capsule().fill(SISOTheme.Colors.canvasInset))
        .overlay(Capsule().stroke(SISOTheme.Colors.hairline, lineWidth: 1))
    }

    private var modelLabel: String {
        store.model == InstructionsStore.defaultModel ? "MiniMax via Bifrost" : store.model
    }

    // MARK: Hint chips (supported tokens)

    private var hintChips: some View {
        SISOFlowLayout {
            ForEach(InstructionsTokens.all, id: \.self) { token in
                Text(token)
                    .font(SISOTheme.mono(size: 11))
                    .foregroundColor(SISOTheme.Colors.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(SISOTheme.Colors.canvasInset)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(SISOTheme.Colors.hairline, lineWidth: 1)
                    )
            }
        }
    }

    // MARK: Action row (dirty dot + status + Save / Reset)

    private var actionRow: some View {
        HStack(spacing: SISOTheme.Metrics.s3) {
            statusLabel
            Spacer(minLength: SISOTheme.Metrics.s3)
            SISOButton("Reset to default", variant: .ghost) {
                draft = InstructionsStore.defaultInstructions
                store.save(InstructionsStore.defaultInstructions)
                flashSaved()
            }
            .disabled(store.isDefault && !isDirty)
            .opacity(store.isDefault && !isDirty ? 0.5 : 1)

            SISOButton("Save", variant: .primary) {
                store.save(draft)
                flashSaved()
            }
            .disabled(!isDirty)
            .opacity(isDirty ? 1 : 0.5)
        }
    }

    /// Dirty dot (gold while edited-unsaved) + status text.
    private var statusLabel: some View {
        HStack(spacing: SISOTheme.Metrics.s2) {
            if isDirty {
                Circle()
                    .fill(SISOTheme.Colors.gold)
                    .frame(width: 7, height: 7)
                Text("Unsaved changes")
                    .sisoText(.caption, color: SISOTheme.Colors.textMuted)
            } else if showSavedFlash {
                Text("Saved · just now")
                    .sisoText(.caption, color: SISOTheme.Colors.accent)
            } else if let rel = store.savedRelative {
                Text("Saved · \(rel)")
                    .sisoText(.caption, color: SISOTheme.Colors.textMuted)
            } else {
                Text("Using default prompt")
                    .sisoText(.caption, color: SISOTheme.Colors.textMuted)
            }
        }
    }

    private func flashSaved() {
        withAnimation { showSavedFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation { showSavedFlash = false }
        }
    }

    // MARK: Token legend

    private var tokenLegend: some View {
        Text("Tokens are documentation only — substitution is handled by the cleanup pipeline (a separate task).")
            .sisoText(.caption, color: SISOTheme.Colors.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
#Preview("Instructions Editor") {
    InstructionsEditorView(store: InstructionsStore())
        .padding(SISOTheme.Metrics.s6)
        .frame(width: 560)
        .background(SISOTheme.Colors.canvas)
}
#endif
