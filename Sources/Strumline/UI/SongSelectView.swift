import SwiftUI
import StrumCore

struct SongSelectView: View {
    @EnvironmentObject var app: AppModel
    var practice: Bool
    @State private var query = ""
    @State private var selected: SongEntry?
    @State private var showSetup = false
    /// Split layout (iPad): the setup panel has controller focus.
    @State private var panelFocused = false

    var body: some View {
        GeometryReader { geo in
            // Side-by-side only when there's room for the whole setup panel
            // (iPad); phones in either orientation use a sheet.
            let wide = geo.size.width > 700 && geo.size.height > 560
            let list = app.sortedSongs(filter: query)
            ZStack {
                StrumlineBackground()
                VStack(spacing: 0) {
                    header(list)
                    if wide {
                        HStack(spacing: 0) {
                            songList(list)
                                .frame(width: min(460, geo.size.width * 0.48))
                            Divider()
                            if let s = selected {
                                SongSetupPanel(song: s, practice: practice, focused: panelFocused, onClose: { panelFocused = false })
                                    .id(s.path)
                            } else {
                                placeholder
                            }
                        }
                    } else {
                        songList(list)
                    }
                    PlayerBar()
                }
            }
            .sheet(isPresented: Binding(get: { showSetup && !wide }, set: { showSetup = $0 })) {
                if let s = selected {
                    SongSetupPanel(song: s, practice: practice, inSheet: true, focused: true, onClose: { showSetup = false })
                        .presentationDetents([.large])
                        .environmentObject(app)
                }
            }
            .onAppear { installMenuHandler(list, wide: wide) }
            .onChange(of: query) { _, _ in installMenuHandler(app.sortedSongs(filter: query), wide: wide) }
            .onChange(of: app.songs) { _, _ in installMenuHandler(app.sortedSongs(filter: query), wide: wide) }
            .onChange(of: showSetup) { _, open in if !open { installMenuHandler(app.sortedSongs(filter: query), wide: wide) } }
            .onChange(of: panelFocused) { _, f in if !f { installMenuHandler(app.sortedSongs(filter: query), wide: wide) } }
            .onChange(of: app.settings.sort) { _, _ in installMenuHandler(app.sortedSongs(filter: query), wide: wide) }
        }
        .onChange(of: selected) { _, s in
            app.preview.volume = app.settings.previewVolume
            if let s { app.preview.play(s) }
        }
        .onAppear {
            if selected == nil { selected = app.selectedSong }
        }
        .onDisappear { app.selectedSong = selected }
        .alert("Couldn't start the song", isPresented: Binding(get: { app.playError != nil }, set: { if !$0 { app.playError = nil } })) {
            Button("OK", role: .cancel) { app.playError = nil }
        } message: {
            Text(app.playError ?? "")
        }
    }

    private func installMenuHandler(_ list: [SongEntry], wide: Bool) {
        InputManager.shared.menuHandler = { a in
            guard let nav = MenuNav(a) else { return }
            if nav == .back { app.preview.stop(); app.screen = .menu; return }
            guard !list.isEmpty else { return }
            let idx = selected.flatMap { s in list.firstIndex { $0.path == s.path } } ?? -1
            switch nav {
            case .down: selected = list[min(list.count - 1, idx + 1)]
            case .up: selected = list[max(0, idx - 1)]
            case .right, .pageDown: selected = list[min(list.count - 1, idx + 10)]
            case .left, .pageUp: selected = list[max(0, idx - 10)]
            case .confirm:
                if selected == nil { selected = list[0]; return }
                if wide { panelFocused = true } else { showSetup = true }
            case .back: break
            }
        }
    }

    private func bestDifficulty(_ s: SongEntry) -> Difficulty {
        let inst = s.instruments.contains(app.settings.lastInstrument) ? app.settings.lastInstrument : (s.instruments.first ?? .guitar)
        let ds = s.difficulties(for: inst)
        return ds.contains(app.settings.lastDifficulty) ? app.settings.lastDifficulty : (ds.last ?? .expert)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Wordmark(size: 34)
            Text("Pick a song").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(_ list: [SongEntry]) -> some View {
        VStack(spacing: 8) {
            HStack {
                Button { app.preview.stop(); app.screen = .menu } label: {
                    Image(systemName: "chevron.left").font(.title3.bold())
                }
                Text(practice ? "Practice" : "Quickplay").font(.system(size: 24, weight: .black, design: .rounded))
                Spacer()
                if app.scanning { ProgressView().controlSize(.small) }
                Text("\(list.count)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                Menu {
                    Picker("Sort", selection: $app.settings.sort) {
                        ForEach(SongSort.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down.circle").font(.title3)
                }
                Button { app.rescan() } label: { Image(systemName: "arrow.clockwise.circle").font(.title3) }
                    .disabled(app.scanning)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search songs, artists, charters…", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
            if app.pendingDownloads > 0 {
                Text("Downloading \(app.pendingDownloads) file(s) from iCloud… they'll appear automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func songList(_ list: [SongEntry]) -> some View {
        ScrollViewReader { proxy in
            List {
                if list.isEmpty && !app.scanning {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(query.isEmpty ? "No songs yet" : "No matches").font(.headline)
                        if query.isEmpty {
                            Text("Add song folders or .sng files to Strumline's folder in the Files app, or link a folder from Library.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("Open Library") { app.screen = .library }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(groups(list), id: \.0) { title, songs in
                    Section {
                        ForEach(songs) { s in
                            SongRow(song: s, selected: selected?.path == s.path)
                                .id(s.path)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selected = s
                                    showSetup = true
                                }
                                .listRowBackground(selected?.path == s.path ? Palette.orange.opacity(0.22) : Color.white.opacity(0.03))
                        }
                    } header: {
                        if !title.isEmpty { Text(title).font(.caption.bold()) }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { app.rescan() }
            .onChange(of: selected) { _, s in
                if let s { withAnimation { proxy.scrollTo(s.path, anchor: .center) } }
            }
        }
    }

    private func groups(_ list: [SongEntry]) -> [(String, [SongEntry])] {
        var out: [(String, [SongEntry])] = []
        for s in list {
            let g = app.groupTitle(s)
            if out.last?.0 == g { out[out.count - 1].1.append(s) } else { out.append((g, [s])) }
        }
        // Keep header ids unique if a title repeats non-adjacently.
        var seen: [String: Int] = [:]
        return out.map { t, s in
            let n = seen[t, default: 0]
            seen[t] = n + 1
            return (n == 0 ? t : "\(t) (\(n + 1))", s)
        }
    }
}

struct SongRow: View {
    @EnvironmentObject var app: AppModel
    var song: SongEntry
    var selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            AlbumArt(song: song, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.name).font(.system(size: 16, weight: .bold)).lineLimit(1)
                Text(song.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if !song.charter.isEmpty {
                    Text(song.charter).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                if let best = bestRecord {
                    StarsView(stars: best.stars, size: 10)
                    Text("\(best.score)").font(.caption2.monospacedDigit()).foregroundStyle(best.fullCombo ? Palette.yellow : .secondary)
                }
                HStack(spacing: 4) {
                    if song.kind == .sng { Image(systemName: "shippingbox.fill").font(.system(size: 9)).foregroundStyle(.tertiary) }
                    Text(formatLength(song.lengthMs)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var bestRecord: ScoreRecord? {
        let inst = app.settings.lastInstrument
        return app.best(song, inst, app.settings.lastDifficulty) ?? Difficulty.allCases.reversed().lazy.compactMap { app.best(song, inst, $0) }.first
    }
}
