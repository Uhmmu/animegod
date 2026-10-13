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
    /// What this disc already knows. A disc whose chapter marks survived has
    /// the opposite problem from the one this sheet was built for: it knows
    /// where every song starts and what none of them is, and then a paste of
    /// bare names is all that is missing.
    var existingTimes: [TimeInterval] = []
    /// The disc the page was showing. A paste that names no night is this one
    /// and the ones after it — not disc 1, which is what it used to mean
    /// wherever the viewer happened to be.
    var discNumber: Int?
    let onFinish: () -> Void

    @State private var text = ""
    @State private var isApplying = false

    private var preview: ConcertCoordinator.PastedTimelinePreview {
        section.previewPastedTimeline(text, over: existingTimes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste a Timeline")
                .font(.title2.weight(.semibold))
            Text("One line per song, each with the time it starts. A `DAY1` or `Disc 2` line splits the nights, and `Encore` marks what follows it — but none of that is required, and a list that simply starts over at a lower time is read as the next disc.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !existingTimes.isEmpty {
                Text("This disc already has \(existingTimes.count) marks, so a list of **just song names** works too — one per line, in order. The times are shown beside them as you type.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Both columns are always here, and that is the whole fix for a
            // sheet that drew itself over its own text. A macOS sheet is sized
            // once, when it appears — and it appeared with the text empty, so
            // the pairing column did not exist yet and the window was made just
            // wide enough without it. The moment anything was pasted the column
            // arrived, the content needed 240pt more than the window had, and
            // the overflow was clipped from both edges: the title, the
            // explanation and every timecode in the editor lost their left
            // halves. Reserving the column means the size it is given at
            // presentation is the size it will need.
            HStack(alignment: .top, spacing: 12) {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, minHeight: 300)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

                // The pairing, line by line, so a list with somebody's own
                // additions in it can be seen going out of step and lines added
                // or removed until it reads right. Nothing here resolves the
                // mismatch; it only shows it.
                pairing
            }

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
                // A line whose time steps backwards. It used to be read as the
                // start of the next night and the list was cut in two there,
                // which put half of one concert onto the other one's episode.
                // It stays where it was pasted now, and is said out loud.
                if preview.outOfOrderCount > 0 {
                    Label(
                        String(localized: "\(preview.outOfOrderCount) line goes back in time"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                }
                if preview.isLayeringNames, preview.names.count != existingTimes.count {
                    Label(
                        String(localized: "\(preview.names.count) names over \(existingTimes.count) marks"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                }
                Spacer()
                Button("Cancel", role: .cancel) { onFinish() }
                Button("Use This") {
                    isApplying = true
                    Task {
                        await section.applyPastedTimeline(
                            text, over: existingTimes, forAnimeID: animeID, startingAtDisc: discNumber
                        )
                        isApplying = false
                        onFinish()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!preview.isUsable || isApplying)
            }
        }
        .padding(20)
        .frame(width: 760)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Time on the left, name on the right, one row per mark — and a row with
    /// one side missing is exactly the thing worth seeing.
    @ViewBuilder
    private var pairing: some View {
        if preview.pairs.isEmpty {
            // The column is here before there is anything in it, because the
            // sheet is sized once and has to be sized for the width it will
            // need. Saying what it is for costs nothing.
            Text("What was read, line by line, appears here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(10)
                .frame(width: 240, height: 300, alignment: .topLeading)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
        } else {
            pairs
        }
    }

    private var pairs: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(preview.pairs.enumerated()), id: \.offset) { index, pair in
                    HStack(spacing: 8) {
                        Text(pair.time.map(Self.timecode) ?? "—")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(pair.time == nil || pair.isOutOfOrder
                                             ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                            .frame(width: 62, alignment: .leading)
                        Text(pair.name ?? String(localized: "no name"))
                            .font(.caption)
                            .foregroundStyle(pair.name == nil ? Color.orange : .primary)
                            .lineLimit(1)
                        if pair.isEncore {
                            Text("ENCORE")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 1)
                    .id(index)
                }
            }
            .padding(8)
        }
        .frame(width: 240, height: 300)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
    }

    static func timecode(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
