import Foundation

/// Online play (LAN / tailnet). One device hosts; guests join it over TCP.
/// Every device plays the song from its own files and reports its score;
/// the host relays a scoreboard. This file is the transport-independent part:
/// messages, framing and clock sync. The app moves the bytes
/// (Network.framework); `Tools/check`'s `strumnet` does it with sockets.
public enum Net {
    /// TCP port the host listens on (also advertised over Bonjour).
    public static let port: UInt16 = 47821
    /// Bonjour service type.
    public static let serviceType = "_strumline._tcp"
    /// Bumped on incompatible protocol changes; mismatches are refused.
    public static let protocolVersion = 2
    /// Bytes per song-transfer chunk.
    public static let chunkSize = 64 * 1024
    /// A guest won't accept a song bigger than this.
    public static let maxSongBytes: Int64 = 1 << 30
    public static let maxSongFiles = 64
}

/// One player in an online lobby.
public struct NetPlayer: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var instrument: Instrument
    public var difficulty: Difficulty
    /// Has the song the host picked (by chart hash); nil before a pick.
    public var hasSong: Bool?
    public var connected = true
    /// 0…1 while the song is being sent to this player.
    public var download: Double?
    public init(id: String, name: String, instrument: Instrument, difficulty: Difficulty, hasSong: Bool? = nil) {
        self.id = id; self.name = name; self.instrument = instrument; self.difficulty = difficulty; self.hasSong = hasSong
    }
}

/// Live score during a song.
public struct NetScore: Codable, Sendable, Equatable {
    public var playerID: String
    public var score: Int
    public var combo: Int
    public var notesHit: Int
    public var notesTotal: Int
    public var spActive: Bool
    public init(playerID: String, score: Int, combo: Int, notesHit: Int, notesTotal: Int, spActive: Bool) {
        self.playerID = playerID; self.score = score; self.combo = combo; self.notesHit = notesHit; self.notesTotal = notesTotal; self.spActive = spActive
    }
}

/// The song the host picked.
public struct NetSong: Codable, Sendable, Equatable {
    public var chartHash: String
    public var name: String
    public var artist: String
    public var lengthMs: Int
    public init(chartHash: String, name: String, artist: String, lengthMs: Int) {
        self.chartHash = chartHash; self.name = name; self.artist = artist; self.lengthMs = lengthMs
    }
}

/// The files of a song a host offers to send (a folder's files, or one .sng).
public struct NetSongOffer: Codable, Sendable, Equatable {
    public struct File: Codable, Sendable, Equatable {
        public var name: String
        public var size: Int64
        public init(name: String, size: Int64) { self.name = name; self.size = size }
    }
    public var song: NetSong
    public var files: [File]
    public var isSng: Bool
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    public init(song: NetSong, files: [File], isSng: Bool) { self.song = song; self.files = files; self.isSng = isSng }

    /// A file name safe to create inside a folder: no paths, no hidden or
    /// odd names (a hostile host can't write outside the song's folder).
    public static func isSafeName(_ n: String) -> Bool {
        !n.isEmpty && n.count <= 128 && !n.hasPrefix(".") && !n.contains("/") && !n.contains("\\") && !n.contains("\0") && n != ".."
    }
}

/// One piece of a song file, sent as a binary frame (not JSON).
public struct NetChunk: Sendable, Equatable {
    public var chartHash: String
    public var file: Int
    public var offset: Int64
    public var bytes: Data
    public init(chartHash: String, file: Int, offset: Int64, bytes: Data) {
        self.chartHash = chartHash; self.file = file; self.offset = offset; self.bytes = bytes
    }
}

/// What a connection received: a message, or a song chunk.
public enum NetIncoming: Sendable, Equatable {
    case message(NetMessage)
    case chunk(NetChunk)
}

public enum NetMessage: Codable, Sendable, Equatable {
    // Joining
    case hello(version: Int, player: NetPlayer)                     // guest → host
    case welcome(playerID: String, hostName: String)                // host → guest
    case refused(reason: String)                                    // host → guest
    case lobby([NetPlayer])                                         // host → all
    case setPart(instrument: Instrument, difficulty: Difficulty)    // guest → host
    // Clock sync: guest sends its local time, host answers with its own.
    case ping(t0: Double)                                           // guest → host
    case pong(t0: Double, hostTime: Double)                         // host → guest
    // A song
    case pick(NetSong)                                              // host → all
    case songStatus(chartHash: String, has: Bool)                   // guest → host
    /// Start the song at `hostTime` on the host's clock, at `speed`.
    case start(chartHash: String, hostTime: Double, speed: Double)  // host → all
    case progress(NetScore)                                         // player → host
    case scoreboard([NetScore])                                     // host → all
    case finished(playerID: String, stats: PlayStats)               // player → host, relayed
    case abort                                                      // host → all (quit to lobby)
    case leave                                                      // either way
    // Sending the song to a guest who doesn't have it (then binary chunks).
    case songOffer(NetSongOffer)                                    // host → guest
    case songAccept(chartHash: String)                              // guest → host
    case songDecline(chartHash: String, reason: String)             // guest → host
    case transferProgress(chartHash: String, received: Int64, total: Int64)  // guest → host
    case songReceived(chartHash: String, ok: Bool, reason: String)  // guest → host
}

/// Length-prefixed frames: 4-byte big-endian length, then either a JSON
/// message (starts with "{") or a binary song chunk (starts with 0x00:
/// hash length, hash, file index u16, offset u64, bytes).
public struct NetFramer: Sendable {
    /// Larger frames are a broken or hostile peer.
    public static let maxFrame = 1 << 20
    private var buffer = Data()

    public init() {}

    private static func frame(_ body: Data) -> Data {
        var len = UInt32(body.count).bigEndian
        return Data(bytes: &len, count: 4) + body
    }

    public static func encode(_ m: NetMessage) -> Data {
        frame((try? JSONEncoder().encode(m)) ?? Data())
    }

    public static func encode(_ c: NetChunk) -> Data {
        var body = Data([0x00])
        let hash = Data(c.chartHash.utf8.prefix(255))
        body.append(UInt8(hash.count))
        body.append(hash)
        body.append(UInt8(truncatingIfNeeded: c.file >> 8)); body.append(UInt8(truncatingIfNeeded: c.file))
        for i in (0..<8).reversed() { body.append(UInt8(truncatingIfNeeded: c.offset >> (8 * Int64(i)))) }
        body.append(c.bytes)
        return frame(body)
    }

    public enum FrameError: Error { case tooLarge(Int), undecodable }

    /// Feeds received bytes; returns everything complete. Throws on a frame
    /// that's too large or malformed (drop the connection).
    public mutating func append(_ data: Data) throws -> [NetIncoming] {
        buffer.append(data)
        var out: [NetIncoming] = []
        while buffer.count >= 4 {
            let b = buffer.startIndex
            let len = Int(buffer[b]) << 24 | Int(buffer[b + 1]) << 16 | Int(buffer[b + 2]) << 8 | Int(buffer[b + 3])
            guard len <= NetFramer.maxFrame else { throw FrameError.tooLarge(len) }
            guard buffer.count >= 4 + len else { break }
            let body = Data(buffer[(b + 4)..<(b + 4 + len)])
            buffer.removeSubrange(b..<(b + 4 + len))
            if body.first == 0x00 {
                out.append(.chunk(try NetFramer.decodeChunk(body)))
            } else {
                guard let m = try? JSONDecoder().decode(NetMessage.self, from: body) else { throw FrameError.undecodable }
                out.append(.message(m))
            }
        }
        return out
    }

    private static func decodeChunk(_ d: Data) throws -> NetChunk {
        let b = [UInt8](d)
        guard b.count >= 2 else { throw FrameError.undecodable }
        let hl = Int(b[1])
        let head = 2 + hl + 2 + 8
        guard b.count >= head else { throw FrameError.undecodable }
        let hash = String(decoding: b[2..<(2 + hl)], as: UTF8.self)
        let file = Int(b[2 + hl]) << 8 | Int(b[3 + hl])
        var off: Int64 = 0
        for i in 0..<8 { off = off << 8 | Int64(b[4 + hl + i]) }
        return NetChunk(chartHash: hash, file: file, offset: off, bytes: Data(b[head...]))
    }
}

/// Estimates the host's clock from ping/pong round trips (NTP-style): the
/// sample with the smallest round trip is the most accurate.
public struct ClockSync: Sendable {
    public struct Sample: Sendable { public var offset: Double; public var rtt: Double }
    public private(set) var samples: [Sample] = []
    public init() {}

    /// `t0` = local send time, `hostTime` = host's clock when it answered,
    /// `t2` = local receive time.
    public mutating func add(t0: Double, hostTime: Double, t2: Double) {
        let rtt = t2 - t0
        guard rtt >= 0, rtt < 2 else { return }
        samples.append(Sample(offset: hostTime - (t0 + t2) / 2, rtt: rtt))
        if samples.count > 32 { samples.removeFirst(samples.count - 32) }
    }

    /// host clock − local clock, from the fastest round trip; nil until a sample.
    public var offset: Double? { samples.min { $0.rtt < $1.rtt }?.offset }
    /// Best round trip seen (how much to trust `offset`: error ≤ rtt / 2).
    public var bestRTT: Double? { samples.map(\.rtt).min() }
    public var isReady: Bool { samples.count >= 5 }

    public func localTime(forHost h: Double) -> Double? { offset.map { h - $0 } }
    public func hostTime(forLocal l: Double) -> Double? { offset.map { l + $0 } }
}
