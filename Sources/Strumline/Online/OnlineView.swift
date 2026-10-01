import SwiftUI
import StrumCore

/// Online: host or join a session, then the lobby.
struct OnlineView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Group {
            if let o = app.online {
                LobbyView(session: o)
            } else {
                OnlineStartView()
            }
        }
        .screenChrome("Online") { app.screen = .menu }
    }
}

/// No session yet: host one, pick a nearby one, or type an address.
private struct OnlineStartView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var browser = OnlineBrowser()
    @State private var address = ""

    private var rows: [NavRow] {
        var r: [NavRow] = [
            NavRow(id: "host", section: "Host", title: "Host a session", detail: "Others on your Wi-Fi or Tailscale join you; you pick the songs.",
                   symbol: "antenna.radiowaves.left.and.right", kind: .button(destructive: false) { app.hostOnline() }),
        ]
        if browser.found.isEmpty {
            r.append(NavRow(id: "looking", section: "Join nearby", title: "Looking for sessions on this network…", kind: .info))
        }
        for f in browser.found {
            r.append(NavRow(id: "found-\(f.name)", section: "Join nearby", title: f.name, symbol: "person.2.fill",
                            kind: .button(destructive: false) { app.joinOnline(f.endpoint) }))
        }
        r.append(NavRow(id: "addr", section: "Join by address", title: "Address (e.g. 100.64.1.2)", kind: .text($address)))
        let a = address.trimmingCharacters(in: .whitespaces)
        if let ep = OnlineSession.endpoint(for: a) {
            r.append(NavRow(id: "joinaddr", section: "Join by address", title: "Join \(a)", symbol: "arrow.right.circle.fill",
                            kind: .button(destructive: false) { app.joinOnline(ep) }))
        }
        r.append(NavRow(id: "you", section: "You", title: "You play as \(app.players.first?.name ?? "Player") on \(app.settings.lastInstrument.displayName) \(app.settings.lastDifficulty.displayName)",
                        detail: "Rename yourself in the player bar; change your part in the lobby.", kind: .info))
        return r
    }

    var body: some View {
        NavForm(rows: rows, onBack: { app.screen = .menu })
            .onAppear { browser.start() }
            .onDisappear { browser.stop() }
    }
}

/// In a session: who's here, the song, your part.
private struct LobbyView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var session: OnlineSession
    @State private var leaveArmed = false

    private var instrument: Binding<Instrument> {
        Binding(get: { app.settings.lastInstrument },
                set: { app.settings.lastInstrument = $0; session.setPart($0, app.settings.lastDifficulty) })
    }
    private var difficulty: Binding<Difficulty> {
        Binding(get: { app.settings.lastDifficulty },
                set: { app.settings.lastDifficulty = $0; session.setPart(app.settings.lastInstrument, $0) })
    }

    private func status(_ p: NetPlayer) -> (String, String) {
        if !p.connected { return ("wifi.slash", "Disconnected") }
        guard session.song != nil else { return ("person.fill", "") }
        if let d = p.download { return ("arrow.down.circle", "Getting the song: \(Int(d * 100))%") }
        switch p.hasSong {
        case true?: return ("checkmark.circle.fill", "Has the song")
        case false?: return ("xmark.circle", session.isHost ? "Doesn't have it" : "Doesn't have it: sits out")
        case nil: return ("ellipsis.circle", "Checking…")
        }
    }

    private var rows: [NavRow] {
        let o = session
        var r: [NavRow] = []
        if let reason = o.ended {
            r.append(NavRow(id: "ended", section: "Session", title: reason, symbol: "exclamationmark.triangle.fill", kind: .info))
            r.append(NavRow(id: "back", section: "Session", title: "Back", kind: .button(destructive: false) { app.leaveOnline() }))
            return r
        }
        r.append(NavRow(id: "status", section: o.isHost ? "Hosting" : "Joined \(o.hostName)", title: o.status.isEmpty ? (o.isHost ? "Hosting" : "Connected") : o.status, kind: .info))
        for p in o.players {
            let (sym, st) = status(p)
            let me = p.id == o.myID ? " (you)" : p.id == "host" ? " (host)" : ""
            r.append(NavRow(id: "pl-\(p.id)", section: "Players (\(o.players.filter(\.connected).count))", title: p.name + me,
                            detail: "\(p.instrument.displayName) · \(p.difficulty.displayName)" + (st.isEmpty ? "" : " · \(st)"),
                            symbol: sym, kind: .info))
        }
        let songTitle = o.song.map { "\($0.name) — \($0.artist)" } ?? (o.isHost ? "No song picked yet" : "Waiting for the host to pick a song")
        r.append(NavRow(id: "song", section: "Song", title: songTitle, symbol: "music.note", kind: .info))
        if o.isHost {
            r.append(NavRow(id: "pick", section: "Song", title: o.song == nil ? "Pick a song…" : "Pick another song…", symbol: "music.note.list",
                            kind: .button(destructive: false) { app.screen = .songs(practice: false) }))
            if o.song != nil {
                let guests = o.players.filter { $0.connected && $0.id != "host" }
                let getting = guests.filter { $0.download != nil }.count
                let out = guests.filter { $0.hasSong == false && $0.download == nil }.count
                r.append(NavRow(id: "start", section: "Song", title: "Start for everyone",
                                detail: getting > 0 ? "\(getting) player(s) still getting the song: wait, or they'll sit this one out"
                                    : out > 0 ? "\(out) player(s) don't have it and will sit out" : "Starts on every device 4 seconds after you press it",
                                symbol: "play.fill", kind: .button(destructive: false) { o.startSong(speed: app.settings.modifiers.songSpeed) }))
            }
        }
        r.append(.pick("inst", "Your part", "Instrument", options: Instrument.allCases, label: { $0.displayName }, selection: instrument))
        r.append(.pick("diff", "Your part", "Difficulty", options: Difficulty.allCases, label: { $0.displayName }, selection: difficulty))
        if o.isHost {
            for (i, a) in localIPv4Addresses().enumerated() {
                r.append(NavRow(id: "ip\(i)", section: "Others can join by address", title: a.address, detail: a.name, symbol: "network", kind: .info))
            }
        }
        r.append(NavRow(id: "leave", section: "Leave", title: leaveArmed ? "Press again to \(o.isHost ? "end the session" : "leave")" : (o.isHost ? "End session" : "Leave session"),
                        symbol: "rectangle.portrait.and.arrow.right", kind: .button(destructive: true) {
            guard leaveArmed else { leaveArmed = true; return }
            app.leaveOnline()
        }))
        return r
    }

    var body: some View {
        NavForm(rows: rows, onBack: { app.screen = .menu })
    }
}
