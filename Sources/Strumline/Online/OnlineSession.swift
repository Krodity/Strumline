import Foundation
import Network
import QuartzCore
import StrumCore

/// The phone's side of online play: moves bytes for `NetHost` / `NetGuest`
/// (StrumCore) over Network.framework and publishes their state for the UI.
/// Everything runs on the main queue.
@MainActor
final class OnlineSession: ObservableObject {
    enum Role { case host, guest }
    let role: Role
    var isHost: Bool { role == .host }

    @Published private(set) var players: [NetPlayer] = []
    @Published private(set) var song: NetSong?
    @Published private(set) var scores: [NetScore] = []
    @Published private(set) var finals: [String: PlayStats] = [:]
    @Published private(set) var myID = ""
    @Published private(set) var hostName = ""
    /// Connecting / connected / problems, for the lobby.
    @Published var status = ""
    /// Set when the session is over (refused, host left, connection lost).
    @Published private(set) var ended: String?
    @Published private(set) var playing = false
    /// Host: guests still finishing the last song.
    @Published private(set) var stillPlaying = 0

    // App hooks
    /// Start `chartHash` at local host time `at`, song speed `speed`.
    var onStart: (_ chartHash: String, _ at: Double, _ speed: Double) -> Void = { _, _, _ in }
    var hasSong: (String) -> Bool = { _ in false }
    /// The host stopped the song for everyone.
    var onAbort: () -> Void = {}
    /// Live scores or results changed while a song is on.
    var onScores: ([NetScore]) -> Void = { _ in }
    /// Players changed (joined, dropped, came back) while a song is on.
    var onPlayers: ([NetPlayer]) -> Void = { _ in }
    var onFinals: () -> Void = {}
    /// Host: the files of a library song, to send to guests without it.
    var songSource: (String) -> NetSongSource? = { _ in nil }

    /// Guest: songs the host sent this session (chart hash → song). Never
    /// added to the library; deleted when the session ends.
    @Published private(set) var receivedSongs: [String: SongEntry] = [:]
    /// Guest: 0…1 while the picked song is arriving.
    @Published private(set) var download: Double?

    /// Where sent songs are kept (cleared at launch and when leaving).
    static var songCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NetSession", isDirectory: true)
    }
    static func clearSongCache() { try? FileManager.default.removeItem(at: songCache) }

    /// Host: chunks queued on each connection (flow control).
    private var inFlight: [Int: Int] = [:]
    private var cachedSource: NetSongSource?

    private var host: NetHost?
    private var guest: NetGuest?
    private var listener: NWListener?
    private var connections: [Int: NWConnection] = [:]
    private var framers: [Int: NetFramer] = [:]
    private var nextConnection = 1
    private var guestConnection: NWConnection?
    private var guestFramer = NetFramer()
    private var timer: Timer?

    private static var now: Double { CACurrentMediaTime() }

    // MARK: Host

    init(hosting me: NetPlayer) {
        role = .host
        let h = NetHost(host: me)
        host = h
        myID = h.hostID
        hostName = me.name
        h.send = { [weak self] c, m in self?.send(m, to: c) }
        h.onChange = { [weak self] in self?.pullFromHost() }
        h.sendChunk = { [weak self] c, chunk in self?.sendChunk(chunk, to: c) }
        // The host gave up on a silent guest: just close the socket (NetHost
        // already marked them disconnected).
        h.closeConnection = { [weak self] id in
            self?.framers[id] = nil
            self?.inFlight[id] = nil
            self?.connections.removeValue(forKey: id)?.cancel()
        }
        // At most 8 chunks (512 KB) waiting per guest; more as they go out.
        h.canSend = { [weak self] c in (self?.inFlight[c] ?? 99) < 8 && self?.connections[c] != nil }
        h.songSource = { [weak self] hash in
            guard let self else { return nil }
            if let s = cachedSource, s.offer.song.chartHash == hash { return s }
            cachedSource = songSource(hash)
            return cachedSource
        }
        pullFromHost()
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Net.port)!)
            l.service = NWListener.Service(name: me.name, type: Net.serviceType)
            l.newConnectionHandler = { [weak self] c in MainActor.assumeIsolated { self?.accept(c) } }
            l.stateUpdateHandler = { [weak self] st in
                MainActor.assumeIsolated {
                    switch st {
                    case .ready: self?.status = "Waiting for players to join"
                    case .failed(let e): self?.finish("Couldn't host: \(e.localizedDescription)")
                    default: break
                    }
                }
            }
            listener = l
            l.start(queue: .main)
        } catch {
            ended = "Couldn't host: \(error.localizedDescription)"
        }
        startTimer()
    }

    private func accept(_ c: NWConnection) {
        let id = nextConnection
        nextConnection += 1
        connections[id] = c
        framers[id] = NetFramer()
        c.stateUpdateHandler = { [weak self] st in
            MainActor.assumeIsolated {
                switch st {
                case .failed, .cancelled: self?.dropConnection(id)
                default: break
                }
            }
        }
        c.start(queue: .main)
        receive(on: c) { [weak self] data in
            guard let self else { return false }
            do {
                for case .message(let m) in try self.framers[id, default: NetFramer()].append(data) { self.host?.receive(m, from: id, now: Self.now) }
                return true
            } catch {
                return false  // junk: drop them
            }
        } closed: { [weak self] in self?.dropConnection(id) }
    }

    private func dropConnection(_ id: Int) {
        guard let c = connections.removeValue(forKey: id) else { return }
        framers[id] = nil
        inFlight[id] = nil
        c.cancel()
        host?.disconnected(id)
    }

    private func send(_ m: NetMessage, to id: Int) {
        connections[id]?.send(content: NetFramer.encode(m), completion: .idempotent)
    }

    private func sendChunk(_ chunk: NetChunk, to id: Int) {
        guard let c = connections[id] else { return }
        inFlight[id, default: 0] += 1
        c.send(content: NetFramer.encode(chunk), completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.inFlight[id] != nil else { return }
                self.inFlight[id, default: 1] -= 1
                self.host?.pump()
            }
        })
    }

    private func pullFromHost() {
        guard let h = host else { return }
        if h.players != players { onPlayers(h.players) }
        players = h.players
        song = h.song
        playing = h.phase == .playing
        stillPlaying = h.stillPlaying.count
        let s = h.players.compactMap { h.scores[$0.id] }
        if s != scores { scores = s; onScores(s) }
        if h.finals != finals { finals = h.finals; onFinals() }
        let joined = h.players.count - 1
        if listener != nil && !playing { status = joined == 0 ? "Waiting for players to join" : "\(joined) joined" }
    }

    // MARK: Guest

    init(joining endpoint: NWEndpoint, as me: NetPlayer) {
        role = .guest
        let g = NetGuest(me: me)
        guest = g
        g.send = { [weak self] m in self?.guestConnection?.send(content: NetFramer.encode(m), completion: .idempotent) }
        g.onChange = { [weak self] in self?.pullFromGuest() }
        // A song the host already sent counts as having it.
        g.hasSong = { [weak self] hash in self.map { $0.hasSong(hash) || $0.receivedSongs[hash] != nil } ?? false }
        g.onStart = { [weak self] hash, at, speed in
            self?.playing = true
            self?.onStart(hash, at, speed)
        }
        g.onAbort = { [weak self] in
            self?.playing = false
            self?.onAbort()
        }
        g.onEnd = { [weak self] reason in self?.finish(reason) }
        OnlineSession.clearSongCache()
        g.songCache = OnlineSession.songCache
        g.onSongReceived = { [weak self] entry in
            self?.receivedSongs[entry.chartHash] = entry
            self?.download = nil
        }
        guestEndpoint = endpoint
        status = "Connecting…"
        connectGuest()
        startTimer()
    }

    // Guest connection, with automatic reconnects: a dropped Wi-Fi / Tailscale
    // link or a locked phone shouldn't end the session. The host gives the
    // same slot back (see NetHost hello handling).
    private var guestEndpoint: NWEndpoint?
    private var reconnectAttempts = 0
    private var reconnectPending = false
    private static let maxReconnects = 15  // × 2 s

    private func connectGuest() {
        guard let endpoint = guestEndpoint, ended == nil else { return }
        guestConnection?.cancel()
        guestFramer = NetFramer()
        let c = NWConnection(to: endpoint, using: .tcp)
        guestConnection = c
        c.stateUpdateHandler = { [weak self] st in
            MainActor.assumeIsolated {
                guard let self, c === self.guestConnection else { return }
                switch st {
                case .ready:
                    self.reconnectAttempts = 0
                    self.status = "Connected"
                    self.guest?.connected(now: Self.now)
                case .waiting(let e): self.status = "Waiting: \(e.localizedDescription)"
                case .failed(let e): self.connectionLost(e.localizedDescription)
                default: break
                }
            }
        }
        c.start(queue: .main)
        receive(on: c) { [weak self] data in
            guard let self, c === self.guestConnection else { return false }
            do {
                for incoming in try self.guestFramer.append(data) { self.guest?.receive(incoming, now: Self.now) }
                return true
            } catch { return false }
        } closed: { [weak self] in
            guard let self, c === self.guestConnection else { return }
            self.connectionLost("Connection closed")
        }
    }

    /// The link to the host dropped: try again every 2 s for ~30 s.
    private func connectionLost(_ why: String) {
        guard ended == nil, !reconnectPending else { return }
        guestConnection?.cancel()
        guestConnection = nil
        guard reconnectAttempts < Self.maxReconnects else { finish("Lost the host: \(why)"); return }
        reconnectAttempts += 1
        reconnectPending = true
        status = "Reconnecting… (\(reconnectAttempts))"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.reconnectPending = false
            self.connectGuest()
        }
    }

    /// "100.64.1.2" or "host.local" (port optional: "host:47821").
    static func endpoint(for address: String) -> NWEndpoint? {
        let a = address.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return nil }
        var hostPart = a, port = Net.port
        if let colon = a.lastIndex(of: ":"), a.filter({ $0 == ":" }).count == 1, let p = UInt16(a[a.index(after: colon)...]) {
            hostPart = String(a[..<colon]); port = p
        }
        return .hostPort(host: NWEndpoint.Host(hostPart), port: NWEndpoint.Port(rawValue: port)!)
    }

    private func pullFromGuest() {
        guard let g = guest else { return }
        if g.players != players { onPlayers(g.players) }
        players = g.players
        song = g.song
        myID = g.myID ?? ""
        hostName = g.hostName
        if g.scores != scores { scores = g.scores; onScores(g.scores) }
        if g.finals != finals { finals = g.finals; onFinals() }
        if let r = g.receiver, !r.done, r.offer.totalBytes > 0 {
            download = Double(r.received) / Double(r.offer.totalBytes)
        } else if g.receiver == nil || g.receiver?.done == true {
            download = nil
        }
        if let s = g.song, !playing {
            if let d = download { status = "Getting \(s.name) from the host: \(Int(d * 100))%" }
            else if receivedSongs[s.chartHash] != nil { status = "Ready (sent by the host)" }
            else { status = hasSong(s.chartHash) ? "Ready" : "You don't have \(s.name)" }
        }
    }

    // MARK: Shared

    private func receive(on c: NWConnection, data handle: @escaping (Data) -> Bool, closed: @escaping () -> Void) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard self != nil else { return }
                if let data, !data.isEmpty, !handle(data) { closed(); return }
                if complete || error != nil { closed(); return }
                self?.receive(on: c, data: handle, closed: closed)
            }
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.host?.tick(now: Self.now)
                if let g = self.guest {
                    g.tick(now: Self.now)
                    // Silent host: the socket may not notice, so we do.
                    if self.guestConnection != nil, g.myID != nil, g.isStale(now: Self.now) { self.connectionLost("No reply from the host") }
                }
            }
        }
    }

    private func finish(_ reason: String) {
        guard ended == nil else { return }
        ended = reason
        status = reason
        playing = false
        teardown()
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        listener?.cancel()
        listener = nil
        for c in connections.values { c.cancel() }
        connections = [:]
        guestConnection?.cancel()
        guestConnection = nil
    }

    // MARK: Actions

    var clockReady: Bool { guest?.clock.isReady ?? true }

    func pick(_ s: SongEntry) {
        host?.pick(NetSong(chartHash: s.chartHash, name: s.name, artist: s.artist, lengthMs: s.lengthMs))
    }

    func setPart(_ inst: Instrument, _ diff: Difficulty) {
        if let h = host { h.setHostPart(inst, diff) } else { guest?.setPart(inst, diff) }
    }

    /// Host: start the picked song for everyone in 4 s.
    func startSong(speed: Double) {
        guard let h = host, let s = h.song else { return }
        let at = Self.now + 4
        h.start(at: at, speed: speed)
        playing = true
        onStart(s.chartHash, at, speed)
    }

    func report(_ s: NetScore) {
        if let h = host { h.reportLocal(s) } else { guest?.report(s) }
    }

    func finishLocal(_ stats: PlayStats) {
        if let h = host { h.finishLocal(stats) } else { guest?.finish(stats) }
    }

    /// Host, after results (or quitting): back to the lobby.
    func endSong(abort: Bool) {
        playing = false
        host?.endSong(abort: abort)
    }

    func leave() {
        host?.close()
        guest?.leave()
        if guest != nil { OnlineSession.clearSongCache() }
        ended = "Left"
        // Stop listening and advertising right away (frees the port, so
        // hosting again works at once), then let the goodbye go out before
        // closing the connections. `self` is held on purpose: the app drops
        // this session as soon as leave() returns, and a weak reference
        // would skip the teardown and leave the listener running.
        listener?.cancel()
        listener = nil
        timer?.invalidate()
        timer = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.teardown() }
    }

    func name(of id: String) -> String { players.first { $0.id == id }?.name ?? "Player" }
}

/// Finds hosts on the local network (Bonjour).
@MainActor
final class OnlineBrowser: ObservableObject {
    struct Found: Identifiable, Hashable {
        var id: String { name }
        var name: String
        var endpoint: NWEndpoint
    }
    @Published private(set) var found: [Found] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: Net.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                self?.found = results.compactMap { r in
                    if case .service(let name, _, _, _) = r.endpoint { return Found(name: name, endpoint: r.endpoint) }
                    return nil
                }.sorted { $0.name < $1.name }
            }
        }
        browser = b
        b.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        found = []
    }
}

/// This phone's IPv4 addresses (Wi-Fi, Tailscale…) so others can join by address.
func localIPv4Addresses() -> [(name: String, address: String)] {
    var out: [(String, String)] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
    defer { freeifaddrs(ifaddr) }
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let i = p.pointee
        guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (i.ifa_flags & UInt32(IFF_LOOPBACK)) == 0, (i.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        let name = String(cString: i.ifa_name)
        let addr = String(cString: host)
        let label = name.hasPrefix("en") ? "Wi-Fi" : name.hasPrefix("utun") && addr.hasPrefix("100.") ? "Tailscale" : name
        out.append((label, addr))
    }
    return out
}
