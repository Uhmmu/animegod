import AnimeGodCore
import SwiftUI

/// Everything about how the picture is annotated — danmaku and subtitles —
/// in one place, adjusted while watching.
///
/// A sheet rather than a menu: the player's body re-evaluates several times a
/// second and a menu rebuilt underneath an open one drops taps — the same
/// trap the Mac's control bar hit. A sheet is presented once and owns its own
/// state from then on. It sits at a detent that leaves the picture showing
/// and lets touches through to it, because a subtitle delay can only be
/// judged against a mouth that is moving.
struct MobilePlayerStylePanel: View {
    @ObservedObject var store: MobileDanmakuSettingsStore
    @ObservedObject var state: MobilePlayerState
    let controller: MobilePlayerController?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    slider(
                        "Delay",
                        systemImage: "timer",
                        value: Binding(
                            get: { state.subtitleDelay },
                            set: {
                                state.subtitleDelay = ($0 * 100).rounded() / 100
                                controller?.setSubtitleDelay(state.subtitleDelay)
                            }
                        ),
                        in: -10...10,
                        step: 0.05,
                        format: { String(format: "%+.2f s", $0) }
                    )
                    slider(
                        "Size",
                        systemImage: "textformat.size",
                        value: Binding(
                            get: { state.subtitleScale },
                            set: {
                                state.subtitleScale = $0
                                controller?.setSubtitleScale($0)
                            }
                        ),
                        in: 0.5...2.5,
                        step: 0.05,
                        format: { String(format: "%.0f%%", $0 * 100) }
                    )
                    Button("Reset Subtitles") {
                        state.subtitleDelay = 0
                        state.subtitleScale = 1
                        controller?.setSubtitleDelay(0)
                        controller?.setSubtitleScale(1)
                    }
                } header: {
                    Text("Subtitles")
                } footer: {
                    Text("A positive delay shows subtitles later. Size applies to plain-text subtitles always, and to styled ones without disturbing their colours or signs.")
                }

                Section {
                    Picker(selection: areaBinding) {
                        ForEach(DanmakuAreaPreset.allCases) { preset in
                            Text(preset.label).tag(preset)
                        }
                    } label: {
                        Label("Area", systemImage: "rectangle.tophalf.inset.filled")
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Danmaku Coverage")
                } footer: {
                    Text("Comments fill from the top down, so this keeps the rest of the picture clear — subtitles included.")
                }

                Section("Danmaku Text") {
                    slider(
                        "Size",
                        systemImage: "textformat.size",
                        value: $store.settings.fontScale,
                        in: 0.5...2.0,
                        step: 0.05,
                        format: { String(format: "%.0f%%", $0 * 100) }
                    )
                    slider(
                        "Opacity",
                        systemImage: "circle.lefthalf.filled",
                        value: $store.settings.opacity,
                        in: 0.2...1.0,
                        step: 0.05,
                        format: { String(format: "%.0f%%", $0 * 100) }
                    )
                    slider(
                        "Line Spacing",
                        systemImage: "arrow.up.and.down.text.horizontal",
                        value: $store.settings.lineSpacing,
                        in: 1.05...2.0,
                        step: 0.05,
                        format: { String(format: "%.2f×", $0) }
                    )
                }

                Section("Danmaku Motion") {
                    slider(
                        "Speed",
                        systemImage: "speedometer",
                        value: $store.settings.speedMultiplier,
                        in: 0.5...2.0,
                        step: 0.1,
                        format: { String(format: "%.1f×", $0) }
                    )
                    slider(
                        "Density",
                        systemImage: "square.stack.3d.down.right",
                        value: $store.settings.density,
                        in: 0.2...1.0,
                        step: 0.05,
                        format: { String(format: "%.0f%%", $0 * 100) }
                    )
                }

                Section {
                    Toggle(isOn: $store.settings.hideScroll) { Label("Hide Scrolling", systemImage: "arrow.left") }
                    Toggle(isOn: $store.settings.hideTop) { Label("Hide Top", systemImage: "arrow.up.to.line") }
                    Toggle(isOn: $store.settings.hideBottom) { Label("Hide Bottom", systemImage: "arrow.down.to.line") }
                    Toggle(isOn: $store.settings.hideColored) { Label("Colored as White", systemImage: "paintpalette") }
                } header: {
                    Text("Danmaku Kinds")
                } footer: {
                    Text("Top and bottom comments are pinned and appear in the middle of the picture rather than scrolling in.")
                }

                Section {
                    Button("Reset Danmaku", role: .destructive) { store.reset() }
                }
            }
            .navigationTitle("Display")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.regularMaterial)
        // The picture keeps playing and keeps taking touches behind the
        // sheet, so a delay can be judged while it is being dragged.
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    private var areaBinding: Binding<DanmakuAreaPreset> {
        Binding(
            get: { DanmakuAreaPreset.nearest(to: store.settings.displayArea) },
            set: { store.settings.displayArea = $0.rawValue }
        )
    }

    @ViewBuilder
    private func slider(
        _ title: LocalizedStringKey,
        systemImage: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double,
        format: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text(verbatim: format(value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }
}
