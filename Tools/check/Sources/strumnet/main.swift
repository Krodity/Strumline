import Foundation
import StrumCore
#if canImport(Glibc)
import Glibc
#endif

// strumnet — a stand-in online player for testing Strumline's online play
// with one phone. Uses the same NetHost / NetGuest code as the app.
//
//   strumnet join <address[:port]> [--name PC] [--no-song]
//       Joins the phone's session. Claims to have every song; with
//       --no-song it says it doesn't, so the host sends it (checked and
//       kept in a temp folder). Plays along with a simulated score.
//   strumnet host [--name PC] [--songs <folder>] [--wait 20]
//       Hosts a session. Picks the first song in --songs (default: the
//       bundled demo), sends it to guests who don't have it, and starts it
//       for everyone once a guest has it, or after --wait seconds.

/// Prints and flushes at once (output is often piped / tee'd while testing).
func say(_ s: String) { print(s); fflush(nil) }
var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i); return true
}
let name = option("--name") ?? "PC"
let songsDir = option("--songs") ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../../../Sources/Strumline/Resources/Songs").standardizedFileURL.path
let waitSeconds = Double(option("--wait") ?? "20") ?? 20
let noSong = flag("--no-song")
guard let mode = args.first, mode == "join" || mode == "host" else {
    say("usage: strumnet join <address[:port]> [--name PC] [--no-song]\n       strumnet host [--name PC] [--songs <folder>] [--wait 20]")
    exit(2)
}
func now() -> Double { ProcessInfo.processInfo.systemUptime }
func stamp() -> String { String(format: "[%7.2f]", now().truncatingRemainder(dividingBy: 10000)) }
let me = NetPlayer(id: "", name: name, instrument: .guitar, difficulty: .expert)

// MARK: Sockets (poll loop, non-blocking)

final class Conn {
    let fd: Int32
    var framer = NetFramer()
    var out = Data()
    init(fd: Int32) { self.fd = fd }
    func send(_ m: NetMessage) { out.append(NetFramer.encode(m)) }
    /// Flushes what it can; false if the socket is dead.
    func flush() -> Bool {
        while !out.isEmpty {
            let n = out.withUnsafeBytes { Glibc.send(fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
            if n > 0 { out.removeFirst(n) } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return true } else { return false }
        }
        return true
    }
    /// Reads what's there; nil when closed.
    func read() -> Data? {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = recv(fd, &buf, buf.count, 0)
        if n > 0 { return Data(buf[0..<n]) }
        if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return Data() }
        return nil
    }
}
func nonBlocking(_ fd: Int32) { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }

func resolve(_ host: String, _ port: UInt16) -> sockaddr_in? {
    var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &res) == 0, let r = res else { return nil }
    defer { freeaddrinfo(res) }
    return r.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
}

/// Simulated playing: a score that climbs while the song runs.
struct FakePlay {
    var start: Double
    var length: Double
    var total = 300
    func score(at t: Double) -> NetScore {
        let p = max(0, min(1, (t - start) / length))
        let hit = Int(Double(total) * p * 0.93)
        return NetScore(playerID: "", score: hit * 50 * 3, combo: hit % 120, notesHit: hit, notesTotal: Int(Double(total) * p), spActive: Int(p * 10) % 3 == 1)
    }
    func done(at t: Double) -> Bool { t >= start + length }
    func stats() -> PlayStats {
        var s = PlayStats(); s.notesTotal = total; s.notesHit = Int(Double(total) * 0.93); s.score = s.notesHit * 150
        s.bestStreak = 118; s.stars = 4
        return s
    }
}

// MARK: Join

if mode == "join" {
    guard args.count >= 2 else { say("join needs an address"); exit(2) }
    var hostPart = args[1], port = Net.port
    if let c = hostPart.lastIndex(of: ":"), let p = UInt16(hostPart[hostPart.index(after: c)...]) { port = p; hostPart = String(hostPart[..<c]) }
    guard var addr = resolve(hostPart, port) else { say("can't resolve \(hostPart)"); exit(1) }
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard ok == 0 else { say("can't connect to \(hostPart):\(port): \(String(cString: strerror(errno)))"); exit(1) }
    nonBlocking(fd)
    let c = Conn(fd: fd)
    let g = NetGuest(me: me)
    var play: FakePlay?
    var lastReport = 0.0, lastBoard = "", lastBoardAt = 0.0
    g.send = { c.send($0) }
    g.hasSong = { hash in say("\(stamp()) host picked \(g.song?.name ?? hash) — \(noSong ? "don't have it, asking for it" : "have it")"); return !noSong }
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent("strumnet-songs", isDirectory: true)
    g.songCache = cache
    var receivedSong: SongEntry?
    g.onSongReceived = { e in
        receivedSong = e
        let files = (try? FileManager.default.contentsOfDirectory(atPath: e.url.path).count) ?? 1
        say("\(stamp()) received \(e.name) — \(e.artist): \(files) file(s), chart hash \(e.chartHash) ✓ (in \(e.url.path))")
    }
    var lastPct = -1
    g.onChange = {
        let board = g.scores.map { s in "\(g.players.first { $0.id == s.playerID }?.name ?? s.playerID) \(s.score)" }.joined(separator: " · ")
        if !board.isEmpty && board != lastBoard && now() - lastBoardAt >= 2 { lastBoard = board; lastBoardAt = now(); say("\(stamp()) scoreboard: \(board)") }
    }
    g.onStart = { hash, at, speed in
        let wait = at - now()
        say("\(stamp()) start \(hash) in \(String(format: "%.3f", wait)) s (speed \(speed), clock offset \(String(format: "%.1f", (g.clock.offset ?? 0) * 1000)) ms, best RTT \(String(format: "%.0f", (g.clock.bestRTT ?? 0) * 1000)) ms)")
        if !noSong || receivedSong?.chartHash == hash { play = FakePlay(start: at, length: min(30, Double(g.song?.lengthMs ?? 30000) / 1000)) }
        else { say("\(stamp()) don't have it: sitting this one out") }
    }
    g.onAbort = { say("\(stamp()) host stopped the song"); play = nil }
    g.onEnd = { reason in say("\(stamp()) session over: \(reason)"); exit(0) }
    var lastPlayers = ""
    g.connected(now: now())
    say("\(stamp()) connected to \(hostPart):\(port) as \(name)")
    while true {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        _ = poll(&p, 1, 50)
        if p.revents & Int16(POLLIN) != 0 {
            guard let d = c.read() else { say("\(stamp()) connection closed"); exit(0) }
            do { for m in try c.framer.append(d) { g.receive(m, now: now()) } } catch { say("bad data from host"); exit(1) }
        }
        let t = now()
        g.tick(now: t)
        if let r = g.receiver, !r.done, r.offer.totalBytes > 0 {
            let pct = Int(Double(r.received) * 100 / Double(r.offer.totalBytes))
            if pct / 10 != lastPct / 10 { lastPct = pct; say("\(stamp()) receiving \(r.offer.song.name): \(pct)% of \(r.offer.totalBytes / 1_000_000) MB") }
        }
        let ps = g.players.map { "\($0.name)[\($0.instrument.rawValue)/\($0.difficulty.displayName)\($0.hasSong == true ? " ✓" : $0.hasSong == false ? " ✗" : "")]" }.joined(separator: ", ")
        if ps != lastPlayers { lastPlayers = ps; say("\(stamp()) lobby: \(ps)") }
        if let pl = play, t >= pl.start {
            if t - lastReport >= 0.25 { lastReport = t; g.report(pl.score(at: t)) }
            if pl.done(at: t) { g.finish(pl.stats()); say("\(stamp()) finished, sent results (\(pl.stats().score))"); play = nil }
        }
        if !c.flush() { say("\(stamp()) connection lost"); exit(0) }
    }
}

// MARK: Host

let scan = LibraryScanner.scan(roots: [URL(fileURLWithPath: songsDir)], cache: [:])
guard let song = scan.songs.first else { say("no songs in \(songsDir)"); exit(1) }
let lfd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
var yes: Int32 = 1
setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
var sin = sockaddr_in(); sin.sin_family = sa_family_t(AF_INET); sin.sin_port = Net.port.bigEndian; sin.sin_addr.s_addr = INADDR_ANY
let bound = withUnsafePointer(to: &sin) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
guard bound == 0, listen(lfd, 8) == 0 else { say("can't listen on \(Net.port): \(String(cString: strerror(errno)))"); exit(1) }
nonBlocking(lfd)
say("\(stamp()) hosting as \(name) on port \(Net.port) — join from the phone: Online › Join by address › this PC's IP")
say("\(stamp()) song: \(song.name) — \(song.artist) [\(song.chartHash)]")

let h = NetHost(host: me)
var conns: [Int32: Conn] = [:]
h.send = { fd, m in conns[Int32(fd)]?.send(m) }
h.sendChunk = { fd, c in conns[Int32(fd)]?.out.append(NetFramer.encode(c)) }
// Flow control: keep at most ~512 KB queued per guest.
h.canSend = { fd in (conns[Int32(fd)]?.out.count ?? Int.max) < 512 * 1024 }
let source = NetSongSource.make(for: song)
h.songSource = { $0 == song.chartHash ? source : nil }
say("\(stamp()) can send it to guests who don't have it: \(source.map { "\($0.offer.files.count) files, \($0.offer.totalBytes / 1_000_000) MB" } ?? "no")")
var lastBoard = "", lastBoardAt = 0.0
h.onChange = {
    let board = h.players.compactMap { p in h.scores[p.id].map { "\(p.name) \($0.score)" } }.joined(separator: " · ")
    if !board.isEmpty && board != lastBoard && now() - lastBoardAt >= 2 { lastBoard = board; lastBoardAt = now(); say("\(stamp()) scoreboard: \(board)") }
}
var firstGuestAt: Double?
var play: FakePlay?
var lastReport = 0.0, lastPlayers = ""
var picked = false, finishedSong = false
while true {
    // Wake for writing too while a guest has data queued (song transfers).
    var fds = [pollfd(fd: lfd, events: Int16(POLLIN), revents: 0)] + conns.map { pollfd(fd: $0.key, events: Int16(POLLIN) | ($0.value.out.isEmpty ? 0 : Int16(POLLOUT)), revents: 0) }
    _ = poll(&fds, nfds_t(fds.count), 50)
    if fds[0].revents & Int16(POLLIN) != 0 {
        let cfd = accept(lfd, nil, nil)
        if cfd >= 0 { nonBlocking(cfd); conns[cfd] = Conn(fd: cfd); say("\(stamp()) connection \(cfd)") }
    }
    for p in fds.dropFirst() where p.revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
        guard let c = conns[p.fd] else { continue }
        guard let d = c.read() else { conns[p.fd] = nil; close(p.fd); h.disconnected(Int(p.fd)); say("\(stamp()) \(p.fd) left"); continue }
        do { for case .message(let m) in try c.framer.append(d) { h.receive(m, from: Int(p.fd), now: now()) } }
        catch { conns[p.fd] = nil; close(p.fd); h.disconnected(Int(p.fd)) }
    }
    let t = now()
    h.tick(now: t)
    let ps = h.players.map { "\($0.name)[\($0.instrument.rawValue)/\($0.difficulty.displayName)\($0.hasSong == true ? " ✓" : $0.hasSong == false ? " ✗" : "")\($0.download.map { " ↓\(Int($0 * 10) * 10)%" } ?? "")]" }.joined(separator: ", ")
    if ps != lastPlayers { lastPlayers = ps; say("\(stamp()) lobby: \(ps)") }
    if h.players.count > 1 && firstGuestAt == nil { firstGuestAt = t }
    if let f = firstGuestAt, !picked, t - f > 2 {
        picked = true
        h.pick(NetSong(chartHash: song.chartHash, name: song.name, artist: song.artist, lengthMs: song.lengthMs))
        say("\(stamp()) picked \(song.name); starting when a guest has it (or in \(Int(waitSeconds)) s)")
    }
    if picked, play == nil, !finishedSong, h.phase == .lobby {
        let anyReady = h.players.dropFirst().contains { $0.hasSong == true }
        let stillSending = h.sending
        if (anyReady && !stillSending) || t - (firstGuestAt ?? t) > waitSeconds + 2 {
            let at = t + 5
            h.start(at: at, speed: 1)
            play = FakePlay(start: at, length: min(30, Double(song.lengthMs) / 1000))
            say("\(stamp()) starting for everyone in 5 s")
        }
    }
    if let pl = play, t >= pl.start {
        if t - lastReport >= 0.25 { lastReport = t; h.reportLocal(pl.score(at: t)) }
        if pl.done(at: t) {
            h.finishLocal(pl.stats())
            say("\(stamp()) host finished; results so far: \(h.finals.map { f in "\(h.players.first { $0.id == f.key }?.name ?? f.key) \(f.value.score)" }.joined(separator: ", "))")
            play = nil; finishedSong = true
        }
    }
    for (fd, c) in conns where !c.flush() { conns[fd] = nil; close(fd); h.disconnected(Int(fd)) }
}
