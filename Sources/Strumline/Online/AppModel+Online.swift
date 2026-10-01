import Foundation
import Network
import StrumCore

extension AppModel {
    /// Player 1 as others see them online.
    private var onlineMe: NetPlayer {
        NetPlayer(id: "", name: players.first?.name ?? "Player", instrument: settings.lastInstrument, difficulty: settings.lastDifficulty)
    }

    func hostOnline() {
        leaveOnline()
        let o = OnlineSession(hosting: onlineMe)
        wire(o)
        online = o
    }

    func joinOnline(_ endpoint: NWEndpoint) {
        leaveOnline()
        let o = OnlineSession(joining: endpoint, as: onlineMe)
        wire(o)
        online = o
    }

    func leaveOnline() {
        online?.leave()
        online = nil
        lastPlayWasOnline = false
    }

    private func wire(_ o: OnlineSession) {
        o.hasSong = { [weak self] hash in self?.songs.contains { $0.chartHash == hash } ?? false }
        o.onStart = { [weak self, weak o] hash, at, speed in
            guard let self else { return }
            guard let song = songs.first(where: { $0.chartHash == hash }) else {
                o?.status = "You don't have this song, so you're sitting this one out"
                return
            }
            play(song: song, instrument: settings.lastInstrument, difficulty: settings.lastDifficulty, practice: nil, onlineStart: (at, speed))
        }
        o.onAbort = { [weak self] in
            guard let self, lastPlayWasOnline else { return }
            session?.quitSilently()
            session = nil
            screen = .online
        }
        o.onFinals = { [weak self] in
            guard let self, lastPlayWasOnline, screen == .results else { return }
            lastResults = mergedOnlineResults()
        }
    }

    /// This device's result plus everyone else's that has arrived.
    func mergedOnlineResults() -> [GameResult] {
        guard let o = online, let mine = onlineLocalResult else { return lastResults }
        var out = [mine]
        for (i, p) in o.players.enumerated() where p.id != o.myID {
            guard let stats = o.finals[p.id] else { continue }
            out.append(GameResult(song: mine.song, instrument: p.instrument, difficulty: p.difficulty, stats: stats,
                                  modifiers: Modifiers(), playerName: p.name, playerIndex: i))
        }
        return out
    }

    /// Results → Continue: back to the online lobby, or to the song list.
    func continueFromResults() {
        if let o = online, lastPlayWasOnline {
            if o.isHost && o.playing { o.endSong(abort: false) }
            screen = .online
        } else {
            screen = .songs(practice: false)
        }
    }
}
