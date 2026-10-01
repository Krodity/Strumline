import SwiftUI
import PhotosUI
import _PhotosUI_SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import QuartzCore
import StrumCore

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @State private var calibrating = false
    @State private var importing = false
    @State private var importDir: URL = CustomAssets.highways
    @State private var importTypes: [UTType] = [.image]
    /// Bumped after an import so the file lists refresh.
    @State private var refresh = 0
    @State private var photosOpen = false
    @State private var photosFilter: PHPickerFilter = .images
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importNote: String?
    /// Reset takes two presses: the first arms it.
    @State private var resetArmed = false

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    private func x(_ v: Double) -> String { String(format: "%.2f×", v) }
    private func ms(_ v: Double) -> String { "\(Int(v)) ms" }

    private var rows: [NavRow] {
        let s = $app.settings
        return [
            NavRow(id: "ns", section: "Highway", title: "Track (note) speed", kind: .slider(s.noteSpeed, 0.25...10, step: 0.05, format: x)),
            NavRow(id: "hl", section: "Highway", title: "Highway length", kind: .slider(s.highwayLength, 0.5...10, step: 0.05, format: x)),
            NavRow(id: "hs", section: "Highway", title: "Highway scale", kind: .slider(s.highwayScale, 0.5...1.5, step: 0.05, format: pct)),
            NavRow(id: "lefty", section: "Highway", title: "Lefty flip", kind: .toggle(s.leftyFlip)),
            NavRow(id: "timing", section: "Highway", title: "Show hit timing", kind: .toggle(s.showHitTiming)),
            NavRow(id: "fps", section: "Highway", title: "Show FPS", kind: .toggle(s.showFPS)),
            NavRow(id: "ao", section: "Timing", title: "Audio offset", detail: "Raise it if you still have to hit early (iOS already compensates for reported latency, including Bluetooth).", kind: .slider(s.audioOffsetMs, -300...300, step: 1, format: ms)),
            NavRow(id: "vo", section: "Timing", title: "Video offset", kind: .slider(s.videoOffsetMs, -300...300, step: 1, format: ms)),
            NavRow(id: "cal", section: "Timing", title: "Calibrate audio…", kind: .button(destructive: false) { calibrating = true }),
            NavRow(id: "hw", section: "Timing", title: "Hit window", detail: "Clone Hero uses 140 ms.", kind: .slider(s.hitWindowMs, 80...200, step: 5, format: ms)),
            NavRow(id: "mv", section: "Audio", title: "Band / music volume", kind: .slider(s.musicVolume, 0...1, step: 0.05, format: pct)),
            NavRow(id: "iv", section: "Audio", title: "Your instrument", kind: .slider(s.instrumentVolume, 0...1, step: 0.05, format: pct)),
            NavRow(id: "sv", section: "Audio", title: "Sound effects", kind: .slider(s.sfxVolume, 0...1, step: 0.05, format: pct)),
            NavRow(id: "pv", section: "Audio", title: "Song previews", kind: .slider(s.previewVolume, 0...1, step: 0.05, format: pct)),
            NavRow(id: "mute", section: "Audio", title: "Mute instrument on miss", kind: .toggle(s.muteOnMiss)),
            NavRow(id: "misssfx", section: "Audio", title: "Miss sounds", kind: .toggle(s.missSounds)),
            .pick("kit", "Drums", "Kit type", options: DrumPlayMode.allCases, label: { $0.displayName }, selection: s.drumMode),
            NavRow(id: "2x", section: "Drums", title: "2x Kick", kind: .toggle(s.modifiers.twoXKick)),
            NavRow(id: "touch", section: "Touch", title: "On-screen controls", detail: "Turn off when using a controller or keyboard.", kind: .toggle(s.showTouchControls)),
            .pick("tl", "Touch", "Touch layout", detail: "Tap Lanes: tap a lane to fret + strum, slide for hammer-ons, tap beside the highway for opens. Frets + Strum: frets left, strum bar right.", options: TouchMode.allCases, label: { $0.displayName }, selection: s.touchMode),
            NavRow(id: "tilt", section: "Touch", title: "Flick phone for Star Power", kind: .toggle(s.tiltStarPower)),
            .pick("hwimg", "Highway & backgrounds", "Highway image", detail: "Player 1's highway (other players: tap them in the player bar).", options: [String?.none] + CustomAssets.highwayFiles.map { Optional($0) }, label: { $0.map { ($0 as NSString).deletingPathExtension } ?? "Default" }, selection: s.highwayImage),
            .pick("bgsrc", "Highway & backgrounds", "Gameplay background", options: GameBackgroundSource.allCases, label: { $0.displayName }, selection: s.gameBackground),
            .pick("bgcustom", "Highway & backgrounds", "Custom background", detail: "Image or looping video; Shuffle picks one per song.", options: [String?.none, CustomAssets.shuffle] + CustomAssets.backgroundFiles.map { Optional($0) }, label: { $0 == nil ? "None" : $0 == CustomAssets.shuffle ? "Shuffle" : ($0! as NSString).deletingPathExtension + (CustomAssets.isVideo($0!) ? " (video)" : "") }, selection: s.customBackground),
            .pick("wall", "Highway & backgrounds", "Menu wallpaper", options: [String?.none] + CustomAssets.backgroundFiles.map { Optional($0) }, label: { $0.map { ($0 as NSString).deletingPathExtension + (CustomAssets.isVideo($0) ? " (video)" : "") } ?? "Default" }, selection: s.menuWallpaper),
            NavRow(id: "imphw", section: "Highway & backgrounds", title: "Import highway image…", kind: .button(destructive: false) { importDir = CustomAssets.highways; importTypes = [.image]; importing = true }),
            NavRow(id: "impbg", section: "Highway & backgrounds", title: "Import background image or video…", kind: .button(destructive: false) { importDir = CustomAssets.backgrounds; importTypes = [.image, .movie]; importing = true }),
            NavRow(id: "phhw", section: "Highway & backgrounds", title: "Highway image from Photos…", kind: .button(destructive: false) { importDir = CustomAssets.highways; photosFilter = .images; photosOpen = true }),
            NavRow(id: "phbg", section: "Highway & backgrounds", title: "Background from Photos (image or video)…", detail: importNote, kind: .button(destructive: false) { importDir = CustomAssets.backgrounds; photosFilter = .any(of: [.images, .videos]); photosOpen = true }),
            NavRow(id: "custominfo", section: "Highway & backgrounds", title: "Or copy files into On My iPhone › Strumline › Custom › Highways / Backgrounds.", kind: .info),
            NavRow(id: "dim", section: "Visuals", title: "Background dim", kind: .slider(s.backgroundDim, 0...1, step: 0.05, format: pct)),
            NavRow(id: "vid", section: "Visuals", title: "Song background videos", kind: .toggle(s.showVideos)),
            NavRow(id: "reset", section: "Reset", title: resetArmed ? "Press again to reset all settings" : "Reset settings", detail: resetArmed ? nil : "Modifiers and controls are kept", kind: .button(destructive: true) {
                guard resetArmed else { resetArmed = true; return }
                resetArmed = false
                let mods = app.settings.modifiers
                app.settings = GameSettings()
                app.settings.modifiers = mods
            }),
        ]
    }

    var body: some View {
        NavForm(rows: rows, onBack: { app.screen = .menu })
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { app.screen = .menu } label: { Label("Menu", systemImage: "chevron.left") }
                }
            }
            .sheet(isPresented: $calibrating) {
                CalibrationView().environmentObject(app)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: importTypes, allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    CustomAssets.importFiles(urls, into: importDir)
                    refresh += 1
                }
            }
            .photosPicker(isPresented: $photosOpen, selection: $photoItems, maxSelectionCount: 10, matching: photosFilter, preferredItemEncoding: .current)
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                let dir = importDir
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
                Circle().fill(running ? Palette.orange.opacity(0.8) : Color.white.opacity(0.15))
                Text(running ? "TAP" : "Tap to start").font(.title.bold())
                TapPad { host in tap(host) }
            }
            .frame(width: 200, height: 200)
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

    private func tap(_ host: Double) {
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
