//
//  InstructionsPromptTextEditor.swift
//  SISO Voice (freeflow fork) — Instructions & Account page (§3.5)
//
//  A thin TextEditor wrapper: strips the default chrome, draws a hairline /
//  accent focus border, uses the SISO mono font, and overlays a placeholder
//  when empty. Pure SwiftUI, macOS 13+.
//

import SwiftUI

// MARK: - InstructionsPromptTextEditor

struct InstructionsPromptTextEditor: View {
    @Binding var text: String
    var placeholder: String
    var minHeight: CGFloat

    @FocusState private var focused: Bool

    init(text: Binding<String>,
         placeholder: String = "Describe how the cleanup pass should rewrite transcripts…",
         minHeight: CGFloat = 220) {
        self._text = text
        self.placeholder = placeholder
        self.minHeight = minHeight
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SISOTheme.Metrics.controlRadius,
                                     style: .continuous)
        ZStack(alignment: .topLeading) {
            // Placeholder overlay (only when empty).
            if text.isEmpty {
                Text(placeholder)
                    .font(SISOTheme.mono(size: 12))
                    .foregroundColor(SISOTheme.Colors.textMuted)
                    .padding(.horizontal, SISOTheme.Metrics.s3 + 1)
                    .padding(.vertical, SISOTheme.Metrics.s3)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .font(SISOTheme.mono(size: 12))
                .foregroundColor(SISOTheme.Colors.textPrimary)
                .scrollContentBackground(.hidden)   // strip default chrome (macOS 13+)
                .background(Color.clear)
                .focused($focused)
                .padding(.horizontal, SISOTheme.Metrics.s3 - 4)
                .padding(.vertical, SISOTheme.Metrics.s2)
        }
        .frame(minHeight: minHeight, alignment: .topLeading)
        .background(shape.fill(SISOTheme.Colors.cardWhite))
        .overlay(
            shape.stroke(focused ? SISOTheme.Colors.accent : SISOTheme.Colors.hairline,
                         lineWidth: 1)
        )
        .overlay(
            shape.stroke(SISOTheme.Colors.accent.opacity(focused ? 0.18 : 0),
                         lineWidth: 3)
        )
        .animation(.easeInOut(duration: 0.15), value: focused)
    }
}

#if DEBUG
private struct InstructionsPromptTextEditorPreviewHost: View {
    @State private var text = ""
    var body: some View {
        InstructionsPromptTextEditor(text: $text)
            .padding(SISOTheme.Metrics.s6)
            .frame(width: 480)
            .background(SISOTheme.Colors.canvas)
    }
}

#Preview("Prompt Editor") { InstructionsPromptTextEditorPreviewHost() }
#endif
