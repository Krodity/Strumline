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

    @State private var instrument: Instrument = .guitar
    @State private var difficulty: Difficulty = .expert
    @State private var sections: [ChartSection] = []
    @State private var startSection = 0
    @State private var endSection = 0
    @State private var showMods = false

    @State private var page = 0
    /// Controller focus row: see `focusRows`.
    @State private var focusRow: FocusRow = .play

    enum FocusRow: Hashable { case instrument, difficulty, kit, modifiers, songSpeed, noteSpeed, play }

    private var focusRows: [FocusRow] {
        var r: [FocusRow] = [.instrument, .difficulty]
        if instrument == .drums { r.append(.kit) }
        r.append(.modifiers)
        if !practice { r.append(.songSpeed) }
        r.append(.noteSpeed)
        r.append(.play)
        return r
    }

    private func ring(_ row: FocusRow) -> some View {
        RoundedRectangle(cornerRadius: 14)
            .stroke(Palette.orange, lineWidth: focused && focusRow == row ? 2.5 : 0)
            .padding(-6)
    }
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
                            ScrollView {
                                VStack(alignment: .leading, spacing: 12) {
                                    modifierSection.id("p2")
                                    warningView
                                    playButton.id("p3")
                                }
                                .padding(14)
                            }
                        }
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                topBar
                                headerView(compact: false).id("p0")
                                partsView.id("p1")
                                modifierSection.id("p2")
                                if practice { practiceControls }
                                warningView
                                playButton.id("p3")
                            }
                            .padding(20)
                        }
                    }
                }
                .onAppear { scroller = proxy }
            }
        }
        .onChange(of: focused) { _, f in if f { installMenuHandler() } }
        .onChange(of: showMods) { _, open in if !open && focused { installMenuHandler() } }
        .onAppear {
            if focused { installMenuHandler() }
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
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, -10)
        }
        if focused && !InputManager.shared.devices.allSatisfy({ $0.kind == .touch }) {
            Label("↑↓ move · ←→ change · green selects (Modifiers opens the full list) · red closes", systemImage: "gamecontroller")
                .font(.caption2).foregroundStyle(.secondary)
        }
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
                Text("Instrument").font(.caption.bold()).foregroundStyle(.secondary)
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
                                .background(RoundedRectangle(cornerRadius: 12).fill(instrument == i ? Palette.orange.opacity(0.35) : Color.white.opacity(0.08)))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(instrument == i ? Palette.orange : .clear, lineWidth: 2))
                            }
                            .foregroundStyle(.white)
                        }
                    }
                }
            }
            .overlay(ring(.instrument))

            // Difficulty
            VStack(alignment: .leading, spacing: 8) {
                Text("Difficulty").font(.caption.bold()).foregroundStyle(.secondary)
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
                            .background(RoundedRectangle(cornerRadius: 10).fill(difficulty == d ? Palette.orange.opacity(0.35) : Color.white.opacity(0.08)))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(difficulty == d ? Palette.orange : .clear, lineWidth: 2))
                        }
                        .foregroundStyle(.white)
                    }
                }
            }
            .overlay(ring(.difficulty))
            if instrument == .drums {
                Picker("Drum kit", selection: $app.settings.drumMode) {
                    ForEach(DrumPlayMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .overlay(ring(.kit))
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
        playButtonBody.overlay(ring(.play))
    }

    private var playButtonBody: some View {
        Button { start() } label: {
            Label(practice ? "Practice" : "Play", systemImage: "play.fill")
                .font(.system(size: 20, weight: .black, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: [Palette.orange, Palette.red], startPoint: .leading, endPoint: .trailing)))
        }
        .foregroundStyle(.white)
        .disabled(song.difficulties(for: instrument).isEmpty)
    }

    /// Controllers can't drag a scroll view: page through the sections.
    private func turnPage(_ delta: Int) {
        page = max(0, min(3, page + delta))
        withAnimation { scroller?.scrollTo("p\(page)", anchor: .top) }
    }

    private func start() {
        guard !song.difficulties(for: instrument).isEmpty else { return }
        let p = practice ? PracticeRange(startSection: startSection, endSection: max(startSection, endSection)) : nil
        let (i, d) = (instrument, difficulty)
        if inSheet {
            onClose()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                app.play(song: song, instrument: i, difficulty: d, practice: p)
            }
        } else {
            app.play(song: song, instrument: i, difficulty: d, practice: p)
        }
    }

    /// ↑↓ moves between rows, ←→ changes the highlighted row, green
    /// selects (plays on Play, opens Modifiers), red closes.
    private func installMenuHandler() {
        InputManager.shared.menuHandler = { a in
            guard let nav = MenuNav(a) else { return }
            let rows = focusRows
            let idx = rows.firstIndex(of: focusRow) ?? rows.count - 1
            switch nav {
            case .up, .down:
                let n = max(0, min(rows.count - 1, idx + (nav == .down ? 1 : -1)))
                focusRow = rows[n]
                let target = [FocusRow.instrument, .difficulty, .kit].contains(focusRow) ? "p1" : focusRow == .play ? "p3" : "p2"
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
        case .noteSpeed:
            let v = app.settings.noteSpeed + Double(d) * 0.25
            app.settings.noteSpeed = min(10, max(0.25, (v * 4).rounded() / 4))
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
                        Text("Modifiers").font(.caption.bold()).foregroundStyle(.secondary)
                        Spacer()
                        Label(active.isEmpty ? "Add" : "Edit", systemImage: "plus.circle").font(.caption.bold()).foregroundStyle(Palette.orange)
                    }
                    if active.isEmpty {
                        Text("None").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ChipLayout(spacing: 6) {
                            ForEach(active, id: \.self) { n in
                                let warn = n == "Drunk"
                                Text(n).font(.caption.bold()).lineLimit(1)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Capsule().fill(warn ? Palette.yellow.opacity(0.35) : Palette.orange.opacity(0.4)))
                                    .overlay(Capsule().stroke(warn ? Palette.yellow : Palette.orange, lineWidth: 1.5))
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .overlay(ring(.modifiers))
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
                    .overlay(ring(.songSpeed))
            }
            SliderRow(title: "Track (note) speed", value: $app.settings.noteSpeed, range: 0.25...10, step: 0.05, format: { String(format: "%.2f×", $0) })
                .overlay(ring(.noteSpeed))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
    }

    @ViewBuilder private var practiceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Practice").font(.caption.bold()).foregroundStyle(.secondary)
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
            SliderRow(title: "Song speed", value: $app.settings.modifiers.songSpeed, range: 0.25...1.5, step: 0.05, format: { "\(Int(($0 * 100).rounded()))%" })
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
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
            NavRow(id: "ss", section: "Speed", title: "Song speed", kind: .slider(m.songSpeed, 0.25...3.0, step: 0.05, format: { "\(Int(($0 * 100).rounded()))%" })),
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
            NavRow(id: "done", section: "Reset", title: "Done", kind: .button(destructive: false) { dismiss() }),
        ]
        return r
    }

    var body: some View {
        NavigationStack {
            NavForm(rows: rows, onBack: { dismiss() })
                .navigationTitle("Modifiers")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Toggle chip for one modifier.
struct ModChip: View {
    var title: String
    @Binding var on: Bool
    var warn = false
    init(_ title: String, _ on: Binding<Bool>, warn: Bool = false) {
        self.title = title
        _on = on
        self.warn = warn
    }
    var body: some View {
        Button { on.toggle() } label: {
            HStack(spacing: 4) {
                if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .black)) }
                Text(title).font(.caption.bold()).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(on ? (warn ? Palette.yellow.opacity(0.35) : Palette.orange.opacity(0.4)) : Color.white.opacity(0.08)))
            .overlay(Capsule().stroke(on ? (warn ? Palette.yellow : Palette.orange) : Color.white.opacity(0.15), lineWidth: 1.5))
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }
}
