import SwiftUI
import StrumCore

@main
struct StrumlineApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
                .tint(Palette.orange)
                .onOpenURL { url in
                    // A .sng shared from Files/another app: link it in place.
                    app.link(urls: [url])
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ZStack {
            switch app.screen {
            case .menu:
                MainMenuView()
            case .songs(let practice):
                SongSelectView(practice: practice)
            case .play:
                if let s = app.session { GameView(session: s) } else { MainMenuView() }
            case .results:
                ResultsView()
            case .settings:
                NavigationStack { SettingsView() }
            case .library:
                NavigationStack { LibraryView() }
            }
        }
        .background(KeyCatcher().frame(width: 0, height: 0))
        .animation(.easeInOut(duration: 0.2), value: app.screen)
    }
}

struct MainMenuView: View {
    @EnvironmentObject var app: AppModel
    @State private var selection = 0
    private let items: [(String, String, Screen)] = [
        ("Quickplay", "play.fill", .songs(practice: false)),
        ("Practice", "metronome.fill", .songs(practice: true)),
        ("Library", "folder.fill", .library),
        ("Settings", "gearshape.fill", .settings),
    ]

    var body: some View {
        ZStack {
            StrumlineBackground()
            GeometryReader { geo in
                let landscape = geo.size.width > geo.size.height
                let layout = landscape ? AnyLayout(HStackLayout(spacing: 40)) : AnyLayout(VStackLayout(spacing: 28))
                layout {
                    VStack(spacing: 6) {
                        Wordmark(size: landscape ? 50 : 46)
                        Text(app.scanning ? app.scanStatus : "\(app.songs.count) songs")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 10) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            MenuButton(title: item.0, systemImage: item.1) { app.screen = item.2 }
                                .focusRing(selection == i)
                        }
                    }
                    .frame(maxWidth: 320)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(spacing: 6) { Spacer(); ControlLegend([.move, .select]); PlayerBar() }
        }
        .onAppear { app.preview.stop() }
        .menuNavigation { nav in navigate(nav) }
    }

    /// ↑↓ through the menu; ↓ past the end moves into the player bar where
    /// ←→ picks a player and green opens their settings (or joins).
    private func navigate(_ nav: MenuNav) {
        if let slot = app.playerBarFocus {
            let slots = min(app.players.count + 1, AppModel.maxPlayers)
            switch nav {
            case .left: app.playerBarFocus = max(0, slot - 1)
            case .right: app.playerBarFocus = min(slots - 1, slot + 1)
            case .up, .back: app.playerBarFocus = nil
            case .confirm: app.playerBarOpen = slot
            default: break
            }
            return
        }
        switch nav {
        case .down:
            if selection == items.count - 1 { app.playerBarFocus = 0 } else { selection += 1 }
        case .up: selection = max(0, selection - 1)
        case .confirm: app.screen = items[selection].2
        default: break
        }
    }
}

/// One physical press → one menu intent. Dedicated menu bindings win; a
/// guitar's strum/green/red and a kit's pads work as fallbacks.
enum MenuNav {
    case up, down, left, right, confirm, back, pageUp, pageDown
    init?(_ a: Set<GameAction>) {
        if a.contains(.menuPageUp) { self = .pageUp }
        else if a.contains(.menuPageDown) { self = .pageDown }
        else if a.contains(.menuConfirm) { self = .confirm }
        else if a.contains(.menuBack) { self = .back }
        else if a.contains(.menuUp) { self = .up }
        else if a.contains(.menuDown) { self = .down }
        else if a.contains(.menuLeft) { self = .left }
        else if a.contains(.menuRight) { self = .right }
        else if a.contains(.strumUp) { self = .up }
        else if a.contains(.strumDown) { self = .down }
        else if a.contains(.fret1) || a.contains(.padGreen) { self = .confirm }
        else if a.contains(.fret2) || a.contains(.padRed) || a.contains(.pause) { self = .back }
        else if a.contains(.fret3) || a.contains(.padYellow) { self = .left }
        else if a.contains(.fret4) || a.contains(.padBlue) { self = .right }
        else if a.contains(.fret5) || a.contains(.cymGreen) { self = .pageDown }
        else if a.contains(.fret6) { self = .pageUp }
        else { return nil }
    }
}
