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
    /// The current selection came from a tap (don't auto-scroll to it).
    @State private var touchSelected = false
    /// Play requested from the setup sheet; runs when the sheet is gone.
    @State private var playAfterSheet: (() -> Void)?

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
                    ControlLegend([.move, .page, .select, .back])
                    PlayerBar()
                }
            }
            .sheet(isPresented: Binding(get: { showSetup && !wide }, set: { showSetup = $0 }), onDismiss: {
                let play = playAfterSheet
                playAfterSheet = nil
                play?()
            }) {
                if let s = selected {
                    SongSetupPanel(song: s, practice: practice, inSheet: true, focused: true, onClose: { showSetup = false },
                                   onPlayAfterClose: { playAfterSheet = $0 })
                        .presentationDetents([.large])
                        .environmentObject(app)
                }
            }
            // The list has input unless the setup panel/sheet has taken it.
            .menuNavigation(enabled: wide ? !panelFocused : !showSetup) { nav in navigate(nav, list: list, wide: wide) }
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

    private func navigate(_ nav: MenuNav, list: [SongEntry], wide: Bool) {
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
            ScreenHeader(title: practice ? "Practice" : "Quickplay", onBack: { app.preview.stop(); app.screen = .menu }) {
                if app.scanning { ProgressView().controlSize(.small) }
                // The sort is named, not just an icon.
                Menu {
                    Picker("Sort", selection: $app.settings.sort) {
                        ForEach(SongSort.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                } label: {
                    Label(app.settings.sort.displayName, systemImage: "arrow.up.arrow.down")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Theme.Surface.control))
                }
                Button { app.rescan() } label: { Image(systemName: "arrow.clockwise").font(.body.weight(.semibold)) }
                    .disabled(app.scanning)
                    .accessibilityLabel("Rescan library")
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search songs, artists, charters…", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
                Text("\(list.count)").font(.footnote.monospacedDigit()).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.Surface.control))
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
                            // Art: highlight + preview only. Rest of the row: open setup.
                            SongRow(song: s, selected: selected?.path == s.path, onArtTap: {
                                touchSelected = true
                                selected = s
                            })
                                .id(s.path)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    touchSelected = true
                                    selected = s
                                    showSetup = true
                                }
                                .listRowBackground(selected?.path == s.path ? Theme.Surface.selected : Theme.Surface.row)
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
                // A tapped row is already under the finger; only controller /
                // keyboard moves scroll the selection into the middle.
                if touchSelected { touchSelected = false; return }
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
    /// Tapping the art previews the song without opening its setup.
    var onArtTap: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            AlbumArt(song: song, size: 48)
                .overlay(alignment: .bottomTrailing) {
                    // The highlighted song is the one previewing.
                    if selected {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Circle().fill(Theme.accent))
                            .offset(x: 4, y: 4)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onArtTap)
                .accessibilityLabel("Preview \(song.name)")
                .accessibilityAddTraits(.isButton)
            // Always two lines, so every row is the same height.
            VStack(alignment: .leading, spacing: 3) {
                Text(song.name).font(Theme.Fonts.heading).lineLimit(1)
                (Text(song.artist).foregroundStyle(.secondary)
                    + Text(song.charter.isEmpty ? "" : "  ·  \(song.charter)").foregroundStyle(.tertiary))
                    .font(.subheadline).lineLimit(1)
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
