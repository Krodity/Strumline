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

            // Online: everyone's live score.
            if !session.remoteScores.isEmpty {
                OnlineScoreboard(scores: session.remoteScores, names: session.remoteNames, me: session.localPlayerID, offline: session.remoteOffline)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .allowsHitTesting(false)
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
            QuickSettingsSheet(online: isOnline)
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

    private struct PauseItem {
        let title: String
        let symbol: String
        var destructive = false
        let run: () -> Void
    }

    private var isOnline: Bool { app.online != nil && app.lastPlayWasOnline }

    /// The pause menu. Online there's no Restart (the host starts songs for
    /// everyone), and the host's Quit ends the song for everyone.
    private var pauseItems: [PauseItem] {
        var items = [PauseItem(title: "Resume", symbol: "play.fill") { session.setPaused(false) }]
        if !isOnline { items.append(PauseItem(title: "Restart", symbol: "arrow.counterclockwise") { app.restartCurrent() }) }
        items.append(PauseItem(title: "Adjust", symbol: "slider.horizontal.3") { showQuickSettings = true })
        let quit = !isOnline ? "Quit" : app.online?.isHost == true ? "End Song for Everyone" : "Leave Song"
        items.append(PauseItem(title: quit, symbol: "xmark", destructive: true) { session.quit() })
        return items
    }

    private var pauseMenu: some View {
        VStack(spacing: 14) {
            Text("Paused").font(Theme.Fonts.display)
            Text("\(session.song.name) — \(session.song.artist)")
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Text("\(session.instrument.displayName) · \(session.difficulty.displayName)")
                .font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 10) {
                let items = pauseItems
                ForEach(items.indices, id: \.self) { i in
                    MenuButton(title: items[i].title, systemImage: items[i].symbol, role: items[i].destructive ? .destructive : nil) { items[i].run() }
                        .overlay(focusRing(i))
                }
            }
            .frame(maxWidth: 280)
            .onAppear {
                // Controller / keyboard drive the same list.
                session.pauseItemCount = pauseItems.count
                session.pauseAction = { i in
                    let items = pauseItems
                    if items.indices.contains(i) { items[i].run() }
                }
            }
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
    /// Online songs can't be restarted from here (the host starts songs).
    var online = false
    var body: some View {
        let st = $app.settings
        NavigationStack {
            NavForm(rows: [
                // Just what you tweak mid-song; the rest lives in Settings.
                NavRow(id: "ns", section: "Highway", title: "Track (note) speed", kind: .slider(st.noteSpeed, 0.25...10, step: 0.05, format: Fmt.times)),
                NavRow(id: "ao", section: "Calibration", title: "Audio offset", kind: .slider(st.audioOffsetMs, -300...300, step: 1, format: Fmt.ms)),
                NavRow(id: "vo", section: "Calibration", title: "Video offset", kind: .slider(st.videoOffsetMs, -300...300, step: 1, format: Fmt.ms)),
            ] + (online ? [
                NavRow(id: "note", section: "Apply", title: "These apply from the next song.", kind: .info),
            ] : [
                NavRow(id: "note", section: "Apply", title: "Choose Restart to apply these to the current song.", kind: .info),
                NavRow(id: "restart", section: "Apply", title: "Restart now", kind: .button(destructive: false) { dismiss(); app.restartCurrent() }),
            ]), onBack: { dismiss() })
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

/// Live scores in an online song, highest first.
struct OnlineScoreboard: View {
    var scores: [NetScore]
    var names: [String: String]
    var me: String
    var offline: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(scores.sorted { $0.score > $1.score }.enumerated()), id: \.element.playerID) { rank, s in
                HStack(spacing: 6) {
                    Text("\(rank + 1)").font(.caption2.bold()).foregroundStyle(.secondary).frame(width: 12)
                    if offline.contains(s.playerID) {
                        Image(systemName: "wifi.slash").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Text(names[s.playerID] ?? "Player").font(.caption.bold()).lineLimit(1)
                        .foregroundStyle(s.playerID == me ? Theme.accent : offline.contains(s.playerID) ? .secondary : .white)
                    Spacer(minLength: 6)
                    if s.spActive { Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(Palette.sp) }
                    Text("\(s.score)").font(.caption.monospacedDigit())
                }
            }
        }
        .frame(width: 150)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(.ultraThinMaterial))
    }
}
