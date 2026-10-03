import SwiftUI
import PhotosUI
import _PhotosUI_SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import QuartzCore
import StrumCore

/// Settings hub: a short list of pages instead of one 30-row list.
struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @State private var page: SettingsPage?
    /// The reset confirmation (type-the-code) sheet.
    @State private var confirmingReset = false

    private var rows: [NavRow] {
        let s = app.settings
        func open(_ p: SettingsPage, _ detail: String) -> NavRow {
            NavRow(id: p.rawValue, section: "Settings", title: p.title, detail: detail, symbol: p.symbol, kind: .button(destructive: false) { page = p })
        }
        return [
            open(.gameplay, "Hit window \(Int(s.hitWindowMs)) ms · Lefty \(s.leftyFlip ? "on" : "off")"),
            open(.audio, "Volumes, offsets, calibration"),
            open(.display, "Track speed \(Fmt.times(s.noteSpeed)) · backgrounds"),
            open(.touch, s.showTouchControls ? s.touchMode.displayName : "On-screen controls off"),
            open(.custom, "Highway images, backgrounds, wallpaper"),
            open(.controls, "Bindings for keyboard, controllers and kits"),
            NavRow(id: "reset", section: "Reset", title: "Reset settings…", detail: "Asks you to confirm with a code", symbol: "arrow.counterclockwise", kind: .button(destructive: true) {
                confirmingReset = true
            }),
        ]
    }

    var body: some View {
        NavForm(rows: rows, onBack: { app.screen = .menu })
            .screenChrome("Settings") { app.screen = .menu }
            .navigationDestination(item: $page) { p in
                if p == .controls {
                    ControlsView(onBack: { page = nil })
                } else {
                    SettingsPageView(page: p, onBack: { page = nil })
                }
            }
            .sheet(isPresented: $confirmingReset) {
                ResetSettingsSheet().environmentObject(app)
            }
    }
}

enum SettingsPage: String, Hashable, Identifiable {
    case gameplay, audio, display, touch, custom, controls
    var id: String { rawValue }
    var title: String {
        switch self {
        case .gameplay: return "Gameplay"
        case .audio: return "Audio & Timing"
        case .display: return "Highway & Display"
        case .touch: return "Touch"
        case .custom: return "Custom Content"
        case .controls: return "Controls"
        }
    }
    var symbol: String {
        switch self {
        case .gameplay: return "guitars"
        case .audio: return "speaker.wave.2.fill"
        case .display: return "road.lanes"
        case .touch: return "hand.tap.fill"
        case .custom: return "photo.on.rectangle"
        case .controls: return "gamecontroller.fill"
        }
    }
}

/// One settings page. Each page owns its own sheets and importers, so they
/// present from the screen that's actually showing.
struct SettingsPageView: View {
    @EnvironmentObject var app: AppModel
    let page: SettingsPage
    var onBack: () -> Void

    @State private var calibrating = false
    @State private var importing = false
    /// Where imports go: highway images or backgrounds.
    @State private var importTarget = ImportTarget.highway
    /// Bumped after an import so the file lists refresh.
    @State private var refresh = 0
    @State private var photosOpen = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importNote: String?

    enum ImportTarget: String, CaseIterable {
        case highway, background
        var title: String { self == .highway ? "Highway image" : "Background (image or video)" }
        var dir: URL { self == .highway ? CustomAssets.highways : CustomAssets.backgrounds }
        var types: [UTType] { self == .highway ? [.image] : [.image, .movie] }
        var photos: PHPickerFilter { self == .highway ? .images : .any(of: [.images, .videos]) }
    }


    private var rows: [NavRow] {
        let s = $app.settings
        switch page {
        case .gameplay:
            return [
                NavRow(id: "hw", section: "Judging", title: "Hit window", detail: "Clone Hero uses 140 ms.", kind: .slider(s.hitWindowMs, 80...200, step: 5, format: Fmt.ms)),
                NavRow(id: "timing", section: "Judging", title: "Show hit timing", detail: "Early/late marks under the strikeline.", kind: .toggle(s.showHitTiming)),
                NavRow(id: "lefty", section: "Player 1", title: "Lefty flip", kind: .toggle(s.leftyFlip)),
                NavRow(id: "info", section: "Player 1", title: "Drum kit, part and difficulty are picked per song; other players set theirs in the player bar.", kind: .info),
            ]
        case .audio:
            return [
                NavRow(id: "mv", section: "Volume", title: "Band / music", kind: .slider(s.musicVolume, 0...1, step: 0.05, format: Fmt.percent)),
                NavRow(id: "iv", section: "Volume", title: "Your instrument", kind: .slider(s.instrumentVolume, 0...1, step: 0.05, format: Fmt.percent)),
                NavRow(id: "sv", section: "Volume", title: "Sound effects", kind: .slider(s.sfxVolume, 0...1, step: 0.05, format: Fmt.percent)),
                NavRow(id: "pv", section: "Volume", title: "Song previews", kind: .slider(s.previewVolume, 0...1, step: 0.05, format: Fmt.percent)),
                NavRow(id: "mute", section: "Misses", title: "Mute instrument on miss", kind: .toggle(s.muteOnMiss)),
                NavRow(id: "misssfx", section: "Misses", title: "Miss sounds", kind: .toggle(s.missSounds)),
                NavRow(id: "cal", section: "Timing", title: "Calibrate audio…", detail: "Tap along to clicks; sets the audio offset.", kind: .button(destructive: false) { calibrating = true }),
                NavRow(id: "ao", section: "Timing", title: "Audio offset", detail: "Raise it if you still have to hit early.", kind: .slider(s.audioOffsetMs, -300...300, step: 1, format: Fmt.ms)),
                NavRow(id: "vo", section: "Timing", title: "Video offset", detail: "Raise it if notes look late against the music.", kind: .slider(s.videoOffsetMs, -300...300, step: 1, format: Fmt.ms)),
            ]
        case .display:
            return [
                NavRow(id: "ns", section: "Highway", title: "Track (note) speed", kind: .slider(s.noteSpeed, 0.25...10, step: 0.05, format: Fmt.times)),
                NavRow(id: "hl", section: "Highway", title: "Highway length", kind: .slider(s.highwayLength, 0.5...10, step: 0.05, format: Fmt.times)),
                NavRow(id: "hs", section: "Highway", title: "Highway width", kind: .slider(s.highwayScale, 0.5...1.5, step: 0.05, format: Fmt.percent)),
                .pick("bgsrc", "Background", "Gameplay background", options: GameBackgroundSource.allCases, label: { $0.displayName }, selection: s.gameBackground),
                NavRow(id: "vid", section: "Background", title: "Song background videos", kind: .toggle(s.showVideos)),
                NavRow(id: "dim", section: "Background", title: "Background dim", kind: .slider(s.backgroundDim, 0...1, step: 0.05, format: Fmt.percent)),
                NavRow(id: "fps", section: "Debug", title: "Show FPS", kind: .toggle(s.showFPS)),
            ]
        case .touch:
            return [
                NavRow(id: "touch", section: "Touch", title: "On-screen controls", detail: "Turn off when using a controller or keyboard.", kind: .toggle(s.showTouchControls)),
                .pick("tl", "Touch", "Layout", detail: "Tap Lanes: tap a lane to fret and strum, slide for hammer-ons, tap beside the highway for opens. Frets + Strum: frets left, strum bar right.", options: TouchMode.allCases, label: { $0.displayName }, selection: s.touchMode),
                NavRow(id: "tilt", section: "Touch", title: "Flick phone for Star Power", kind: .toggle(s.tiltStarPower)),
            ]
        case .custom:
            return [
                .pick("hwimg", "Use", "Highway image", detail: "Player 1's highway (other players: tap them in the player bar).", options: [String?.none] + CustomAssets.highwayFiles.map { Optional($0) }, label: { $0.map { ($0 as NSString).deletingPathExtension } ?? "Default" }, selection: s.highwayImage),
                .pick("bgcustom", "Use", "Custom background", detail: "Image or looping video; Shuffle picks one per song.", options: [String?.none, CustomAssets.shuffle] + CustomAssets.backgroundFiles.map { Optional($0) }, label: { $0 == nil ? "None" : $0 == CustomAssets.shuffle ? "Shuffle" : ($0! as NSString).deletingPathExtension + (CustomAssets.isVideo($0!) ? " (video)" : "") }, selection: s.customBackground),
                .pick("wall", "Use", "Menu wallpaper", options: [String?.none] + CustomAssets.backgroundFiles.map { Optional($0) }, label: { $0.map { ($0 as NSString).deletingPathExtension + (CustomAssets.isVideo($0) ? " (video)" : "") } ?? "Default" }, selection: s.menuWallpaper),
                .pick("target", "Add", "Add to", options: ImportTarget.allCases, label: { $0.title }, selection: $importTarget),
                NavRow(id: "files", section: "Add", title: "From Files…", symbol: "folder", kind: .button(destructive: false) { importing = true }),
                NavRow(id: "photos", section: "Add", title: "From Photos…", detail: importNote, symbol: "photo", kind: .button(destructive: false) { photosOpen = true }),
                NavRow(id: "custominfo", section: "Add", title: "Or copy files into On My iPhone › Strumline › Custom › Highways / Backgrounds.", kind: .info),
            ]
        case .controls:
            return []  // shown by ControlsView
        }
    }

    var body: some View {
        NavForm(rows: rows, onBack: onBack)
            .screenChrome(page.title, back: "Settings", onBack: onBack)
            .sheet(isPresented: $calibrating) {
                CalibrationView().environmentObject(app)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: importTarget.types, allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    CustomAssets.importFiles(urls, into: importTarget.dir)
                    refresh += 1
                }
            }
            .photosPicker(isPresented: $photosOpen, selection: $photoItems, maxSelectionCount: 10, matching: importTarget.photos, preferredItemEncoding: .current)
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                let dir = importTarget.dir
                importNote = "Importing \(items.count)…"
                Task {
                    let n = await CustomAssets.importPhotos(items, into: dir)
                    await MainActor.run {
                        photoItems = []
                        importNote = "Imported \(n) from Photos"
                        refresh += 1
                    }
                }
            }
            .id(refresh)
    }
}

/// Double check before resetting settings: the player has to type a random
/// code shown on screen, so it can't happen by a stray tap or button press.
struct ResetSettingsSheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    /// New every time the sheet opens. No look-alikes (0/O, 1/I/L).
    @State private var code = ResetSettingsSheet.makeCode()
    @State private var typed = ""
    @FocusState private var fieldFocused: Bool

    static func makeCode(length: Int = 6) -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }

    private var matches: Bool {
        typed.trimmingCharacters(in: .whitespaces).uppercased() == code
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label("This resets every setting to its default.", systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Fonts.heading)
                        .foregroundStyle(Palette.yellow)
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel("Reset")
                            Text("Highway, timing and calibration, volumes, touch, backgrounds and wallpaper.")
                            SectionLabel("Kept").padding(.top, 6)
                            Text("Modifiers, controller and keyboard bindings, players, your library and scores.")
                        }
                        .font(.subheadline)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Type this code to confirm:").font(.subheadline).foregroundStyle(.secondary)
                        Text(code)
                            .font(.system(size: 34, weight: .heavy, design: .monospaced))
                            .kerning(6)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.Surface.card))
                            .accessibilityLabel("Code " + code.map(String.init).joined(separator: " "))
                        TextField("Code", text: $typed)
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .focused($fieldFocused)
                            .submitLabel(.done)
                            .onSubmit { if matches { reset() } }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.Surface.control))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium)
                                .stroke(matches ? Palette.green : typed.isEmpty ? .clear : Theme.Surface.stroke, lineWidth: 2))
                    }
                    Button(role: .destructive) { reset() } label: {
                        Label("Reset settings", systemImage: "arrow.counterclockwise")
                            .font(Theme.Fonts.button)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(matches ? Palette.red.opacity(0.85) : Theme.Surface.control))
                            .foregroundStyle(matches ? .white : .secondary)
                    }
                    .disabled(!matches)
                }
                .padding(20)
            }
            .navigationTitle("Reset Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .onAppear { fieldFocused = true }
        // Back / red on a controller cancels; nothing else can confirm.
        .menuNavigation { nav in if nav == .back { dismiss() } }
    }

    private func reset() {
        guard matches else { return }
        let mods = app.settings.modifiers
        app.settings = GameSettings()
        app.settings.modifiers = mods
        app.flushSettings()
        dismiss()
    }
}

/// Plays a click track at exact host times; you tap along and the average
/// error becomes the audio offset.
struct CalibrationView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var taps: [Double] = []
    @State private var running = false
    @State private var startHost: Double = 0
    private let interval = 0.5
    private let clicks = 24

    var body: some View {
        VStack(spacing: 20) {
            Text("Audio Calibration").font(.title2.bold())
            Text("Tap the pad in time with the clicks. Uses your current headphones or speaker, so calibrate with the ones you play on.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            ZStack {
                Circle().fill(running ? Theme.accent.opacity(0.8) : finished ? Palette.green.opacity(0.35) : Theme.Surface.control)
                Text(running ? "TAP" : finished ? "Done" : "Tap to start").font(.title.bold())
                TapPad { host in tap(host) }
            }
            .frame(width: 200, height: 200)
            if finished {
                Button("Again") { begin() }.font(.subheadline.bold())
            }
            Text(taps.isEmpty ? " " : "\(taps.count) taps · \(Int(average * 1000)) ms").monospacedDigit()
            HStack {
                Button("Cancel") { stop(); dismiss() }
                Spacer()
                Button("Apply \(Int(average * 1000)) ms") {
                    app.settings.audioOffsetMs = (average * 1000).rounded()
                    stop(); dismiss()
                }
                .disabled(taps.count < 6)
            }
        }
        .padding(30)
        .onDisappear { stop() }
    }

    private var average: Double {
        guard taps.count > 3 else { return 0 }
        // Median of the later taps (the first few are warm-up).
        let s = taps.dropFirst(3).sorted()
        return s[s.count / 2]
    }

    /// A run finished: further taps on the pad are ignored (so a stray tap
    /// can't wipe the result before Apply); "Again" starts over.
    private var finished: Bool { !running && taps.count >= 18 }

    private func tap(_ host: Double) {
        if finished { return }
        if !running { begin(); return }
        // Clicks are rendered at startHost + n·interval and heard after the
        // latency iOS reports; the remainder is what the offset corrects.
        let heard = startHost + AudioEngine.shared.outputLatency
        let rel = host - heard
        let nearest = (rel / interval).rounded() * interval
        taps.append(rel - nearest)
        if taps.count >= 18 { stop() }
    }

    private func begin() {
        taps = []
        running = true
        AudioEngine.shared.unload()
        startHost = CACurrentMediaTime() + 0.5
        AudioEngine.shared.scheduleTicks(startHost: startHost, count: clicks, interval: interval)
    }

    private func stop() {
        running = false
        AudioEngine.shared.stopSfx()
    }
}

/// Touch surface that reports the exact touch-down time.
struct TapPad: UIViewRepresentable {
    var onTap: (Double) -> Void
    func makeUIView(context: Context) -> PadView {
        let v = PadView()
        v.onTap = onTap
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ v: PadView, context: Context) { v.onTap = onTap }
    final class PadView: UIView {
        var onTap: ((Double) -> Void)?
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches { onTap?(t.timestamp) }
        }
    }
}
