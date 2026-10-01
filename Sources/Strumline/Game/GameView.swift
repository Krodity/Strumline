import SwiftUI
import AVFoundation
import QuartzCore
import StrumCore

struct GameView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var session: GameSession
    @State private var showQuickSettings = false

    private var touchOn: Bool { app.settings.showTouchControls }

    /// Solo: the on-screen controls setting. Multiplayer: only the player
    /// using the touchscreen gets them.
    static func touchEnabled(_ s: GameSession, _ r: PlayerRun, _ touchOn: Bool) -> Bool {
        s.runs.count == 1 ? touchOn : r.settings.showTouchControls
    }

    var body: some View {
        ZStack {
            background
            highwayTextures
            HighwayCanvas(session: session, touchOn: touchOn)
            .ignoresSafeArea()
            .allowsHitTesting(false)

            GeometryReader { geo in
                let n = CGFloat(session.runs.count)
                let colW = geo.size.width / n
                ForEach(session.runs.filter { GameView.touchEnabled(session, $0, touchOn) }, id: \.index) { run in
                    TouchControls(kind: run.instrument.kind, drumMode: run.drumMode, settings: run.settings)
                        .frame(width: colW, height: geo.size.height)
                        .position(x: colW * (CGFloat(run.index) + 0.5), y: geo.size.height / 2)
                }
            }
            .ignoresSafeArea()

            // Top controls
            VStack {
                HStack {
                    Spacer()
                    if touchOn {
                        Button {
                            InputManager.shared.inject(.starPower, down: true, time: CACurrentMediaTime())
                        } label: {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 20, weight: .bold))
                                .frame(width: 46, height: 46)
                                .background(Circle().fill(Palette.sp.opacity(0.25)))
                                .overlay(Circle().stroke(Palette.sp, lineWidth: 2))
                        }
                        .foregroundStyle(Palette.sp)
                    }
                    Button {
                        session.setPaused(true)
                    } label: {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 18, weight: .bold))
                            .frame(width: 46, height: 46)
                            .background(Circle().fill(Color.black.opacity(0.4)))
                    }
                    .foregroundStyle(.white)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                Spacer()
            }

            if session.paused {
                if let c = session.resumeCountdown {
                    Text(c > 0 ? "\(c)" : "Go!")
                        .font(.system(size: 80, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(radius: 10)
                } else {
                    pauseMenu
                }
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            session.setPaused(true)
        }
        // While the settings sheet is up, controllers drive the sheet rather
        // than the pause menu underneath.
        .onChange(of: showQuickSettings) { _, open in InputManager.shared.gameplayActive = !open }
        .sheet(isPresented: $showQuickSettings) {
            QuickSettingsSheet()
                .environmentObject(app)
                .presentationDetents([.medium, .large])
        }
    }

    /// Pinned to the screen size: a scaledToFill image left unconstrained
    /// grows the ZStack (and the highway canvas) past the screen edges.
    /// Custom background chosen once per song (shuffle picks one).
    @State private var customBG: URL? = nil
    @State private var pickedBG = false

    private var useSongMedia: Bool {
        app.settings.gameBackground == .song && (session.videoPlayer != nil || session.background != nil)
    }

    /// Pinned to the screen size: a scaledToFill image left unconstrained
    /// grows the ZStack (and the highway canvas) past the screen edges.
    private var background: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Color(red: 0.08, green: 0.03, blue: 0.14), .black], startPoint: .top, endPoint: .bottom)
                if app.settings.gameBackground != .none {
                    if useSongMedia, let player = session.videoPlayer {
                        VideoLayer(player: player)
                    } else if useSongMedia, let img = session.background {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else if let url = customBG {
                        MediaBackground(url: url)
                    } else if let art = session.albumArt {
                        Image(uiImage: art).resizable().scaledToFill().blur(radius: 30).opacity(0.6)
                    }
                }
                Color.black.opacity(app.settings.gameBackground == .none ? 0 : app.settings.backgroundDim)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            guard !pickedBG else { return }
            pickedBG = true
            customBG = CustomAssets.resolveBackground(app.settings.customBackground)
        }
    }

    /// Custom highway images, one per player column, under the canvas.
    private var highwayTextures: some View {
        GeometryReader { geo in
            let n = CGFloat(session.runs.count)
            let colW = geo.size.width / n
            ForEach(session.runs, id: \.index) { run in
                if let url = run.highwayImageURL, let img = CustomAssets.image(url) {
                    HighwayTexture(session: session, run: run, image: img, touchControls: GameView.touchEnabled(session, run, touchOn))
                        .frame(width: colW, height: geo.size.height)
                        .position(x: colW * (CGFloat(run.index) + 0.5), y: geo.size.height / 2)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func focusRing(_ i: Int) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.large).stroke(Theme.accent, lineWidth: session.pauseSelection == i ? Theme.focusWidth : 0)
    }

    private func pauseAction(_ i: Int) {
        switch i {
        case 0: session.setPaused(false)
        case 1: app.restartCurrent()
        case 2: showQuickSettings = true
        default: session.quit()
        }
    }

    private var pauseMenu: some View {
        VStack(spacing: 14) {
            Text("Paused").font(Theme.Fonts.display)
            Text("\(session.song.name) — \(session.song.artist)")
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Text("\(session.instrument.displayName) · \(session.difficulty.displayName)")
                .font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 10) {
                MenuButton(title: "Resume", systemImage: "play.fill") { pauseAction(0) }
                    .overlay(focusRing(0))
                MenuButton(title: "Restart", systemImage: "arrow.counterclockwise") { pauseAction(1) }
                    .overlay(focusRing(1))
                MenuButton(title: "Adjust", systemImage: "slider.horizontal.3") { pauseAction(2) }
                    .overlay(focusRing(2))
                MenuButton(title: "Quit", systemImage: "xmark", role: .destructive) { pauseAction(3) }
                    .overlay(focusRing(3))
            }
            .frame(maxWidth: 280)
            .onAppear { session.pauseAction = { pauseAction($0) } }
        }
        .padding(28)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.sheet).fill(.ultraThinMaterial))
    }
}

/// Note speed / calibration tweaks from the pause menu. Changes apply on
/// the next song or restart, as in Clone Hero.
struct QuickSettingsSheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let st = $app.settings
        NavigationStack {
            NavForm(rows: [
                // Just what you tweak mid-song; the rest lives in Settings.
                NavRow(id: "ns", section: "Highway", title: "Track (note) speed", kind: .slider(st.noteSpeed, 0.25...10, step: 0.05, format: { String(format: "%.2f×", $0) })),
                NavRow(id: "ao", section: "Calibration", title: "Audio offset", kind: .slider(st.audioOffsetMs, -300...300, step: 1, format: { "\(Int($0)) ms" })),
                NavRow(id: "vo", section: "Calibration", title: "Video offset", kind: .slider(st.videoOffsetMs, -300...300, step: 1, format: { "\(Int($0)) ms" })),
                NavRow(id: "note", section: "Apply", title: "Choose Restart to apply these to the current song.", kind: .info),
                NavRow(id: "restart", section: "Apply", title: "Restart now", kind: .button(destructive: false) { dismiss(); app.restartCurrent() }),
            ], onBack: { dismiss() })
            .sheetChrome("Adjust") { dismiss() }
        }
    }
}

struct VideoLayer: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ v: PlayerView, context: Context) {}

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
