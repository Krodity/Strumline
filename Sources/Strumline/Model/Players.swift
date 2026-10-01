import SwiftUI
import StrumCore

/// A local player, like Clone Hero's profiles on the bottom bar. Player 1's
/// part choices and highway settings live in `GameSettings`; players 2-4
/// keep their own here.
struct PlayerProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Input device id (InputDevice.id). nil = any device not claimed by
    /// another player (player 1 only).
    var deviceID: String?
    var deviceName: String?
    var instrument: Instrument = .guitar
    var difficulty: Difficulty = .expert
    var noteSpeed: Double = 1.0
    var highwayLength: Double = 1.0
    var highwayScale: Double = 1.0
    var highwayImage: String? = nil
    var leftyFlip = false
    var drumMode: DrumPlayMode = .fourLanePro
    var modifiers = Modifiers()

    static let colors: [Color] = [Palette.orange, Palette.blue, Palette.green, Palette.red, Palette.yellow, Palette.open]
}

extension AppModel {
    static let maxPlayers = 6

    /// The effective settings for player `i` (audio/calibration are shared).
    func settings(forPlayer i: Int) -> GameSettings {
        guard i > 0, i < players.count else { return settings }
        let p = players[i]
        var s = settings
        s.noteSpeed = p.noteSpeed
        s.highwayLength = p.highwayLength
        s.highwayScale = p.highwayScale
        s.highwayImage = p.highwayImage
        s.leftyFlip = p.leftyFlip
        s.drumMode = p.drumMode
        var m = p.modifiers
        m.songSpeed = settings.modifiers.songSpeed  // one song, one speed
        s.modifiers = m
        s.lastInstrument = p.instrument
        s.lastDifficulty = p.difficulty
        s.showTouchControls = p.deviceID == InputDevice.touchID
        return s
    }

    func instrument(forPlayer i: Int) -> Instrument { i == 0 || i >= players.count ? settings.lastInstrument : players[i].instrument }
    func difficulty(forPlayer i: Int) -> Difficulty { i == 0 || i >= players.count ? settings.lastDifficulty : players[i].difficulty }

    /// Start pressed on a device no player owns → a new player on it.
    func join(device: String) -> Bool {
        if players.contains(where: { $0.deviceID == device }) { return false }
        guard players.count < AppModel.maxPlayers else { return false }
        // With one player on "any device", Start on the keyboard/touch is
        // just player 1; only a second physical device joins someone new.
        if players.count == 1 && players[0].deviceID == nil && (device == InputDevice.keyboardID || device == InputDevice.touchID) {
            return false
        }
        addPlayer(device: device)
        return true
    }

    func addPlayer(device: String?) {
        guard players.count < AppModel.maxPlayers else { return }
        // Only player 1 can take "any device": anyone else needs a device of
        // their own or nothing they press reaches them. Added by tapping the
        // bar, that's the first unclaimed one (normally the touchscreen).
        var device = device
        if device == nil && !players.isEmpty {
            let claimed = Set(players.compactMap(\.deviceID))
            device = InputManager.shared.devices.map(\.id).first { !claimed.contains($0) }
        }
        let name = InputManager.shared.devices.first { $0.id == device }?.name
        var p = PlayerProfile(name: "Player \(players.count + 1)", deviceID: device, deviceName: name)
        p.instrument = settings.lastInstrument
        p.difficulty = settings.lastDifficulty
        players.append(p)
        AudioEngine.shared.play(.spReady)
    }

    func removePlayer(_ i: Int) {
        guard i > 0, i < players.count else { return }
        players.remove(at: i)
        for j in players.indices where j > 0 && players[j].name.hasPrefix("Player ") { players[j].name = "Player \(j + 1)" }
    }

    /// Device → player index for gameplay. Unclaimed devices go to player 1
    /// if player 1 takes "any device".
    func deviceRouting() -> (map: [String: Int], fallback: Int?) {
        var map: [String: Int] = [:]
        for (i, p) in players.enumerated() { if let d = p.deviceID { map[d] = i } }
        return (map, players.first?.deviceID == nil ? 0 : nil)
    }
}

// MARK: - Bottom bar

/// Clone Hero-style player strip: one slot per player, "Press Start to
/// join" for the rest. Tap a slot for that player's settings.
struct PlayerBar: View {
    @EnvironmentObject var app: AppModel
    @State private var editing: Int?
    /// Player who chose Leave in their sheet; removed in the sheet's onDismiss.
    @State private var leaving: Int?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(app.players.indices, id: \.self) { i in
                    slot(i).frame(width: 128)
                        .focusRing(app.playerBarFocus == i, radius: Theme.Radius.medium)
                }
                if app.players.count < AppModel.maxPlayers {
                    Button { app.addPlayer(device: nil); editing = app.players.count - 1 } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "plus.circle").font(.system(size: 15))
                            // "Start" only means something with a controller or keyboard.
                            Text(InputManager.shared.hasPhysicalInput ? "Add player\nor press Start" : "Add player")
                                .font(.system(size: 10, weight: .semibold)).multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 110, height: 50)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.Surface.stroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    .focusRing(app.playerBarFocus == app.players.count, radius: Theme.Radius.medium)
                }
            }
        }
        // A horizontal ScrollView is vertically greedy: pin the bar's height
        // or it covers (and eats taps for) the screen above it.
        .frame(height: 54)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.35))
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: app.playerBarOpen) { _, i in
            guard let i else { return }
            app.playerBarOpen = nil
            if i >= app.players.count { app.addPlayer(device: nil) }
            editing = min(i, app.players.count - 1)
        }
        .sheet(item: Binding(get: { editing.map { EditIndex(id: $0) } }, set: { editing = $0?.id }), onDismiss: {
            // A player who chose Leave is removed only once their sheet is gone
            // (removing the slot while the sheet still read it crashed).
            if let i = leaving { leaving = nil; app.removePlayer(i) }
        }) { e in
            PlayerSettingsSheet(index: e.id, onLeave: { leaving = $0 }).environmentObject(app)
        }
    }

    private struct EditIndex: Identifiable { var id: Int }

    @ViewBuilder private func slot(_ i: Int) -> some View {
        if i < app.players.count { slotBody(i) }
    }

    private func slotBody(_ i: Int) -> some View {
        let p = app.players[i]
        let inst = app.instrument(forPlayer: i)
        let diff = app.difficulty(forPlayer: i)
        return Button { editing = i } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(PlayerProfile.colors[i % 6]).frame(width: 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).font(.system(size: 12, weight: .bold)).lineLimit(1)
                    HStack(spacing: 3) {
                        Image(systemName: inst.symbol).font(.system(size: 9))
                        Text(diff.displayName).font(.system(size: 10))
                    }
                    .foregroundStyle(.secondary)
                    Text(deviceLabel(p)).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(PlayerProfile.colors[i % 6].opacity(0.15)))
        }
        .foregroundStyle(.white)
    }

    private func deviceLabel(_ p: PlayerProfile) -> String {
        guard let d = p.deviceID else { return "Any input" }
        if d == InputDevice.touchID { return "Touch" }
        if d == InputDevice.keyboardID { return "Keyboard" }
        return InputManager.shared.devices.first { $0.id == d }?.name ?? p.deviceName ?? "Disconnected"
    }
}

struct PlayerSettingsSheet: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject private var input = InputManager.shared
    @Environment(\.dismiss) private var dismiss
    let index: Int
    /// Marks this player to be removed when the sheet closes.
    var onLeave: (Int) -> Void = { _ in }
    @State private var showMods = false

    private var valid: Bool { index < app.players.count }

    private var rows: [NavRow] {
        var devIDs: [String?] = index == 0 ? [nil] : []
        devIDs += input.devices.map { Optional($0.id) }
        let devName: (String?) -> String = { id in
            guard let id else { return "Any device" }
            let n = input.devices.first { $0.id == id }?.name ?? "Disconnected"
            return n + (claimed(id) ? " (taken)" : "")
        }
        var r: [NavRow] = [
            NavRow(id: "name", section: "Player", title: "Name", kind: .text(profile(\.name, ""))),
            .pick("dev", "Player", "Input device", options: devIDs, label: devName, selection: profile(\.deviceID, nil)),
            .pick("inst", "Part", "Instrument", options: Instrument.allCases, label: { $0.displayName }, selection: instrument),
            .pick("diff", "Part", "Difficulty", options: Difficulty.allCases, label: { $0.displayName }, selection: difficulty),
        ]
        if instrument.wrappedValue == .drums {
            r.append(.pick("kit", "Part", "Drum kit", options: DrumPlayMode.allCases, label: { $0.displayName }, selection: drumMode))
        }
        r += [
            NavRow(id: "ns", section: "Highway", title: "Track (note) speed", kind: .slider(noteSpeed, 0.25...10, step: 0.05, format: { String(format: "%.2f×", $0) })),
            NavRow(id: "hl", section: "Highway", title: "Highway length", kind: .slider(highwayLength, 0.5...10, step: 0.05, format: { String(format: "%.2f×", $0) })),
            NavRow(id: "hs", section: "Highway", title: "Highway scale", kind: .slider(highwayScale, 0.5...1.5, step: 0.05, format: { "\(Int(($0 * 100).rounded()))%" })),
            .pick("hwimg", "Highway", "Highway image", detail: "Add images in Settings › Custom Content.", options: [String?.none] + CustomAssets.highwayFiles.map { Optional($0) }, label: { $0.map { ($0 as NSString).deletingPathExtension } ?? "Default" }, selection: highwayImage),
            NavRow(id: "lefty", section: "Highway", title: "Lefty flip", kind: .toggle(lefty)),
            NavRow(id: "mods", section: "Modifiers", title: "Modifiers…", detail: modifiers.wrappedValue.activeNames.joined(separator: ", ").nilIfEmpty, kind: .button(destructive: false) { showMods = true }),
        ]
        if index > 0 {
            r.append(NavRow(id: "leave", section: "Leave", title: "Leave", kind: .button(destructive: true) {
                onLeave(index)
                dismiss()
            }))
        }
        return r
    }

    var body: some View {
        NavigationStack {
            if valid {
                NavForm(rows: rows, onBack: { dismiss() })
                    .sheetChrome(index < app.players.count ? app.players[index].name : "Player") { dismiss() }
                    .sheet(isPresented: $showMods) {
                        ModifiersView(kind: instrument.wrappedValue.kind, mods: modifiers)
                            .environmentObject(app)
                    }
            }
        }
    }

    private func claimed(_ id: String) -> Bool { app.players.enumerated().contains { $0.offset != index && $0.element.deviceID == id } }

    /// Bounds-checked binding into this player's profile (the player can be
    /// removed while the sheet is still animating away).
    private func profile<T>(_ kp: WritableKeyPath<PlayerProfile, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { index < app.players.count ? app.players[index][keyPath: kp] : fallback },
                set: { v in if index < app.players.count { app.players[index][keyPath: kp] = v } })
    }

    // Player 1 reads/writes GameSettings; the others their profile.
    private func bind<T>(_ p1: WritableKeyPath<GameSettings, T>, _ other: WritableKeyPath<PlayerProfile, T>) -> Binding<T> {
        Binding(
            get: { index == 0 || index >= app.players.count ? app.settings[keyPath: p1] : app.players[index][keyPath: other] },
            set: { v in if index == 0 { app.settings[keyPath: p1] = v } else if index < app.players.count { app.players[index][keyPath: other] = v } })
    }
    private var instrument: Binding<Instrument> { bind(\.lastInstrument, \.instrument) }
    private var difficulty: Binding<Difficulty> { bind(\.lastDifficulty, \.difficulty) }
    private var drumMode: Binding<DrumPlayMode> { bind(\.drumMode, \.drumMode) }
    private var noteSpeed: Binding<Double> { bind(\.noteSpeed, \.noteSpeed) }
    private var highwayLength: Binding<Double> { bind(\.highwayLength, \.highwayLength) }
    private var highwayScale: Binding<Double> { bind(\.highwayScale, \.highwayScale) }
    private var highwayImage: Binding<String?> { bind(\.highwayImage, \.highwayImage) }
    private var lefty: Binding<Bool> { bind(\.leftyFlip, \.leftyFlip) }
    private var modifiers: Binding<Modifiers> { bind(\.modifiers, \.modifiers) }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
