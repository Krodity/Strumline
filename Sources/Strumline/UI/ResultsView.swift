import SwiftUI
import StrumCore

struct ResultsView: View {
    @EnvironmentObject var app: AppModel
    @State private var choice = 1  // 0 retry, 1 continue

    @State private var page = 0
    @State private var scroller: ScrollViewProxy?

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                StrumlineBackground()
                ScrollViewReader { proxy in
                    Group {
                        if app.lastResults.count > 1 {
                            multiResults
                        } else if let r = app.lastResult {
                            if landscape {
                                // Two columns: score on the left, details on the right.
                                HStack(alignment: .top, spacing: 18) {
                                    VStack(spacing: 12) {
                                        songHeader(r)
                                        scoreBlock(r, compact: true)
                                        Spacer(minLength: 0)
                                        buttons
                                    }
                                    .frame(maxWidth: 320)
                                    ScrollView {
                                        VStack(spacing: 12) {
                                            statsGrid(r).id("p0")
                                            sectionsBlock(r)
                                        }
                                    }
                                }
                                .padding(.horizontal, 22).padding(.vertical, 12)
                            } else {
                                ScrollView {
                                    VStack(spacing: 18) {
                                        songHeader(r).id("p0")
                                        scoreBlock(r, compact: false)
                                        statsGrid(r)
                                        sectionsBlock(r)
                                        buttons
                                    }
                                    .padding(22)
                                    .frame(maxWidth: 560)
                                    .frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                    .onAppear { scroller = proxy }
                }
            }
        }
        .menuNavigation { nav in
            switch nav {
            case .left, .up, .right, .down: choice = 1 - choice
            case .confirm: if choice == 0 { app.restartCurrent() } else { app.screen = .songs(practice: false) }
            case .back: app.screen = .songs(practice: false)
            case .pageDown: turnPage(1)
            case .pageUp: turnPage(-1)
            }
        }
    }

    /// Scroll targets, in order, for controller paging.
    private var pageIDs: [String] {
        if app.lastResults.count > 1 { return app.lastResults.indices.map { "pl\($0)" } }
        let n = app.lastResult?.stats.sections.count ?? 0
        return ["p0"] + stride(from: 0, to: n, by: 6).map { "sec\($0)" }
    }

    private func turnPage(_ d: Int) {
        let ids = pageIDs
        guard !ids.isEmpty else { return }
        page = max(0, min(ids.count - 1, page + d))
        withAnimation { scroller?.scrollTo(ids[page], anchor: .top) }
    }

    private func songHeader(_ r: GameResult) -> some View {
        HStack(spacing: 14) {
            AlbumArt(song: r.song, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(r.song.name).font(.headline).lineLimit(1)
                Text(r.song.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text("\(r.instrument.displayName) · \(r.difficulty.displayName)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func scoreBlock(_ r: GameResult, compact: Bool) -> some View {
        VStack(spacing: 4) {
            StarsView(stars: r.stats.stars, size: compact ? 22 : 30)
            Text("\(r.stats.score)")
                .font(.system(size: compact ? 36 : 48, weight: .black, design: .rounded).monospacedDigit())
            if r.newBest { Text("NEW HIGH SCORE").font(.caption.bold()).foregroundStyle(Palette.yellow) }
            if r.stats.fullCombo { Text("FULL COMBO").font(.headline.bold()).foregroundStyle(Palette.yellow) }
            if r.modifiers.disablesScoreSaving { Text("Score not saved (modifiers)").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func statsGrid(_ r: GameResult) -> some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                stat("Notes hit", "\(r.stats.notesHit)/\(r.stats.notesTotal)")
                stat("Accuracy", String(format: "%.1f%%", r.stats.accuracy * 100))
                stat("Best streak", "\(r.stats.bestStreak)")
                stat("Overstrums", "\(r.stats.overstrums)")
                stat("Star power", "\(r.stats.spPhrasesHit)/\(r.stats.spPhrasesTotal)")
                stat("Speed", "\(Int((r.modifiers.songSpeed * 100).rounded()))%")
            }
            if !r.modifiers.activeNames.isEmpty {
                Text(r.modifiers.activeNames.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func sectionsBlock(_ r: GameResult) -> some View {
        if r.stats.sections.count > 1 {
            VStack(alignment: .leading, spacing: 5) {
                Text("Sections").font(.headline)
                ForEach(Array(r.stats.sections.enumerated()), id: \.offset) { i, s in
                    HStack {
                        Text(s.name).lineLimit(1)
                        Spacer()
                        let pct = s.total > 0 ? Double(s.hit) / Double(s.total) : 0
                        Text("\(Int(pct * 100))%").monospacedDigit()
                            .foregroundStyle(pct >= 1 ? Palette.yellow : pct >= 0.9 ? Palette.green : pct >= 0.7 ? .white : Palette.red)
                        ProgressView(value: pct).frame(width: 70).tint(pct >= 1 ? Palette.yellow : Palette.green)
                    }
                    .font(.subheadline)
                    .id(i % 6 == 0 ? "sec\(i)" : "row\(i)")
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
        }
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            MenuButton(title: "Retry", systemImage: "arrow.counterclockwise") { app.restartCurrent() }
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.orange, lineWidth: choice == 0 ? 2.5 : 0))
            MenuButton(title: "Continue", systemImage: "chevron.right") { app.screen = .songs(practice: false) }
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.orange, lineWidth: choice == 1 ? 2.5 : 0))
        }
    }

    /// Several players: one card each, best score first.
    private var multiResults: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let s = app.lastResults.first?.song {
                    HStack(spacing: 12) {
                        AlbumArt(song: s, size: 56)
                        VStack(alignment: .leading) {
                            Text(s.name).font(.headline).lineLimit(1)
                            Text(s.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                }
                ForEach(Array(app.lastResults.sorted { $0.stats.score > $1.stats.score }.enumerated()), id: \.offset) { rank, r in
                    HStack(spacing: 12) {
                        Text("#\(rank + 1)").font(.title3.bold()).foregroundStyle(rank == 0 ? Palette.yellow : .secondary).frame(width: 36)
                        RoundedRectangle(cornerRadius: 2).fill(PlayerProfile.colors[r.playerIndex % PlayerProfile.colors.count]).frame(width: 4)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(r.playerName).font(.headline)
                                if r.newBest { Text("NEW BEST").font(.caption2.bold()).foregroundStyle(Palette.yellow) }
                                if r.stats.fullCombo { Text("FC").font(.caption2.bold()).foregroundStyle(Palette.yellow) }
                            }
                            Text("\(r.instrument.displayName) · \(r.difficulty.displayName)").font(.caption).foregroundStyle(.secondary)
                            StarsView(stars: r.stats.stars, size: 12)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("\(r.stats.score)").font(.system(size: 22, weight: .black, design: .rounded).monospacedDigit())
                            Text(String(format: "%.1f%% · streak %d", r.stats.accuracy * 100, r.stats.bestStreak)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
                    .id("pl\(rank)")
                }
                buttons
            }
            .padding(22)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
    }
}
