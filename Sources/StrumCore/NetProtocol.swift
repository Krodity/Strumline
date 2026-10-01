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
    public static let protocolVersion = 1
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
}

/// Length-prefixed JSON frames: 4-byte big-endian length, then the message.
public struct NetFramer: Sendable {
    /// Larger frames are a broken or hostile peer.
    public static let maxFrame = 1 << 20
    private var buffer = Data()

    public init() {}

    public static func encode(_ m: NetMessage) -> Data {
        let body = (try? JSONEncoder().encode(m)) ?? Data()
        var len = UInt32(body.count).bigEndian
        return Data(bytes: &len, count: 4) + body
    }

    public enum FrameError: Error { case tooLarge(Int), undecodable }

    /// Feeds received bytes; returns every complete message. Throws on a
    /// frame that's too large or isn't a message (drop the connection).
    public mutating func append(_ data: Data) throws -> [NetMessage] {
        buffer.append(data)
        var out: [NetMessage] = []
        while buffer.count >= 4 {
            let b = buffer.startIndex
            let len = Int(buffer[b]) << 24 | Int(buffer[b + 1]) << 16 | Int(buffer[b + 2]) << 8 | Int(buffer[b + 3])
            guard len <= NetFramer.maxFrame else { throw FrameError.tooLarge(len) }
            guard buffer.count >= 4 + len else { break }
            let body = buffer[(b + 4)..<(b + 4 + len)]
            guard let m = try? JSONDecoder().decode(NetMessage.self, from: Data(body)) else { throw FrameError.undecodable }
            out.append(m)
            buffer.removeSubrange(b..<(b + 4 + len))
        }
        return out
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
