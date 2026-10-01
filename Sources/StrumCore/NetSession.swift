import Foundation

/// Host side of an online session, independent of how bytes move. Feed it
/// what connections receive (`receive`) and call `tick` regularly; it sends
/// through `send`. Times are the host's own monotonic clock in seconds.
/// Not thread-safe: use from one thread/queue.
public final class NetHost {
    public enum Phase: Sendable, Equatable { case lobby, playing }

    /// Sends a message to one connection.
    public var send: (_ connection: Int, _ message: NetMessage) -> Void = { _, _ in }
    /// Lobby, song status, scoreboard or results changed (update the UI).
    public var onChange: () -> Void = {}

    public private(set) var players: [NetPlayer]
    public private(set) var song: NetSong?
    public private(set) var phase = Phase.lobby
    public private(set) var scores: [String: NetScore] = [:]
    public private(set) var finals: [String: PlayStats] = [:]
    public let hostID = "host"

    private var playerOf: [Int: String] = [:]  // connection → player id
    private var nextID = 1
    private var scoresDirty = false
    private var lastScoreboard = -Double.infinity
    public let maxPlayers: Int

    public init(host: NetPlayer, maxPlayers: Int = 6) {
        var h = host
        h.id = "host"
        h.hasSong = nil
        players = [h]
        self.maxPlayers = maxPlayers
    }

    public var connections: [Int] { Array(playerOf.keys) }

    private func broadcast(_ m: NetMessage, except: Int? = nil) {
        for c in playerOf.keys where c != except { send(c, m) }
    }
    private func broadcastLobby() { broadcast(.lobby(players)); onChange() }

    public func receive(_ m: NetMessage, from c: Int, now: Double) {
        if case .hello(let version, var p) = m {
            guard version == Net.protocolVersion else { send(c, .refused(reason: "Different Strumline version")); return }
            guard phase == .lobby else { send(c, .refused(reason: "A song is in progress")); return }
            guard players.filter(\.connected).count < maxPlayers else { send(c, .refused(reason: "Session is full")); return }
            p.id = "p\(nextID)"; nextID += 1
            p.hasSong = nil
            p.connected = true
            playerOf[c] = p.id
            players.append(p)
            send(c, .welcome(playerID: p.id, hostName: players[0].name))
            if let s = song { send(c, .pick(s)) }
            broadcastLobby()
            return
        }
        if case .ping(let t0) = m { send(c, .pong(t0: t0, hostTime: now)); return }
        guard let id = playerOf[c], let i = players.firstIndex(where: { $0.id == id }) else { return }
        switch m {
        case .setPart(let inst, let diff):
            players[i].instrument = inst
            players[i].difficulty = diff
            broadcastLobby()
        case .songStatus(let hash, let has):
            guard hash == song?.chartHash else { return }
            players[i].hasSong = has
            broadcastLobby()
        case .progress(var s):
            s.playerID = id
            scores[id] = s
            scoresDirty = true
        case .finished(_, let stats):
            finals[id] = stats
            broadcast(.finished(playerID: id, stats: stats), except: c)
            onChange()
        case .leave:
            disconnected(c)
        default:
            break
        }
    }

    /// The connection closed (or sent `leave`).
    public func disconnected(_ c: Int) {
        guard let id = playerOf.removeValue(forKey: c) else { return }
        if phase == .lobby {
            players.removeAll { $0.id == id }
        } else if let i = players.firstIndex(where: { $0.id == id }) {
            players[i].connected = false  // keep their score on the board
        }
        broadcastLobby()
    }

    /// Host picks a song (it must have it). Guests answer with songStatus.
    public func pick(_ s: NetSong) {
        song = s
        for i in players.indices { players[i].hasSong = i == 0 ? true : nil }
        broadcast(.pick(s))
        broadcastLobby()
    }

    public func setHostPart(_ inst: Instrument, _ diff: Difficulty) {
        players[0].instrument = inst
        players[0].difficulty = diff
        broadcastLobby()
    }

    /// Everyone connected who has the song (the host always plays).
    public var readyPlayers: [NetPlayer] { players.filter { $0.connected && ($0.id == hostID || $0.hasSong == true) } }

    /// Starts the picked song for everyone at `hostTime`. Returns false if
    /// there's no song.
    @discardableResult
    public func start(at hostTime: Double, speed: Double) -> Bool {
        guard let s = song else { return false }
        phase = .playing
        scores = [:]
        finals = [:]
        broadcast(.start(chartHash: s.chartHash, hostTime: hostTime, speed: speed))
        onChange()
        return true
    }

    /// The host's own live score.
    public func reportLocal(_ s: NetScore) {
        var s = s
        s.playerID = hostID
        scores[hostID] = s
        scoresDirty = true
    }

    public func finishLocal(_ stats: PlayStats) {
        finals[hostID] = stats
        broadcast(.finished(playerID: hostID, stats: stats))
        onChange()
    }

    /// Back to the lobby (song over or abandoned). `abort` tells guests to quit theirs.
    public func endSong(abort: Bool) {
        if abort { broadcast(.abort) }
        phase = .lobby
        players.removeAll { !$0.connected }
        broadcastLobby()
    }

    /// Call ~10×/s: sends the scoreboard (at most 4×/s, only on change).
    public func tick(now: Double) {
        guard scoresDirty, now - lastScoreboard >= 0.25 else { return }
        scoresDirty = false
        lastScoreboard = now
        let board = players.compactMap { scores[$0.id] }
        broadcast(.scoreboard(board))
        onChange()
    }

    /// Say goodbye to everyone (host leaving).
    public func close() {
        broadcast(.leave)
        playerOf.removeAll()
    }
}

/// Guest side of an online session. Feed it received messages, call `tick`
/// regularly (it pings the host to sync clocks), and act on its callbacks.
/// Times are the guest's own monotonic clock. Not thread-safe.
public final class NetGuest {
    public var send: (NetMessage) -> Void = { _ in }
    public var onChange: () -> Void = {}
    /// Does this device have the song with this chart hash?
    public var hasSong: (String) -> Bool = { _ in false }
    /// Start `chartHash` at local time `at`, song speed `speed`.
    public var onStart: (_ chartHash: String, _ at: Double, _ speed: Double) -> Void = { _, _, _ in }
    /// The host stopped the song.
    public var onAbort: () -> Void = {}
    /// Refused or the host left.
    public var onEnd: (_ reason: String) -> Void = { _ in }

    public private(set) var me: NetPlayer
    public private(set) var myID: String?
    public private(set) var hostName = ""
    public private(set) var players: [NetPlayer] = []
    public private(set) var song: NetSong?
    public private(set) var scores: [NetScore] = []
    public private(set) var finals: [String: PlayStats] = [:]
    public private(set) var clock = ClockSync()
    private var lastPing = -Double.infinity
    private var pings = 0

    public init(me: NetPlayer) { self.me = me }

    /// Call once the connection is up.
    public func connected(now: Double) {
        send(.hello(version: Net.protocolVersion, player: me))
        tick(now: now)
    }

    /// Pings quickly at first (to sync the clock), then every 2 s to track drift.
    public func tick(now: Double) {
        let interval = pings < 8 ? 0.15 : 2.0
        guard now - lastPing >= interval else { return }
        lastPing = now
        pings += 1
        send(.ping(t0: now))
    }

    public func setPart(_ inst: Instrument, _ diff: Difficulty) {
        me.instrument = inst
        me.difficulty = diff
        send(.setPart(instrument: inst, difficulty: diff))
    }

    public func report(_ s: NetScore) { send(.progress(s)) }
    public func finish(_ stats: PlayStats) { send(.finished(playerID: myID ?? "", stats: stats)) }
    public func leave() { send(.leave) }

    public func receive(_ m: NetMessage, now: Double) {
        switch m {
        case .welcome(let id, let host):
            myID = id
            hostName = host
            onChange()
        case .refused(let reason):
            onEnd(reason)
        case .lobby(let ps):
            players = ps
            onChange()
        case .pong(let t0, let hostTime):
            clock.add(t0: t0, hostTime: hostTime, t2: now)
        case .pick(let s):
            song = s
            finals = [:]
            send(.songStatus(chartHash: s.chartHash, has: hasSong(s.chartHash)))
            onChange()
        case .start(let hash, let hostTime, let speed):
            scores = []
            finals = [:]
            // Before the clock has settled, the best guess is "now".
            let at = clock.localTime(forHost: hostTime) ?? now
            onStart(hash, at, speed)
        case .scoreboard(let s):
            scores = s
            onChange()
        case .finished(let id, let stats):
            finals[id] = stats
            onChange()
        case .abort:
            onAbort()
        case .leave:
            onEnd("The host left")
        default:
            break
        }
    }
}
