//
//  SharedComponentsGallery.swift
//  SISO Voice (freeflow fork) — Shared component library
//
//  DEBUG-only verification surface: renders every shared primitive in idle +
//  active state. This is the single view a reviewer drives to confirm the
//  library reads as one deliberate, branded artifact.
//

#if DEBUG
import SwiftUI

struct SharedComponentsGallery: View {
    @State private var switchOn = true
    @State private var switchOff = false
    @State private var toggleA = true
    @State private var toggleB = false
    @State private var selectValue = "natural"
    @State private var segValue = "week"
    @State private var search = "agent"
    @State private var emptySearch = ""
    @State private var term = "agentic"
    @State private var ruleFrom = "teh"
    @State private var ruleTo = "the"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SISOTheme.Metrics.s6) {

                group("SISOSectionLabel") {
                    SISOSectionLabel("General Settings")
                }

                group("SISOCard + SISORow + SISOHairline") {
                    SISOCard {
                        VStack(spacing: 0) {
                            SISORow(icon: "mic.fill", label: "Microphone", sublabel: "Built-in mic") {
                                Text("Active").sisoText(.caption, color: SISOTheme.Colors.accent)
                            }
                            SISOHairline().padding(.horizontal, SISOTheme.Metrics.s4)
                            SISORow(icon: "waveform", label: "Input level")
                        }
                    }
                }

                group("SISOSwitch (off / on)") {
                    HStack(spacing: SISOTheme.Metrics.s4) {
                        SISOSwitch(isOn: $switchOff)
                        SISOSwitch(isOn: $switchOn)
                    }
                }

                group("SISOToggleRow (off / on)") {
                    SISOCard {
                        VStack(spacing: 0) {
                            SISOToggleRow(icon: "bolt.fill", label: "Auto-clean",
                                          sublabel: "Run cleanup pass", isOn: $toggleB)
                            SISOHairline().padding(.horizontal, SISOTheme.Metrics.s4)
                            SISOToggleRow(icon: "sparkles", label: "Smart format", isOn: $toggleA)
                        }
                    }
                }

                group("SISOSelect") {
                    SISOSelect(selection: $selectValue,
                               options: [("natural", "Natural"),
                                         ("verbatim", "Verbatim"),
                                         ("formal", "Formal")])
                        .frame(width: 220)
                }

                group("SISOSegmented (idle / active)") {
                    SISOSegmented(selection: $segValue,
                                  options: [("day", "Day"), ("week", "Week"), ("month", "Month")])
                        .frame(width: 300)
                }

                group("SISOKeycapChip") {
                    HStack(spacing: SISOTheme.Metrics.s3) {
                        SISOKeycapChip("⌘ ⇧ D")
                        SISOKeycapChip("⌥ Space")
                        SISOKeycapChip("F5")
                    }
                }

                group("SISOStatPill (with / without delta)") {
                    HStack(spacing: SISOTheme.Metrics.s3) {
                        SISOStatPill(value: "1,204", label: "Words today", delta: "+12%")
                        SISOStatPill(value: "37", label: "Sessions")
                    }
                }

                group("SISOButton (primary / secondary / ghost)") {
                    HStack(spacing: SISOTheme.Metrics.s3) {
                        SISOButton("Primary") {}
                        SISOButton("Secondary", variant: .secondary) {}
                        SISOButton("Ghost", variant: .ghost) {}
                    }
                }

                group("SISOSearchField (filled / empty)") {
                    VStack(spacing: SISOTheme.Metrics.s3) {
                        SISOSearchField(text: $search)
                        SISOSearchField(text: $emptySearch, placeholder: "Search dictionary")
                    }
                    .frame(width: 320)
                }

                group("SISOInlineEditor (single / rule)") {
                    VStack(alignment: .leading, spacing: SISOTheme.Metrics.s3) {
                        SISOInlineEditor(text: $term, onSave: {}, onCancel: {})
                        SISOInlineEditor(from: $ruleFrom, to: $ruleTo, onSave: {}, onCancel: {})
                    }
                }

                group("SISOValidationPill") {
                    SISOValidationPill("Term cannot be empty")
                }

                group("SISOFlowLayout (wrapping chips)") {
                    SISOFlowLayout {
                        ForEach(["agentic", "Bifrost", "MiniMax", "SISO", "Convex",
                                 "Tailscale", "launchd", "WAL"], id: \.self) { tag in
                            SISOKeycapChip(keys: [tag])
                        }
                    }
                    .frame(width: 360)
                }

                group("SISOEmptyState") {
                    SISOEmptyState(icon: "tray",
                                   title: "No records yet",
                                   message: "Dictate something and it will appear here.")
                }
            }
            .padding(SISOTheme.Metrics.s6)
        }
        .frame(width: 460, height: 900)
        .background(SISOTheme.Colors.canvas)
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SISOTheme.Metrics.s2) {
            SISOSectionLabel(title)
            content()
        }
    }
}

#Preview("Shared Components Gallery") {
    SharedComponentsGallery()
}
#endif
