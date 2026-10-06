import AnimeGodCore
import SwiftUI

/// Paste a setlist with times into a disc that has none.
///
/// For the concerts nothing can place: a rip whose chapter marks were stripped
/// has no timeline anywhere, and no catalogue publishes where a song starts. But
/// people write these lists out and post them, and one paste is a great deal
/// less work than marking sixteen songs by hand while the concert plays.
///
/// What is pasted becomes the setlist, not an overlay on one: it is the
/// programme in the order it happened, including the parts no catalogue lists —
/// the encore, the curtain call, the bow at the end.
struct ConcertTimelinePasteSheet: View {
    @ObservedObject var section: ConcertCoordinator
    let animeID: UUID
    let onFinish: () -> Void

    @State private var text = ""
    @State private var isApplying = false

    private var preview: ConcertCoordinator.PastedTimelinePreview {
        section.previewPastedTimeline(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste a Timeline")
                .font(.title2.weight(.semibold))
            Text("One line per song, each with the time it starts. A `DAY1` or `Disc 2` line splits the nights, and `Encore` marks what follows it — but none of that is required, and a list that simply starts over at a lower time is read as the next disc.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 460, minHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            HStack {
                // Says what it understood before anything is written, because a
                // list that was misread is worth seeing as a number rather than
                // as a wrong setlist afterwards.
                if text.isEmpty {
                    Text("00:01:56 1.迷星叫")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                } else if preview.isUsable {
                    Label(
                        preview.discCount > 1
                            ? String(localized: "\(preview.entryCount) entries over \(preview.discCount) discs")
                            : String(localized: "\(preview.entryCount) entries"),
                        systemImage: "checkmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if preview.timedLines > 0 {
                    // It did read times; there were not enough of them. Saying
                    // "no times found" here was simply untrue, and left nobody
                    // anything to do about it.
                    Label(
                        String(localized: "Only \(preview.timedLines) line with a time — a disc needs at least \(ConcertTimelineParser.minimumEntries)"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                } else {
                    Label("No times found in that", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                }
                Spacer()
                Button("Cancel", role: .cancel) { onFinish() }
                Button("Use This") {
                    isApplying = true
                    Task {
                        await section.applyPastedTimeline(text, forAnimeID: animeID)
                        isApplying = false
                        onFinish()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!preview.isUsable || isApplying)
            }
        }
        .padding(20)
        .frame(minWidth: 520)
    }
}
