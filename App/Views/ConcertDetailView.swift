import AnimeGodCore
import SwiftUI

/// A concert's page.
///
/// Deliberately not an anime page with the episode list swapped out. An anime
/// page is built around a score, a synopsis and a run of episodes, and a concert
/// disc has none of those: no provider rates it as a work, no synopsis says
/// anything a setlist does not say better, and there is one programme rather
/// than twelve. What it does have is **what was played**, so the setlist is the
/// page — clickable, timed, and honest about where the times came from.
struct ConcertDetailView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var section: ConcertCoordinator
    let animeID: UUID

    @State private var episodes: [EpisodeMedia] = []
    @State private var selectedDiscNumber: Int?
    @State private var catalogNumberEntry = ""

    private var concert: LibraryConcert? {
        section.concerts.first { $0.id == animeID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let concert {
                    header(concert)
                    if let release = concert.release {
                        setlistSection(release)
                        programme(release)
                        summary(release)
                        otherDiscs(release)
                        inTheBox(release)
                        scans(release)
                        releaseFacts(release)
                    } else {
                        programme(nil)
                        unidentified
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(concert?.displayTitle ?? String(localized: "Concert"))
        .task(id: animeID) { await load() }
        .task(id: model.libraryRevision) { await load() }
    }

    private func load() async {
        guard let anime = concert?.anime else { return }
        episodes = await model.episodes(for: anime)
        if selectedDiscNumber == nil, let first = discNumbers.first { selectedDiscNumber = first }
        for episode in episodes {
            await section.loadStoredSetlist(forEpisodeID: episode.episode.id)
        }
    }

    // MARK: - Header

    private func header(_ concert: LibraryConcert) -> some View {
        HStack(alignment: .top, spacing: 20) {
            PosterView(urls: concert.release?.coverImageURLs ?? [], height: 200)
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 8) {
                Text(concert.displayTitle)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(3)
                if let artist = concert.release?.artistNames.first {
                    Text(artist)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                // The line an anime page spends on air date and episode count.
                // For a concert the useful facts are when and where it happened
                // and how long it runs — the hall in particular, which only
                // Bangumi knows and which nothing else on screen can say.
                factsLine(concert)

                HStack(spacing: 10) {
                    if let first = playableEpisode(forDiscNumber: selectedDiscNumber) ?? episodes.first {
                        Button {
                            Task { await model.play(first) }
                        } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    if let score = concert.release?.score {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(score, format: .number.precision(.fractionLength(1)))
                                .font(.title3.weight(.semibold))
                                .monospacedDigit()
                            Text(concert.release?.ratingCount.map { String(localized: "\($0) ratings") }
                                 ?? String(localized: "Bangumi"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    private func factsLine(_ concert: LibraryConcert) -> some View {
        let release = concert.release
        var parts: [String] = []
        if let performed = release?.performedOn, !performed.isEmpty { parts.append(performed) }
        if let venue = release?.venue, !venue.isEmpty { parts.append(venue) }
        if concert.discCount > 1 { parts.append(String(localized: "\(concert.discCount) discs")) }
        if let total = release?.totalSongDuration, total > 0 {
            parts.append(String(localized: "\(Int(total / 60)) min of music"))
        }
        return Text(parts.joined(separator: " · "))
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    // MARK: - The setlist, which is the page

    private var discNumbers: [Int?] {
        let numbers = episodes.map { $0.episode.numberText.flatMap { Int($0) } }
        return numbers.isEmpty ? [nil] : numbers
    }

    private func playableEpisode(forDiscNumber number: Int?) -> EpisodeMedia? {
        guard let number else { return episodes.first }
        return episodes.first { $0.episode.numberText.flatMap { Int($0) } == number } ?? episodes.first
    }

    @ViewBuilder
    private func setlistSection(_ release: ConcertRelease) -> some View {
        let episode = playableEpisode(forDiscNumber: selectedDiscNumber)
        let disc = release.videoDisc(forDiscNumber: selectedDiscNumber)
        let alignment = episode.flatMap { section.setlists[$0.episode.id] }

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Setlist")
                    .font(.title2.weight(.semibold))
                Spacer()
                if let disc, !disc.songs.isEmpty {
                    Text("\(disc.songs.count) songs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                timelineBadge(alignment: alignment, episode: episode)
            }

            // More than one night or disc: which one's setlist is on screen.
            if discNumbers.count > 1 {
                Picker("Disc", selection: $selectedDiscNumber) {
                    ForEach(discNumbers, id: \.self) { number in
                        Text(discLabel(number)).tag(number)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if let disc, !disc.songs.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(disc.songs.enumerated()), id: \.element.id) { index, song in
                        if song.isEncore, index > 0, !disc.songs[index - 1].isEncore {
                            encoreDivider
                        }
                        SongRow(
                            song: song,
                            startTime: alignment?.placements
                                .first { $0.trackPosition == song.position }?.startTime,
                            canPlay: episode != nil
                        ) {
                            guard let episode else { return }
                            let start = alignment?.placements
                                .first { $0.trackPosition == song.position }?.startTime
                            Task { await model.play(episode, startingAt: start) }
                        }
                        if index < disc.songs.count - 1 { Divider() }
                    }
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            } else {
                Text("No setlist was found for this disc. The chapter list in the player is still the quickest way around it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            // The songs are known before the times are, and sometimes the times
            // never come. Where a song starts is read off the disc's own chapter
            // marks, which only reach the app once mpv has opened the disc — and
            // plenty of rips have had their marks stripped, in which case no
            // source has them and saying "play it and they will appear" would be
            // a promise nothing can keep.
            if let disc, !disc.songs.isEmpty, alignment?.placements.isEmpty != false, let episode {
                if section.discHasNoChapters(forEpisodeID: episode.episode.id) {
                    Text("This file carries no chapter marks, so there is nothing to place the songs on. No catalogue publishes where a song starts either — the marks live inside the disc, and this encode dropped them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if section.setlistNotLookedAtYet(forEpisodeID: episode.episode.id) {
                    Text("Times appear once the disc has been played: they come from its own chapter marks, which are inside the disc rather than in any catalogue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var encoreDivider: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.quaternary).frame(height: 1)
            Text("Encore")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Rectangle().fill(.quaternary).frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Says where the times came from, and offers to fix them.
    ///
    /// Shown rather than hidden because the timeline is inferred: no source
    /// publishes where a song starts, so it is read off the disc's own chapter
    /// marks. A viewer who knows that corrects a list that is one song out
    /// instead of concluding the feature does not work.
    @ViewBuilder
    private func timelineBadge(alignment: ConcertSetlistAlignment?, episode: EpisodeMedia?) -> some View {
        if let alignment, !alignment.placements.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: alignment.isTrustworthy ? "clock.badge.checkmark" : "clock.badge.questionmark")
                Text(timelineDescription(alignment))
                if !alignment.isTrustworthy, let episode,
                   section.canNudgeSetlist(forEpisodeID: episode.episode.id) {
                    Button("Shift ↓") { Task { await nudge(episode: episode, by: 1) } }
                        .buttonStyle(.link)
                    Button("Shift ↑") { Task { await nudge(episode: episode, by: -1) } }
                        .buttonStyle(.link)
                }
            }
            .font(.caption)
            .foregroundStyle(alignment.isTrustworthy
                             ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            .help(timelineHelp(alignment))
        }
    }

    private func timelineDescription(_ alignment: ConcertSetlistAlignment) -> String {
        switch alignment.method {
        case .chapterTitles: String(localized: "Times from the disc's chapters")
        case .durations: alignment.isTrustworthy
            ? String(localized: "Times matched to the disc")
            : String(localized: "Times are a guess")
        case .oneToOne: String(localized: "One chapter per song")
        case .cumulative: String(localized: "Times estimated")
        case .none: String(localized: "No times")
        }
    }

    private func timelineHelp(_ alignment: ConcertSetlistAlignment) -> String {
        switch alignment.method {
        case .chapterTitles:
            String(localized: "The disc names its own chapters after the songs, so these times are the disc's.")
        case .durations:
            String(localized: "No source publishes where a song starts, so the published song lengths were matched against the disc's chapter marks.")
        case .oneToOne:
            String(localized: "The disc has as many chapters as the setlist has songs, so each chapter was taken as a song. A disc that also marks its MC segments would be one song out.")
        case .cumulative:
            String(localized: "The disc carries no chapter marks, so the songs are laid end to end. The talk between them is not accounted for.")
        case .none:
            String(localized: "There was nothing to work the times out from.")
        }
    }

    private func nudge(episode: EpisodeMedia, by offset: Int) async {
        await section.nudgeSetlist(forEpisodeID: episode.episode.id, by: offset)
    }

    private func discLabel(_ number: Int?) -> String {
        guard let number else { return String(localized: "Disc") }
        return String(localized: "Disc \(number)")
    }

    // MARK: - What is actually on disk

    /// The files themselves, each playable.
    ///
    /// The setlist is the page when there is one, but there is often not one —
    /// a BDRip identified only through Bangumi has a hall and a date and no
    /// track list anywhere. What it does have is two nights sitting on the
    /// disk, and without this there is no way to play the second one.
    @ViewBuilder
    private func programme(_ release: ConcertRelease?) -> some View {
        if episodes.count > 1 || release?.videoDiscs.first?.songs.isEmpty != false {
            VStack(alignment: .leading, spacing: 8) {
                Text("Discs")
                    .font(.title2.weight(.semibold))
                VStack(spacing: 0) {
                    ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                        Button {
                            Task { await model.play(episode) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "play.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(programmeLabel(episode, release: release))
                                        .font(.body.weight(.medium))
                                    Text(fileName(episode))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                if let progress = episode.progress, progress.duration > 0 {
                                    Text(SongRow.timecode(progress.duration))
                                        .font(.callout.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < episodes.count - 1 { Divider() }
                    }
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    /// What to call one file. A disc the release names is called that; anything
    /// else on a concert of several entries is a night, which is what two
    /// entries of a live almost always are.
    private func programmeLabel(_ episode: EpisodeMedia, release: ConcertRelease?) -> String {
        let number = episode.episode.numberText.flatMap { Int($0) }
        if let title = release?.videoDisc(forDiscNumber: number)?.title, !title.isEmpty {
            return title
        }
        guard let number else { return String(localized: "Full programme") }
        return String(localized: "Disc \(number)")
    }

    private func fileName(_ episode: EpisodeMedia) -> String {
        (episode.mediaFile.relativePath as NSString).lastPathComponent
    }

    /// What the entry says about the concert, when it says anything. Bangumi's
    /// 演出 subjects often carry a line or two, and on a page with no setlist it
    /// is the only prose there is.
    @ViewBuilder
    private func summary(_ release: ConcertRelease) -> some View {
        if let text = release.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("About")
                    .font(.title3.weight(.semibold))
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - The rest of the box

    @ViewBuilder
    private func otherDiscs(_ release: ConcertRelease) -> some View {
        let others = release.discs.filter { disc in
            disc.position != (selectedDiscNumber ?? release.videoDiscs.first?.position)
        }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Also on this release")
                    .font(.title3.weight(.semibold))
                ForEach(others) { disc in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(disc.title ?? discLabel(disc.position))
                                .font(.subheadline.weight(.medium))
                            if let format = disc.format {
                                Text(format)
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        if !disc.tracks.isEmpty {
                            Text(disc.tracks.prefix(4).map(\.title).joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    /// What came in the box beside the video.
    ///
    /// The bonus CDs, the soundtrack rip, the scans, the menus. A catalogue
    /// cannot know any of this; the folder does, and it is the part of the page
    /// that describes what the viewer actually owns.
    @ViewBuilder
    private func inTheBox(_ release: ConcertRelease) -> some View {
        if !release.extras.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("In the box")
                    .font(.title3.weight(.semibold))
                HStack(spacing: 10) {
                    ForEach(release.extras) { extra in
                        VStack(spacing: 2) {
                            Text(extra.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Text("\(extra.itemCount) items")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    /// The jacket scans, which are the best artwork anywhere near this release:
    /// three megabytes each against a catalogue's 445×600 photograph of a case.
    @ViewBuilder
    private func scans(_ release: ConcertRelease) -> some View {
        let images = Array(release.coverImageURLs.dropFirst().prefix(24))
        if !images.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Scans")
                    .font(.title3.weight(.semibold))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(images, id: \.self) { url in
                            PosterView(url: url, height: 150)
                                .frame(height: 150)
                                .fixedSize(horizontal: false, vertical: true)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// The label, the catalogue number, the barcode. Small print, and the only
    /// place the identity the whole lookup hangs on is visible.
    @ViewBuilder
    private func releaseFacts(_ release: ConcertRelease) -> some View {
        if !releaseFactPairs(release).isEmpty || release.sourceURL != nil || release.officialSiteURL != nil {
            releaseFactsBody(release)
        }
    }

    private func releaseFactsBody(_ release: ConcertRelease) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Release")
                .font(.title3.weight(.semibold))
            HStack(spacing: 14) {
                ForEach(releaseFactPairs(release), id: \.0) { pair in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pair.0)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(pair.1)
                            .font(.caption)
                            .monospacedDigit()
                            .textSelection(.enabled)
                    }
                }
            }
            HStack(spacing: 14) {
                if let site = release.officialSiteURL {
                    Link(String(localized: "Official site"), destination: site).font(.caption)
                }
                if let source = release.sourceURL {
                    Link(String(localized: "Open on \(release.provider.displayName)"), destination: source)
                        .font(.caption)
                }
            }
        }
    }

    private func releaseFactPairs(_ release: ConcertRelease) -> [(String, String)] {
        var pairs: [(String, String)] = []
        if let label = release.labels.first {
            pairs.append((String(localized: "Label"), label))
        }
        if let catalogue = release.catalogNumbers.first {
            pairs.append((String(localized: "Catalogue number"), catalogue))
        }
        if let barcode = release.barcode {
            pairs.append((String(localized: "Barcode"), barcode))
        }
        if let released = release.releaseDate {
            pairs.append((String(localized: "Released"), released))
        }
        if !release.genres.isEmpty {
            pairs.append((String(localized: "Genre"), release.genres.prefix(2).joined(separator: ", ")))
        }
        return pairs
    }

    // MARK: - Nothing matched

    private var unidentified: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This disc has not been identified")
                .font(.title3.weight(.semibold))
            Text("Nothing is known about it beyond the folder it arrived in, so there is no setlist to lay over it. Discs are matched by the catalogue number in the folder name — ANZX-10294, BRMM-10716.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Look This Disc Up") {
                    Task { await section.identify(animeID: animeID) }
                }
                .disabled(section.isIdentifying)
                Text("or")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                // The escape hatch for a release whose folder never carried the
                // number — a BDRip, a folder someone renamed. It is the same key
                // the automatic path uses, so it gives the same answer.
                TextField("Catalogue number", text: $catalogNumberEntry)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .onSubmit { lookUpByCatalogNumber() }
                Button("Look Up", action: lookUpByCatalogNumber)
                    .disabled(section.isIdentifying || catalogNumberEntry.isEmpty)
            }
        }
    }

    private func lookUpByCatalogNumber() {
        let entry = catalogNumberEntry
        guard !entry.isEmpty else { return }
        Task { await section.identify(animeID: animeID, catalogNumber: entry) }
    }
}

/// One song: where it starts, how long it runs, and a click that plays it.
struct SongRow: View {
    let song: ConcertTrack
    let startTime: TimeInterval?
    let canPlay: Bool
    let play: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                Text(String(song.position))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, alignment: .trailing)
                Text(song.title)
                    .font(.body)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let startTime {
                    Text(Self.timecode(startTime))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(isHovering ? .primary : .secondary)
                }
                if let duration = song.duration {
                    Text(Self.duration(duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(isHovering ? AnyShapeStyle(.selection.opacity(0.25)) : AnyShapeStyle(.clear))
        }
        .buttonStyle(.plain)
        .disabled(!canPlay)
        .onHover { isHovering = $0 && canPlay }
        .help(startTime == nil
              ? String(localized: "Plays this disc from the start — there is no time for this song.")
              : String(localized: "Plays from \(Self.timecode(startTime!))"))
    }

    /// Where it starts, as a position in the programme.
    static func timecode(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// How long it runs.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
