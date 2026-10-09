//
//  HistorySearchField.swift
//  SISO Voice (freeflow fork) — History page
//
//  Thin debounce wrapper around the Shared `SISOSearchField`. The field itself
//  is reused as-is (chrome, focus ring, clear button); this adds a ~200ms
//  debounce so list re-filtering doesn't churn on every keystroke, and exposes
//  a `FocusState` binding so the page can wire ⌘F.
//
//  macOS 13+.
//

import SwiftUI
import Combine

/// A `SISOSearchField` whose committed (debounced) value drives list filtering.
/// `text` updates immediately (so the field stays responsive + the clear button
/// works); `debouncedText` updates ~200ms after typing stops.
struct HistorySearchField: View {
    @Binding var text: String
    @Binding var debouncedText: String
    var placeholder: String
    var focus: FocusState<Bool>.Binding

    init(text: Binding<String>,
         debouncedText: Binding<String>,
         placeholder: String = "Search everything you've said…",
         focus: FocusState<Bool>.Binding) {
        self._text = text
        self._debouncedText = debouncedText
        self.placeholder = placeholder
        self.focus = focus
    }

    var body: some View {
        SISOSearchField(text: $text, placeholder: placeholder)
            .focused(focus)
            .onChange(of: text) { newValue in
                let token = UUID()
                pending = token
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    // Only the latest scheduled change wins.
                    if pending == token { debouncedText = newValue }
                }
            }
    }

    @State private var pending = UUID()
}
