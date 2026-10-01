import Foundation
import StrumCore

enum TouchMode: String, Codable, CaseIterable {
    /// Tap a lane to fret and strum in one go.
    case tap
    /// Hold frets on the left, strum on the right.
    case fretStrum
    var displayName: String { self == .tap ? "Tap Lanes" : "Frets + Strum Bar" }
}

struct GameSettings: Codable, Equatable {
    // Highway
    /// "Track speed" / hyperspeed: how fast notes scroll (1 = default).
    var noteSpeed: Double = 1.0
    /// How far up the screen the highway reaches (1 = default).
    var highwayLength: Double = 1.0
    /// Width of the highway (1 = default).
    var highwayScale: Double = 1.0
    var leftyFlip = false
    var showHitTiming = false
    var showFPS = false
    // Timing
    /// Extra audio delay beyond what iOS reports, in ms. Raise it if you
    /// have to hit early.
    var audioOffsetMs: Double = 0
    /// Display delay, in ms. Raise it if notes look late against the audio.
    var videoOffsetMs: Double = 0
    var hitWindowMs: Double = 140
    // Audio
    var musicVolume: Double = 0.9
    var instrumentVolume: Double = 1.0
    var sfxVolume: Double = 0.6
    var previewVolume: Double = 0.6
    var muteOnMiss = true
    var missSounds = true
    // Drums
    var drumMode: DrumPlayMode = .fourLanePro
    // Touch
    var touchMode: TouchMode = .tap
    var showTouchControls = true
    var tiltStarPower = true
    // Visuals
    var backgroundDim: Double = 0.55
    var showVideos = true
    /// Custom highway image (file in Custom/Highways), nil = default.
    var highwayImage: String? = nil
    var gameBackground: GameBackgroundSource = .song
    /// File in Custom/Backgrounds, CustomAssets.shuffle, or nil.
    var customBackground: String? = nil
    /// Menu wallpaper: file in Custom/Backgrounds or nil for the default.
    var menuWallpaper: String? = nil
    // Last choices
    var lastInstrument: Instrument = .guitar
    var lastDifficulty: Difficulty = .expert
    var modifiers = Modifiers()
    /// Practice mode's own song speed, so slowing a section down doesn't
    /// carry over into Quickplay (`modifiers.songSpeed`).
    var practiceSpeed: Double = 1.0
    var sort: SongSort = .artist

    static let key = "settings.v1"

    /// Decodes older saves: missing keys keep their defaults.
    init() {}
    init(from decoder: Decoder) throws {
        let d = GameSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? nil ?? def }
        noteSpeed = v(.noteSpeed, d.noteSpeed); highwayLength = v(.highwayLength, d.highwayLength); highwayScale = v(.highwayScale, d.highwayScale)
        leftyFlip = v(.leftyFlip, d.leftyFlip); showHitTiming = v(.showHitTiming, d.showHitTiming); showFPS = v(.showFPS, d.showFPS)
        audioOffsetMs = v(.audioOffsetMs, d.audioOffsetMs); videoOffsetMs = v(.videoOffsetMs, d.videoOffsetMs); hitWindowMs = v(.hitWindowMs, d.hitWindowMs)
        musicVolume = v(.musicVolume, d.musicVolume); instrumentVolume = v(.instrumentVolume, d.instrumentVolume); sfxVolume = v(.sfxVolume, d.sfxVolume)
        previewVolume = v(.previewVolume, d.previewVolume); muteOnMiss = v(.muteOnMiss, d.muteOnMiss); missSounds = v(.missSounds, d.missSounds)
        drumMode = v(.drumMode, d.drumMode); touchMode = v(.touchMode, d.touchMode); showTouchControls = v(.showTouchControls, d.showTouchControls)
        tiltStarPower = v(.tiltStarPower, d.tiltStarPower); backgroundDim = v(.backgroundDim, d.backgroundDim); showVideos = v(.showVideos, d.showVideos)
        lastInstrument = v(.lastInstrument, d.lastInstrument); lastDifficulty = v(.lastDifficulty, d.lastDifficulty)
        modifiers = v(.modifiers, d.modifiers); sort = v(.sort, d.sort); practiceSpeed = v(.practiceSpeed, d.practiceSpeed)
        highwayImage = v(.highwayImage, d.highwayImage); gameBackground = v(.gameBackground, d.gameBackground)
        customBackground = v(.customBackground, d.customBackground); menuWallpaper = v(.menuWallpaper, d.menuWallpaper)
    }

    static func load() -> GameSettings {
        guard let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(GameSettings.self, from: d) else { return GameSettings() }
        return s
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: GameSettings.key) }
    }

    var engineConfig: EngineConfig {
        var c = EngineConfig()
        c.hitWindow = hitWindowMs / 1000
        return c
    }
}

enum SongSort: String, Codable, CaseIterable {
    case title, artist, album, genre, year, charter, length, playlist, recent
    var displayName: String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album"
        case .genre: return "Genre"
        case .year: return "Year"
        case .charter: return "Charter"
        case .length: return "Length"
        case .playlist: return "Folder"
        case .recent: return "Recently Added"
        }
    }
}

// MARK: - Bindings

enum GameAction: String, Codable, CaseIterable, Identifiable {
    case fret1, fret2, fret3, fret4, fret5, fret6
    case strumUp, strumDown, starPower, whammy, tilt, pause
    case kick, padRed, padYellow, padBlue, padGreen, padOrange, cymYellow, cymBlue, cymGreen
    case menuUp, menuDown, menuConfirm, menuBack, menuLeft, menuRight, menuPageUp, menuPageDown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fret1: return "Green / Black 1"
        case .fret2: return "Red / Black 2"
        case .fret3: return "Yellow / Black 3"
        case .fret4: return "Blue / White 1"
        case .fret5: return "Orange / White 2"
        case .fret6: return "White 3 (6-fret)"
        case .strumUp: return "Strum Up"
        case .strumDown: return "Strum Down"
        case .starPower: return "Star Power"
        case .whammy: return "Whammy (axis)"
        case .tilt: return "Tilt"
        case .pause: return "Pause / Start"
        case .kick: return "Kick"
        case .padRed: return "Red Pad"
        case .padYellow: return "Yellow Pad"
        case .padBlue: return "Blue Pad"
        case .padGreen: return "Green Pad"
        case .padOrange: return "Orange Pad (5-lane)"
        case .cymYellow: return "Yellow Cymbal"
        case .cymBlue: return "Blue Cymbal"
        case .cymGreen: return "Green Cymbal"
        case .menuUp: return "Menu Up"
        case .menuDown: return "Menu Down"
        case .menuConfirm: return "Menu Confirm"
        case .menuBack: return "Menu Back"
        case .menuLeft: return "Menu Left"
        case .menuRight: return "Menu Right"
        case .menuPageUp: return "Menu Page Up"
        case .menuPageDown: return "Menu Page Down"
        }
    }

    static let guitar: [GameAction] = [.fret1, .fret2, .fret3, .fret4, .fret5, .fret6, .strumUp, .strumDown, .starPower, .whammy, .tilt, .pause]
    static let drums: [GameAction] = [.kick, .padRed, .padYellow, .padBlue, .padGreen, .padOrange, .cymYellow, .cymBlue, .cymGreen, .starPower, .pause]
    static let menu: [GameAction] = [.menuUp, .menuDown, .menuLeft, .menuRight, .menuPageUp, .menuPageDown, .menuConfirm, .menuBack]
}

enum InputBinding: Codable, Hashable {
    /// GCKeyCode raw value.
    case key(Int)
    /// Controller element alias (e.g. "Button A", "Direction Pad.up").
    case button(String)
    /// Controller axis alias; `positive` picks the direction for buttons made
    /// from an axis. Whammy uses the absolute value.
    case axis(String, positive: Bool)
    /// MIDI note number (any channel).
    case midi(Int)

    var label: String {
        switch self {
        case .key(let k): return "⌨︎ " + KeyNames.name(k)
        case .button(let b): return "🎮 " + b
        case .axis(let a, let p): return "🎮 \(a) \(p ? "+" : "−")"
        case .midi(let n): return "🥁 MIDI \(n) (\(KeyNames.drumName(n)))"
        }
    }
}

struct Bindings: Codable, Equatable {
    var map: [GameAction: [InputBinding]] = [:]

    static let key = "bindings.v1"

    static func load() -> Bindings {
        guard let d = UserDefaults.standard.data(forKey: key), var b = try? JSONDecoder().decode(Bindings.self, from: d) else { return .defaults }
        // Actions added in later versions get their default bindings.
        for (a, list) in Bindings.defaults.map where b.map[a] == nil { b.map[a] = list }
        return b
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Bindings.key) }
    }

    /// Keyboard like the classic "keyboard as guitar" layout, gamepad laid
    /// out like an Xbox 360 guitar (A/B/Y/X/LB, D-pad strum), General MIDI
    /// drum notes for electronic kits.
    static var defaults: Bindings {
        var m: [GameAction: [InputBinding]] = [:]
        // GCKeyCode values (USB HID usage IDs).
        let k1 = 0x1E, k2 = 0x1F, k3 = 0x20, k4 = 0x21, k5 = 0x22, k6 = 0x23
        m[.fret1] = [.key(k1), .key(0x3A), .button("Button A")]      // 1, F1
        m[.fret2] = [.key(k2), .key(0x3B), .button("Button B")]
        m[.fret3] = [.key(k3), .key(0x3C), .button("Button Y")]
        m[.fret4] = [.key(k4), .key(0x3D), .button("Button X")]
        m[.fret5] = [.key(k5), .key(0x3E), .button("Left Shoulder")]
        m[.fret6] = [.key(k6), .key(0x3F), .button("Right Shoulder")]
        m[.strumUp] = [.key(0x52), .button("Direction Pad.up")]       // Up arrow
        m[.strumDown] = [.key(0x51), .key(0x28), .button("Direction Pad.down")]  // Down, Return
        m[.starPower] = [.key(0xE5), .key(0x2A), .button("Button Options")]      // R-Shift, Delete
        m[.whammy] = [.axis("Right Thumbstick X Axis", positive: true)]
        m[.tilt] = [.button("Right Trigger")]
        m[.pause] = [.key(0x29), .key(0x2B), .button("Button Menu")]            // Esc, Tab
        m[.kick] = [.key(0x2C), .midi(36), .midi(35), .button("Left Trigger")]
        m[.padRed] = [.key(0x07), .midi(38), .midi(40), .midi(37), .button("Button B")]  // D
        m[.padYellow] = [.key(0x09), .midi(48), .midi(50), .button("Button Y")]          // F
        m[.padBlue] = [.key(0x0D), .midi(45), .midi(47), .button("Button X")]            // J
        m[.padGreen] = [.key(0x0E), .midi(41), .midi(43), .button("Button A")]           // K
        m[.padOrange] = [.key(0x0F)]                                                      // L
        m[.cymYellow] = [.key(0x08), .midi(42), .midi(46), .midi(44), .midi(22), .midi(26)]  // E
        m[.cymBlue] = [.key(0x0C), .midi(51), .midi(53), .midi(59)]                       // I
        m[.cymGreen] = [.key(0x12), .midi(49), .midi(57), .midi(52), .midi(55)]           // O
        m[.menuUp] = [.key(0x52), .button("Direction Pad.up")]
        m[.menuDown] = [.key(0x51), .button("Direction Pad.down")]
        m[.menuConfirm] = [.key(0x28), .button("Button A")]
        m[.menuBack] = [.key(0x29), .key(0x2A), .button("Button B")]
        m[.menuLeft] = [.key(0x50), .button("Direction Pad.left"), .axis("Left Thumbstick X Axis", positive: false)]
        m[.menuRight] = [.key(0x4F), .button("Direction Pad.right"), .axis("Left Thumbstick X Axis", positive: true)]
        // Page Up/Down, bumpers/shoulders, and a guitar's orange / 6th fret.
        m[.menuPageUp] = [.key(0x4B), .button("Left Trigger"), .axis("Right Thumbstick Y Axis", positive: true)]
        m[.menuPageDown] = [.key(0x4E), .button("Right Trigger"), .axis("Right Thumbstick Y Axis", positive: false)]
        m[.menuUp]?.append(.axis("Left Thumbstick Y Axis", positive: true))
        m[.menuDown]?.append(.axis("Left Thumbstick Y Axis", positive: false))
        return Bindings(map: m)
    }

    func actions(for b: InputBinding) -> [GameAction] {
        map.compactMap { $0.value.contains(b) ? $0.key : nil }
    }
}

enum KeyNames {
    static func name(_ code: Int) -> String {
        switch code {
        case 0x04...0x1D: return String(UnicodeScalar(UInt8(0x41 + code - 0x04)))
        case 0x1E...0x26: return String(code - 0x1D)
        case 0x27: return "0"
        case 0x28: return "Return"
        case 0x29: return "Esc"
        case 0x2A: return "Delete"
        case 0x2B: return "Tab"
        case 0x2C: return "Space"
        case 0x2D: return "-"
        case 0x2E: return "="
        case 0x2F: return "["
        case 0x30: return "]"
        case 0x33: return ";"
        case 0x34: return "'"
        case 0x36: return ","
        case 0x37: return "."
        case 0x38: return "/"
        case 0x3A...0x45: return "F\(code - 0x39)"
        case 0x4F: return "→"
        case 0x50: return "←"
        case 0x51: return "↓"
        case 0x52: return "↑"
        case 0xE0: return "L-Ctrl"
        case 0xE1: return "L-Shift"
        case 0xE2: return "L-Opt"
        case 0xE3: return "L-Cmd"
        case 0xE4: return "R-Ctrl"
        case 0xE5: return "R-Shift"
        case 0xE6: return "R-Opt"
        case 0xE7: return "R-Cmd"
        default: return String(format: "Key %02X", code)
        }
    }

    static func drumName(_ n: Int) -> String {
        switch n {
        case 35, 36: return "Kick"
        case 37: return "Side Stick"
        case 38, 40: return "Snare"
        case 42, 44, 22: return "Hi-Hat Closed"
        case 46, 26: return "Hi-Hat Open"
        case 41, 43: return "Floor Tom"
        case 45, 47: return "Mid Tom"
        case 48, 50: return "High Tom"
        case 49, 57, 52, 55: return "Crash"
        case 51, 53, 59: return "Ride"
        default: return "Note"
        }
    }
}
