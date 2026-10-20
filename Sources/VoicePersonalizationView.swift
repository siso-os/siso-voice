//
//  VoicePersonalizationView.swift
//  Local controls for dictation modes, snippets and agent draft preferences.
//

import SwiftUI

struct VoicePersonalizationView: View {
    @State private var mappings: [VoiceModeMapping] = VoicePersonalization.loadMappings()
    @State private var snippets: [VoiceSnippet] = VoicePersonalization.loadSnippets()
    @State private var bundleIdentifier = ""
    @State private var selectedMode: VoiceMode = .standard
    @State private var trigger = ""
    @State private var content = ""
    @AppStorage(VoicePersonalization.reviewDraftKey) private var reviewDraft = false
    @AppStorage(VoicePersonalization.draftMinimumWordsKey) private var minimumWords = 80
    @AppStorage(VoicePersonalization.agentPaneKey) private var agentPane = ""
    @AppStorage(VoicePersonalization.agentReadBackKey) private var agentReadBack = false

    var body: some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s6) {
            SISOSectionLabel("Dictation modes")
            SISOCard {
                VStack(alignment: .leading, spacing: SISOTheme.Metrics.s3) {
                    Text("Choose a mode for an app. Start dictation with “email mode:” or “[mode] email:” to override it.")
                        .font(SISOTheme.font(.caption))
                        .foregroundColor(SISOTheme.Colors.textSecondary)

                    ForEach(mappings.indices, id: \.self) { index in
                        HStack(spacing: SISOTheme.Metrics.s2) {
                            TextField("Bundle identifier", text: mappingBundleBinding(at: index))
                                .textFieldStyle(.roundedBorder)
                            Picker("Mode", selection: mappingModeBinding(at: index)) {
                                ForEach(VoiceMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .labelsHidden()
                            Button(role: .destructive) { removeMapping(at: index) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    HStack(spacing: SISOTheme.Metrics.s2) {
                        TextField("com.example.app", text: $bundleIdentifier)
                            .textFieldStyle(.roundedBorder)
                        Picker("Mode", selection: $selectedMode) {
                            ForEach(VoiceMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        Button("Add mapping", action: addMapping)
                            .disabled(bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }

            SISOSectionLabel("Spoken snippets")
            SISOCard {
                VStack(alignment: .leading, spacing: SISOTheme.Metrics.s3) {
                    Text("A whole-phrase trigger expands to its saved text. Snippet text is stored locally on this Mac.")
                        .font(SISOTheme.font(.caption))
                        .foregroundColor(SISOTheme.Colors.textSecondary)

                    ForEach(snippets.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s2) {
                            HStack {
                                TextField("Trigger phrase", text: snippetTriggerBinding(at: index))
                                    .textFieldStyle(.roundedBorder)
                                Button(role: .destructive) { removeSnippet(at: index) } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                            TextEditor(text: snippetContentBinding(at: index))
                                .font(SISOTheme.font(.body))
                                .frame(minHeight: 58)
                                .padding(4)
                                .background(SISOTheme.Colors.canvasInset)
                                .clipShape(RoundedRectangle(cornerRadius: SISOTheme.Metrics.controlRadius))
                        }
                    }

                    TextField("Trigger phrase", text: $trigger)
                        .textFieldStyle(.roundedBorder)
                    TextEditor(text: $content)
                        .font(SISOTheme.font(.body))
                        .frame(minHeight: 70)
                        .padding(4)
                        .background(SISOTheme.Colors.canvasInset)
                        .clipShape(RoundedRectangle(cornerRadius: SISOTheme.Metrics.controlRadius))
                    Button("Add snippet", action: addSnippet)
                        .disabled(trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || content.isEmpty)
                }
            }

            SISOSectionLabel("Review and agent draft")
            SISOCard(padding: 0) {
                VStack(spacing: 0) {
                    SISOToggleRow(icon: "doc.text.magnifyingglass",
                                  label: "Review long drafts",
                                  sublabel: "Keep longer dictation in a draft for review",
                                  isOn: $reviewDraft)
                    Divider().overlay(SISOTheme.Colors.hairline)
                    SISORow(icon: "text.word.spacing",
                            label: "Draft threshold",
                            sublabel: "Minimum words before review draft is used") {
                        Stepper(value: $minimumWords, in: 1...2000, step: 10) {
                            Text("\(minimumWords) words")
                                .font(SISOTheme.font(.caption))
                                .foregroundColor(SISOTheme.Colors.textSecondary)
                        }
                        .frame(maxWidth: 190)
                    }
                    Divider().overlay(SISOTheme.Colors.hairline)
                    SISORow(icon: "rectangle.split.3x1",
                            label: "Agent target pane",
                            sublabel: "Destination label used by the deliberate send flow") {
                        TextField("Pane ID", text: $agentPane)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 190)
                    }
                    Divider().overlay(SISOTheme.Colors.hairline)
                    SISOToggleRow(icon: "speaker.wave.2",
                                  label: "Read back sent message",
                                  sublabel: "Speak your outgoing message after Send succeeds",
                                  isOn: $agentReadBack)
                }
            }

            Text("Agent mode prepares a draft only. Sending always requires a deliberate user action.")
                .font(SISOTheme.font(.caption))
                .foregroundColor(SISOTheme.Colors.textMuted)
        }
        .onChange(of: mappings) { value in VoicePersonalization.saveMappings(value) }
        .onChange(of: snippets) { value in VoicePersonalization.saveSnippets(value) }
    }

    private func mappingBundleBinding(at index: Int) -> Binding<String> {
        Binding(get: { mappings[index].bundleIdentifier }, set: { mappings[index].bundleIdentifier = $0 })
    }
    private func mappingModeBinding(at index: Int) -> Binding<VoiceMode> {
        Binding(get: { mappings[index].mode }, set: { mappings[index].mode = $0 })
    }
    private func snippetTriggerBinding(at index: Int) -> Binding<String> {
        Binding(get: { snippets[index].trigger }, set: { snippets[index].trigger = $0 })
    }
    private func snippetContentBinding(at index: Int) -> Binding<String> {
        Binding(get: { snippets[index].content }, set: { snippets[index].content = $0 })
    }

    private func addMapping() {
        let id = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        if let existing = mappings.firstIndex(where: { $0.bundleIdentifier.caseInsensitiveCompare(id) == .orderedSame }) {
            mappings[existing].mode = selectedMode
        } else {
            mappings.append(VoiceModeMapping(bundleIdentifier: id, mode: selectedMode))
        }
        bundleIdentifier = ""
    }
    private func removeMapping(at index: Int) {
        guard mappings.indices.contains(index) else { return }
        mappings.remove(at: index)
    }
    private func addSnippet() {
        let phrase = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, !content.isEmpty else { return }
        snippets.append(VoiceSnippet(trigger: phrase, content: content))
        trigger = ""
        content = ""
    }
    private func removeSnippet(at index: Int) {
        guard snippets.indices.contains(index) else { return }
        snippets.remove(at: index)
    }
}
