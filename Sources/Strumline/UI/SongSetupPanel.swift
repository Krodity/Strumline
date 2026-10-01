import SwiftUI
import StrumCore

struct SongSetupPanel: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    var song: SongEntry
    var practice: Bool
    /// Set when shown in a sheet: the sheet must close before the game
    /// screen replaces the song list, or it stays on top of it.
    var inSheet = false
    /// Controller/keyboard focus: ↑↓ instrument, ←→ difficulty, confirm plays.
    var focused = false
    var onClose: () -> Void = {}
    /// In a sheet: hands over the "start the song" action to run once the
    /// sheet has finished closing (the game screen replaces the song list).
    var onPlayAfterClose: ((@escaping () -> Void) -> Void)? = nil

    @State private var instrument: Instrument = .guitar
    @State private var difficulty: Difficulty = .expert
    @State private var sections: [ChartSection] = []
    @State private var startSection = 0
    @State private var endSection = 0
    @State private var showMods = false

    @State private var page = 0
    /// Controller focus row: see `focusRows`.
    @State private var focusRow: FocusRow = .play

    enum FocusRow: Hashable { case instrument, difficulty, kit, modifiers, songSpeed, play }

    private var focusRows: [FocusRow] {
        var r: [FocusRow] = [.instrument, .difficulty]
        if instrument == .drums { r.append(.kit) }
        r.append(.modifiers)
        if !practice { r.append(.songSpeed) }
        r.append(.play)
        return r
    }

    private func isFocused(_ row: FocusRow) -> Bool { focused && focusRow == row }
    @State private var scroller: ScrollViewProxy?

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ScrollViewReader { proxy in
                Group {
                    if landscape {
                        // Two columns so a phone in landscape shows everything
                        // without scrolling.
                        HStack(alignment: .top, spacing: 0) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 12) {
                                    topBar
                                    headerView(compact: true).id("p0")
                                    partsView.id("p1")
                                    if practice { practiceControls }
                                }
                                .padding(14)
                            }
                            VStack(spacing: 0) {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 12) {
                                        modifierSection.id("p2")
                                        warningView
                                    }
                                    .padding(14)
                                }
                                footer.padding(.horizontal, 14).padding(.bottom, 10)
                            }
                        }
                    } else {
                        VStack(spacing: 0) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 18) {
                                    topBar
                                    headerView(compact: false).id("p0")
                                    partsView.id("p1")
                                    modifierSection.id("p2")
                                    if practice { practiceControls }
                                    warningView
                                }
                                .padding(20)
                            }
                            footer.padding(.horizontal, 20).padding(.bottom, 12)
                        }
                    }
                }
                .onAppear { scroller = proxy }
            }
        }
        .menuNavigation(enabled: focused) { nav in navigate(nav) }
        .onAppear {
            let insts = song.instruments
            select(insts.contains(app.settings.lastInstrument) ? app.settings.lastInstrument : (insts.first ?? .guitar))
            if practice { loadSections() }
        }
        .sheet(isPresented: $showMods) {
            ModifiersView(kind: instrument.kind, practice: practice)
                .environmentObject(app)
                .presentationDetents([.large])
        }
    }


    @ViewBuilder private var topBar: some View {
        if inSheet {
            HStack {
                Spacer()
                Button("Done") { onClose() }.bold()
            }
            .padding(.bottom, -10)
        }
    }

    /// Play stays on screen; the legend sits under it when a controller,
    /// keyboard or kit is connected.
    private var footer: some View {
        VStack(spacing: 8) {
            playButton.id("p3")
            if focused { ControlLegend([.move, .change, .select, .back]) }
        }
        .padding(.top, 8)
    }

    @ViewBuilder private func headerView(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                AlbumArt(song: song, size: compact ? 64 : 112)
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.name).font(.system(size: compact ? 17 : 22, weight: .black, design: .rounded)).lineLimit(2)
                    Text(song.artist).font(.headline).foregroundStyle(.secondary)
                    Text([song.album, song.year].filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if !song.genre.isEmpty { Label(song.genre, systemImage: "music.quarternote.3") }
                        Label(formatLength(song.lengthMs), systemImage: "clock")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if !song.charter.isEmpty {
                        Label(song.charter, systemImage: "pencil.and.ruler").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !song.loadingPhrase.isEmpty {
                Text(TextDecoding.stripTags(song.loadingPhrase)).font(.footnote.italic()).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var partsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Instrument
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Instrument")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(song.instruments) { i in
                            Button { select(i) } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: i.symbol).font(.title3)
                                    Text(i.displayName).font(.caption.bold()).lineLimit(1)
                                    IntensityDots(value: song.intensity(i))
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .tile(selected: instrument == i)
                            }
                            .foregroundStyle(.white)
                        }
                    }
                }
            }
            .focusRing(isFocused(.instrument), inset: -6)

            // Difficulty
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Difficulty")
                HStack(spacing: 8) {
                    ForEach(song.difficulties(for: instrument)) { d in
                        Button { difficulty = d } label: {
                            VStack(spacing: 3) {
                                Text(d.displayName).font(.subheadline.bold())
                                if let b = app.best(song, instrument, d) {
                                    StarsView(stars: b.stars, size: 8)
                                    Text("\(b.score)").font(.system(size: 10).monospacedDigit()).foregroundStyle(b.fullCombo ? Palette.yellow : .secondary)
                                } else {
                                    Text("—").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .tile(selected: difficulty == d)
                        }
                        .foregroundStyle(.white)
                    }
                }
            }
            .focusRing(isFocused(.difficulty), inset: -6)
            if instrument == .drums {
                Picker("Drum kit", selection: $app.settings.drumMode) {
                    ForEach(DrumPlayMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .focusRing(isFocused(.kit), inset: -6)
                if let t = song.drumType {
                    Text("Charted as \(t == .fiveLane ? "5-lane" : t == .fourLanePro ? "4-lane Pro" : "4-lane") drums").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var warningView: some View {
        if app.settings.modifiers.disablesScoreSaving && !practice {
            Label("Scores won't be saved with Drunk Mode on.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(Palette.yellow)
        }
    }

    private var playButton: some View {
        playButtonBody.focusRing(isFocused(.play), inset: -6)
    }

    private var playButtonBody: some View {
        Button { start() } label: {
            Label(practice ? "Practice" : "Play", systemImage: "play.fill")
                .font(Theme.Fonts.title.weight(.black))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(LinearGradient(colors: [Palette.orange, Palette.red], startPoint: .leading, endPoint: .trailing)))
        }
        .foregroundStyle(.white)
        .disabled(song.difficulties(for: instrument).isEmpty)
    }

    /// Controllers can't drag a scroll view: page through the sections.
    private func turnPage(_ delta: Int) {
        page = max(0, min(2, page + delta))
        withAnimation { scroller?.scrollTo("p\(page)", anchor: .top) }
    }

    private func start() {
        guard !song.difficulties(for: instrument).isEmpty else { return }
        let p = practice ? PracticeRange(startSection: startSection, endSection: max(startSection, endSection)) : nil
        let (i, d) = (instrument, difficulty)
        if inSheet, let defer_ = onPlayAfterClose {
            defer_ { app.play(song: song, instrument: i, difficulty: d, practice: p) }
            onClose()
        } else {
            app.play(song: song, instrument: i, difficulty: d, practice: p)
        }
    }

    /// ↑↓ moves between rows, ←→ changes the highlighted row, green
    /// selects (plays on Play, opens Modifiers), red closes.
    private func navigate(_ nav: MenuNav) {
        let rows = focusRows
        let idx = rows.firstIndex(of: focusRow) ?? rows.count - 1
        switch nav {
        case .up, .down:
            let n = max(0, min(rows.count - 1, idx + (nav == .down ? 1 : -1)))
            focusRow = rows[n]
            // Play is pinned below the scroll view, so it needs no scrolling.
            let target = [FocusRow.instrument, .difficulty, .kit].contains(focusRow) ? "p1" : "p2"
            withAnimation { scroller?.scrollTo(target, anchor: .center) }
        case .left, .right:
            adjust(focusRow, by: nav == .right ? 1 : -1)
        case .confirm:
            switch focusRow {
            case .play: start()
            case .modifiers: showMods = true
            default:
                // Accept this row and move on toward Play.
                focusRow = rows[min(rows.count - 1, idx + 1)]
            }
        case .back: onClose()
        case .pageDown: turnPage(1)
        case .pageUp: turnPage(-1)
        }
    }

    private func adjust(_ row: FocusRow, by d: Int) {
        switch row {
        case .instrument:
            let insts = song.instruments
            guard let i = insts.firstIndex(of: instrument), !insts.isEmpty else { return }
            select(insts[(i + d + insts.count) % insts.count])
        case .difficulty:
            let diffs = song.difficulties(for: instrument)
            guard let i = diffs.firstIndex(of: difficulty) else { return }
            difficulty = diffs[max(0, min(diffs.count - 1, i + d))]
        case .kit:
            let all = DrumPlayMode.allCases
            let i = all.firstIndex(of: app.settings.drumMode) ?? 0
            app.settings.drumMode = all[(i + d + all.count) % all.count]
        case .songSpeed:
            let v = app.settings.modifiers.songSpeed + Double(d) * 0.05
            app.settings.modifiers.songSpeed = min(3, max(0.25, (v * 20).rounded() / 20))
        case .modifiers, .play:
            break
        }
    }

    private func select(_ i: Instrument) {
        instrument = i
        let ds = song.difficulties(for: i)
        difficulty = ds.contains(app.settings.lastDifficulty) ? app.settings.lastDifficulty : (ds.last ?? .expert)
    }

    private func loadSections() {
        let s = song
        Task.detached {
            let secs = (try? SongLoader.loadChart(entry: s).0.sections) ?? []
            await MainActor.run {
                sections = secs
                startSection = 0
                endSection = max(0, secs.count - 1)
            }
        }
    }

    private var mods: Binding<Modifiers> { $app.settings.modifiers }

    /// Clone Hero's modifiers, right under the difficulty picker.
    /// Only the modifiers that are on; tap (or green) opens the full list.
    @ViewBuilder private var modifierSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            let active = app.settings.modifiers.activeNames.filter { !$0.hasSuffix("% speed") }
            Button { showMods = true } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SectionLabel("Modifiers")
                        Spacer()
                        Label(active.isEmpty ? "Add" : "Edit", systemImage: active.isEmpty ? "plus.circle" : "slider.horizontal.3").font(.caption.bold()).foregroundStyle(Theme.accent)
                    }
                    if active.isEmpty {
                        Text("None").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ChipLayout(spacing: 6) {
                            ForEach(active, id: \.self) { n in
                                Chip(text: n, warn: n == "Drunk")
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .focusRing(isFocused(.modifiers), inset: -6)
            if !active.isEmpty {
                Button("Clear modifiers") {
                    let speed = app.settings.modifiers.songSpeed
                    let kick = app.settings.modifiers.twoXKick
                    app.settings.modifiers = Modifiers()
                    app.settings.modifiers.songSpeed = speed
                    app.settings.modifiers.twoXKick = kick
                }
                .font(.caption.bold())
            }
            if !practice {
                SliderRow(title: "Song speed", value: mods.songSpeed, range: 0.25...3.0, step: 0.05, format: { "\(Int(($0 * 100).rounded()))%" })
                    .focusRing(isFocused(.songSpeed), inset: -6)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.Surface.card))
    }

    @ViewBuilder private var practiceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Practice")
            if sections.isEmpty {
                Text("This chart has no sections; the whole song will loop.").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Start", selection: $startSection) {
                    ForEach(sections.indices, id: \.self) { i in Text("\(i + 1). \(sections[i].name)").tag(i) }
                }
                Picker("End", selection: $endSection) {
                    ForEach(sections.indices.filter { $0 >= startSection }, id: \.self) { i in Text("\(i + 1). \(sections[i].name)").tag(i) }
                }
            }
            SliderRow(title: "Song speed", value: $app.settings.practiceSpeed, range: 0.25...3.0, step: 0.05, format: { "\(Int(($0 * 100).rounded()))%" })
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.Surface.card))
    }
}

/// Clone Hero's modifier list plus the speed settings.
struct ModifiersView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    var kind: InstrumentKind
    var practice: Bool
    /// Whose settings to edit (default: player 1's).
    var mods: Binding<Modifiers>? = nil
    var noteSpeed: Binding<Double>? = nil
    var highwayLength: Binding<Double>? = nil

    private var m: Binding<Modifiers> { mods ?? $app.settings.modifiers }

    private var rows: [NavRow] {
        func t(_ id: String, _ sec: String, _ title: String, _ detail: String, _ b: Binding<Bool>) -> NavRow {
            NavRow(id: id, section: sec, title: title, detail: detail, kind: .toggle(b))
        }
        var r: [NavRow] = [
            NavRow(id: "ss", section: "Speed", title: "Song speed", kind: .slider(practice && mods == nil ? $app.settings.practiceSpeed : m.songSpeed, 0.25...3.0, step: 0.05, format: { "\(Int(($0 * 100).rounded()))%" })),
            NavRow(id: "ns", section: "Speed", title: "Track (note) speed", kind: .slider(noteSpeed ?? $app.settings.noteSpeed, 0.25...10, step: 0.05, format: { String(format: "%.2f×", $0) })),
            NavRow(id: "hl", section: "Speed", title: "Highway length", kind: .slider(highwayLength ?? $app.settings.highwayLength, 0.5...10, step: 0.05, format: { String(format: "%.2f×", $0) })),
        ]
        if kind != .drums {
            r += [
                t("auto", "Guitar", "Auto Strum", "Strums for you — just fret. Scores are still saved.", m.autoStrum),
                .pick("notes", "Guitar", "Note type", detail: "All Taps is recommended for keyboard and touch players.", options: Modifiers.NoteMod.allCases, label: { $0.displayName }, selection: m.notes),
                t("h2t", "Guitar", "HOPOs to Taps", "Turns all HOPO notes into tap notes.", m.hoposToTaps),
                t("prec", "Guitar", "Precision Mode", "Smaller hit window that shrinks as the notes get faster; stricter HOPOs and taps.", m.precision),
                t("drunk", "Guitar", "Drunk Mode", "Easier HOPOs and taps, anchoring in both directions. Disables score saving.", m.drunk),
                t("brutal", "Guitar", "Brutal Mode", "Notes fade out past a point that gets closer the better you're doing.", m.brutal),
                t("dropless", "Guitar", "Dropless Sustains", "Let go of a sustain early and you lose your combo.", m.droplessSustains),
                t("strumless", "Guitar", "Strumless HOPOs", "Strumming a HOPO or tap is an overstrum.", m.strumlessHopos),
                t("double", "Guitar", "Double Notes", "Adds a note to each note or chord, up to 3.", m.doubleNotes),
                t("noghost", "Guitar", "No Ghosting", "Blocks ghosting frets between HOPOs, to a degree.", m.noGhosting),
                t("deadghost", "Guitar", "Deadly Ghosting", "Ghosting too much breaks your combo.", m.deadlyGhosting),
            ]
        } else {
            r += [
                t("prec", "Drums", "Precision Mode", "Smaller hit window that shrinks further than normal.", m.precision),
                t("brutal", "Drums", "Brutal Mode", "Notes fade out past a point that gets closer the better you're doing.", m.brutal),
                t("dyn", "Drums", "Deadly Dynamics", "Accents must be hit hard and ghost notes soft (velocity-sensitive kits).", m.deadlyDynamics),
                t("2x", "Drums", "2x Kick", "Include Expert+ double-kick notes.", m.twoXKick),
                t("nokick", "Drums", "No Kick", "Removes kick notes.", m.noKick),
                t("onlykick", "Drums", "Only Kicks", "Turns every note into a kick.", m.onlyKicks),
            ]
        }
        r += [
            t("mirror", "Chart", "Mirror Mode", "Mirrors the chart without mirroring the strikeline.", m.mirror),
            t("shuffle", "Chart", "Note Shuffle", "Randomizes note placement — the same way every time.", m.shuffle),
            t("lights", "Display", "Lights Out", "Hides the highway, including the notes.", m.lightsOut),
            .pick("modchart", "Display", "Modchart", options: Modifiers.Modchart.allCases, label: { $0.displayName }, selection: m.modchart),
            NavRow(id: "reset", section: "Reset", title: "Reset all modifiers", kind: .button(destructive: true) {
                let speed = practice ? m.wrappedValue.songSpeed : 1
                m.wrappedValue = Modifiers()
                m.wrappedValue.songSpeed = speed
            }),
        ]
        return r
    }

    var body: some View {
        NavigationStack {
            NavForm(rows: rows, onBack: { dismiss() })
                .sheetChrome("Modifiers") { dismiss() }
        }
    }
}
