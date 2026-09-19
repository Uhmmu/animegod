import AnimeGodCore
import SwiftUI

/// The playlist button: a popover of episode tiles grouped like the detail
/// page (Episodes, Specials, Music & Credits, …), laid out as a grid so a
/// long series or a pile of SPs stays short instead of becoming a tall menu.
///
/// Equatable on what it shows, so the player's frequent re-renders don't
/// rebuild the popover while it is open.
struct PlayerEpisodePicker: View, @MainActor Equatable {
    let episodes: [EpisodeMedia]
    let currentIndex: Int
    let isSwitching: Bool
    let select: (Int) -> Void

    @State private var isPresented = ProcessInfo.processInfo.environment["AG_SMOKE_EPISODE_PICKER"] == "1"

    static func == (lhs: PlayerEpisodePicker, rhs: PlayerEpisodePicker) -> Bool {
        lhs.currentIndex == rhs.currentIndex && lhs.isSwitching == rhs.isSwitching
            && lhs.episodes.map(\.id) == rhs.episodes.map(\.id)
    }

    var body: some View {
        Button { isPresented.toggle() } label: { Image(systemName: "list.bullet") }
            .help("Episodes")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                PlayerEpisodeGrid(episodes: episodes, currentIndex: currentIndex, isSwitching: isSwitching) { index in
                    isPresented = false
                    select(index)
                }
            }
    }
}

private struct PlayerEpisodeGrid: View {
    let episodes: [EpisodeMedia]
    let currentIndex: Int
    let isSwitching: Bool
    let select: (Int) -> Void

    private struct Item: Identifiable {
        let index: Int
        let episode: EpisodeMedia
        /// 1-based position within its kind.
        var ordinal = 0
        /// Some item of the same kind has no number, so the whole kind is
        /// labelled by position; mixing "PV1" and "PV01" would be ambiguous.
        var kindUsesOrdinals = false
        var id: UUID { episode.id }
    }

    private var groups: [(category: EpisodeCategory, items: [Item])] {
        var counts: [EpisodeKind: Int] = [:]
        let unnumberedKinds = Set(episodes.filter { ($0.episode.numberText ?? "").isEmpty }.map(\.episode.kind))
        let items = episodes.enumerated().map { offset, episode in
            let kind = episode.episode.kind
            counts[kind, default: 0] += 1
            return Item(index: offset, episode: episode, ordinal: counts[kind]!, kindUsesOrdinals: unnumberedKinds.contains(kind))
        }
        let grouped = Dictionary(grouping: items) { $0.episode.episode.kind.category }
        return EpisodeCategory.allCases.compactMap { category in
            grouped[category].map { (category, $0) }
        }
    }

    /// Wider for bigger groups, so neither 3 nor 60 tiles makes a tall list.
    private var columnCount: Int {
        let largest = groups.map(\.items.count).max() ?? 0
        return switch largest {
        case ..<7: max(largest, 3)
        case ..<25: 6
        case ..<49: 8
        default: 10
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groups, id: \.category) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Text(group.category.displayName)
                                    .font(.subheadline.weight(.semibold))
                                Text("\(group.items.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.fixed(Self.tileWidth), spacing: 6), count: columnCount),
                                alignment: .leading,
                                spacing: 6
                            ) {
                                ForEach(group.items) { item in
                                    tile(item).id(item.index)
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }
            .frame(width: CGFloat(columnCount) * (Self.tileWidth + 6) + 22)
            .frame(maxHeight: 460)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { proxy.scrollTo(currentIndex, anchor: .center) }
        }
    }

    private static let tileWidth: CGFloat = 56

    private func tile(_ item: Item) -> some View {
        let isCurrent = item.index == currentIndex
        let watched = item.episode.progress?.isWatched == true
        return Button { select(item.index) } label: {
            Text(tileLabel(item))
                .font(.system(size: 13, weight: isCurrent ? .bold : .medium).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: Self.tileWidth, height: 34)
                .foregroundStyle(isCurrent ? Color.black : (watched ? Color.secondary : Color.primary))
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isCurrent ? Color.white : Color.white.opacity(0.1))
                )
                .overlay(alignment: .bottom) {
                    // A partly watched episode shows how far it got.
                    if let progress = item.episode.progress, !progress.isWatched, progress.completion > 0.02, !isCurrent {
                        GeometryReader { geometry in
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: max(4, (geometry.size.width - 12) * progress.completion), height: 2)
                                .offset(x: 6)
                        }
                        .frame(height: 2)
                        .padding(.bottom, 4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The playing tile stays bright; it just doesn't do anything.
        .allowsHitTesting(!isCurrent && !isSwitching)
        .help(fullLabel(item) + (isCurrent ? " · playing" : watched ? " · watched" : ""))
    }

    /// Main episodes show their number; everything else carries its kind
    /// (SP3, OP1, PV2…), numbered by position when some file of that kind
    /// has no number, so a row of unnumbered specials is still tellable apart.
    private func tileLabel(_ item: Item) -> String {
        let episode = item.episode.episode
        let number = episode.numberText.flatMap { $0.isEmpty ? nil : $0 }
        let prefix = switch episode.kind {
        case .regular: ""
        case .special: "SP"
        case .opening: "OP"
        case .ending: "ED"
        case .music: "MV"
        case .trailer: "PV"
        case .extra: "EX"
        }
        if episode.kind == .regular { return number ?? "Movie" }
        return prefix + (item.kindUsesOrdinals ? String(item.ordinal) : number ?? String(item.ordinal))
    }

    private func fullLabel(_ item: Item) -> String {
        let name = (item.episode.mediaFile.relativePath as NSString).lastPathComponent
        let title = item.episode.episode.title.map { " — \($0)" } ?? ""
        return "\(tileLabel(item))\(title)\n\(name)"
    }
}
