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
    /// Sends a song chunk (binary frame) to one connection.
    public var sendChunk: (_ connection: Int, _ chunk: NetChunk) -> Void = { _, _ in }
    /// Whether a connection can take another chunk now (flow control: the
    /// transport keeps only a little queued per connection).
    public var canSend: (_ connection: Int) -> Bool = { _ in true }
    /// The host's files for a song, to send to guests who don't have it.
    public var songSource: (_ chartHash: String) -> NetSongSource? = { _ in nil }

    private struct Transfer {
        var source: NetSongSource
        var file = 0
        var offset: Int64 = 0
    }
    private var transfers: [Int: Transfer] = [:]

    public private(set) var players: [NetPlayer]
    public private(set) var song: NetSong?
    public private(set) var phase = Phase.lobby
    public private(set) var scores: [String: NetScore] = [:]
    public private(set) var finals: [String: PlayStats] = [:]
    public let hostID = "host"

    private var playerOf: [Int: String] = [:]  // connection → player id
    private var lastHeard: [Int: Double] = [:]
    /// Closes a connection the host gave up on (silent too long).
    public var closeConnection: (_ connection: Int) -> Void = { _ in }
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
        lastHeard[c] = now
        if case .hello(let version, var p) = m {
            guard version == Net.protocolVersion else { send(c, .refused(reason: "Different Strumline version")); return }
            // A player coming back after a dropped connection gets their own
            // slot (and score) back, even mid-song.
            if !p.id.isEmpty, let i = players.firstIndex(where: { $0.id == p.id && !$0.connected && $0.id != hostID }) {
                playerOf[c] = p.id
                players[i].connected = true
                send(c, .welcome(playerID: p.id, hostName: players[0].name))
                if let s = song { send(c, .pick(s)) }
                if phase == .playing { send(c, .scoreboard(players.compactMap { scores[$0.id] })) }
                broadcastLobby()
                return
            }
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
            // Doesn't have it: offer to send it.
            if !has, phase == .lobby, let src = songSource(hash) { send(c, .songOffer(src.offer)) }
            broadcastLobby()
        case .songAccept(let hash):
            guard hash == song?.chartHash, let src = songSource(hash) else { return }
            transfers[c] = Transfer(source: src)
            players[i].download = 0
            broadcastLobby()
            pump()
        case .songDecline(let hash, _):
            guard hash == song?.chartHash else { return }
            transfers[c] = nil
            players[i].download = nil
            broadcastLobby()
        case .transferProgress(let hash, let received, let total):
            guard hash == song?.chartHash, total > 0 else { return }
            players[i].download = min(1, Double(received) / Double(total))
            broadcastLobby()
        case .songReceived(let hash, let ok, _):
            guard hash == song?.chartHash else { return }
            transfers[c] = nil
            players[i].download = nil
            players[i].hasSong = ok
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
        transfers[c] = nil
        lastHeard[c] = nil
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
        transfers = [:]
        for i in players.indices { players[i].hasSong = i == 0 ? true : nil; players[i].download = nil }
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

    /// Sends song chunks while the connections can take them.
    public func pump() {
        for c in Array(transfers.keys) {
            while var t = transfers[c], canSend(c) {
                let files = t.source.offer.files
                guard t.file < files.count else { transfers[c] = nil; break }  // all sent; wait for songReceived
                let f = files[t.file]
                let n = Int(min(Int64(Net.chunkSize), f.size - t.offset))
                if n > 0 {
                    guard let bytes = t.source.read(t.file, t.offset, n), bytes.count == n else {
                        // Our own file went missing: stop, they sit this one out.
                        transfers[c] = nil
                        if let id = playerOf[c], let i = players.firstIndex(where: { $0.id == id }) {
                            players[i].download = nil
                            players[i].hasSong = false
                        }
                        broadcastLobby()
                        break
                    }
                    sendChunk(c, NetChunk(chartHash: t.source.offer.song.chartHash, file: t.file, offset: t.offset, bytes: bytes))
                    t.offset += Int64(n)
                }
                if t.offset >= f.size { t.file += 1; t.offset = 0 }
                transfers[c] = t
            }
        }
    }

    /// True while any guest is still being sent the song.
    public var sending: Bool { !transfers.isEmpty }

    /// Call ~10×/s: sends song chunks and the scoreboard (at most 4×/s, only on change).
    public func tick(now: Double) {
        // Drop guests that went silent (their pings stopped): the socket
        // may never report the loss itself.
        for c in Array(playerOf.keys) where now - (lastHeard[c] ?? now) > Net.timeout {
            closeConnection(c)
            disconnected(c)
        }
        pump()
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
    /// Where songs sent by the host are put (a session cache, not the library).
    public var songCache: URL?
    /// A sent song arrived and checked out; play it from here.
    public var onSongReceived: (SongEntry) -> Void = { _ in }

    /// The song being received, if any.
    public private(set) var receiver: NetSongReceiver?
    private var lastProgress = -Double.infinity

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

    private var lastHeard = -Double.infinity

    public init(me: NetPlayer) { self.me = me }

    /// Call once the connection is up (again, after a reconnect: the host
    /// recognises the player id and restores the same slot).
    public func connected(now: Double) {
        var hello = me
        hello.id = myID ?? ""
        lastHeard = now
        pings = 0
        send(.hello(version: Net.protocolVersion, player: hello))
        tick(now: now)
    }

    /// The host hasn't been heard from for too long: the connection is
    /// probably dead even if the socket hasn't noticed.
    public func isStale(now: Double) -> Bool { now - lastHeard > Net.timeout }

    /// Pings quickly at first (to sync the clock), then every 2 s to track drift.
    public func tick(now: Double) {
        if let r = receiver, !r.done, now - lastProgress >= 0.25 {
            lastProgress = now
            send(.transferProgress(chartHash: r.offer.song.chartHash, received: r.received, total: r.offer.totalBytes))
        }
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

    /// Feeds whatever a connection received.
    public func receive(_ incoming: NetIncoming, now: Double) {
        switch incoming {
        case .message(let m): receive(m, now: now)
        case .chunk(let c): receive(chunk: c, now: now)
        }
    }

    public func receive(chunk c: NetChunk, now: Double) {
        lastHeard = now
        guard let r = receiver, !r.done, c.chartHash == r.offer.song.chartHash else { return }
        do {
            if let entry = try r.write(c) {
                send(.transferProgress(chartHash: c.chartHash, received: r.received, total: r.offer.totalBytes))
                send(.songReceived(chartHash: c.chartHash, ok: true, reason: ""))
                send(.songStatus(chartHash: c.chartHash, has: true))
                onSongReceived(entry)
            }
        } catch {
            r.cancel()
            receiver = nil
            send(.songReceived(chartHash: c.chartHash, ok: false, reason: "\(error)"))
        }
        onChange()
    }

    public func receive(_ m: NetMessage, now: Double) {
        lastHeard = now
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
            // The same pick again (we rejoined after a drop): keep the song
            // we have or are receiving — it may be playing right now.
            if s.chartHash == song?.chartHash {
                let have = hasSong(s.chartHash) || receiver?.done == true && receiver?.offer.song.chartHash == s.chartHash
                if receiver == nil || receiver?.done == true { send(.songStatus(chartHash: s.chartHash, has: have)) }
                return
            }
            song = s
            finals = [:]
            receiver?.cancel()
            receiver = nil
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
        case .songOffer(let offer):
            guard offer.song.chartHash == song?.chartHash else { return }
            guard let cache = songCache else { send(.songDecline(chartHash: offer.song.chartHash, reason: "Can't receive songs")); return }
            if let problem = NetSongReceiver.problem(with: offer) {
                send(.songDecline(chartHash: offer.song.chartHash, reason: problem))
                return
            }
            receiver?.cancel()
            do {
                receiver = try NetSongReceiver(offer: offer, cache: cache)
                send(.songAccept(chartHash: offer.song.chartHash))
            } catch {
                send(.songDecline(chartHash: offer.song.chartHash, reason: "\(error)"))
            }
            onChange()
        default:
            break
        }
    }
}
