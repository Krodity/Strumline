import Foundation

public enum InstrumentKind: String, Codable, Sendable {
    case fiveFret, sixFret, drums
}

public enum Instrument: String, CaseIterable, Codable, Sendable, Identifiable {
    case guitar, guitarCoop, rhythm, bass, keys, drums
    case guitarGHL, bassGHL, rhythmGHL, coopGHL

    public var id: String { rawValue }

    public var kind: InstrumentKind {
        switch self {
        case .drums: return .drums
        case .guitarGHL, .bassGHL, .rhythmGHL, .coopGHL: return .sixFret
        default: return .fiveFret
        }
    }

    public var displayName: String {
        switch self {
        case .guitar: return "Guitar"
        case .guitarCoop: return "Guitar Co-op"
        case .rhythm: return "Rhythm"
        case .bass: return "Bass"
        case .keys: return "Keys"
        case .drums: return "Drums"
        case .guitarGHL: return "6-Fret Guitar"
        case .bassGHL: return "6-Fret Bass"
        case .rhythmGHL: return "6-Fret Rhythm"
        case .coopGHL: return "6-Fret Co-op"
        }
    }

    /// song.ini difficulty tag.
    public var iniDifficultyKey: String {
        switch self {
        case .guitar: return "diff_guitar"
        case .guitarCoop: return "diff_guitar_coop"
        case .rhythm: return "diff_rhythm"
        case .bass: return "diff_bass"
        case .keys: return "diff_keys"
        case .drums: return "diff_drums"
        case .guitarGHL: return "diff_guitarghl"
        case .bassGHL: return "diff_bassghl"
        case .rhythmGHL: return "diff_rhythm_ghl"
        case .coopGHL: return "diff_guitar_coop_ghl"
        }
    }

    /// Bass-type parts go up to a 6x multiplier, like Clone Hero.
    public var maxMultiplier: Int {
        switch self {
        case .bass, .bassGHL: return 6
        default: return 4
        }
    }

    /// The audio stems this part controls (muted on misses).
    public var stems: [StemRole] {
        switch self {
        case .guitar, .guitarGHL, .guitarCoop, .coopGHL: return [.guitar]
        case .rhythm, .rhythmGHL: return [.rhythm]
        case .bass, .bassGHL: return [.bass]
        case .keys: return [.keys]
        case .drums: return [.drums, .drums1, .drums2, .drums3, .drums4]
        }
    }
}

public enum Difficulty: Int, CaseIterable, Codable, Sendable, Comparable, Identifiable {
    case easy, medium, hard, expert
    public var id: Int { rawValue }
    public static func < (a: Difficulty, b: Difficulty) -> Bool { a.rawValue < b.rawValue }
    public var displayName: String {
        switch self {
        case .easy: return "Easy"
        case .medium: return "Medium"
        case .hard: return "Hard"
        case .expert: return "Expert"
        }
    }
}

public enum DrumType: String, Codable, Sendable {
    case fourLane, fourLanePro, fiveLane
}

public enum StemRole: String, CaseIterable, Codable, Sendable {
    case song, guitar, rhythm, bass, keys, drums, drums1, drums2, drums3, drums4
    case vocals, vocals1, vocals2, crowd, preview
    public var fileBase: String {
        switch self {
        case .drums1: return "drums_1"
        case .drums2: return "drums_2"
        case .drums3: return "drums_3"
        case .drums4: return "drums_4"
        case .vocals1: return "vocals_1"
        case .vocals2: return "vocals_2"
        default: return rawValue
        }
    }
}

// MARK: - Lanes

/// Lane numbering used everywhere after parsing.
public enum Lane {
    // 5-fret
    public static let green = 0, red = 1, yellow = 2, blue = 3, orange = 4
    public static let open5 = 5
    // 6-fret: black row 0-2, white row 3-5, open 6. Column = lane % 3.
    public static let black1 = 0, black2 = 1, black3 = 2, white1 = 3, white2 = 4, white3 = 5
    public static let open6 = 6
    // drums
    public static let kick = 0, drumRed = 1, drumYellow = 2, drumBlue = 3
    /// 4-lane green / 5-lane orange.
    public static let drum4 = 4
    /// 5-lane green.
    public static let drum5 = 5
}

// MARK: - Chart

public enum NoteKind: UInt8, Codable, Sendable {
    case strum, hopo, tap
}

public struct Gem: Sendable, Hashable {
    public var lane: Int
    public var endTick: Int
    public var endTime: Double
    public var cymbal: Bool = false
    public var accent: Bool = false
    public var ghost: Bool = false
    public var doubleKick: Bool = false
}

public struct Chord: Sendable {
    public var tick: Int
    public var time: Double
    public var gems: [Gem]
    public var kind: NoteKind = .strum
    /// Index into `TrackChart.starPower`, or -1.
    public var spPhrase: Int = -1
    /// Last chord of its star power phrase.
    public var spPhraseEnd = false
    /// Index into `TrackChart.solos`, or -1.
    public var solo: Int = -1
    /// Drums: hitting this note activates star power (end of a fill).
    public var activation = false

    public var mask: UInt32 {
        var m: UInt32 = 0
        for g in gems { m |= 1 << UInt32(g.lane) }
        return m
    }
    public var isChord: Bool { gems.count > 1 }
    public var sustainEndTime: Double { gems.map(\.endTime).max() ?? time }
    public var hasSustain: Bool { gems.contains { $0.endTick > tick } }
}

public struct Phrase: Sendable {
    public var startTick: Int
    public var endTick: Int
    public var startTime: Double
    public var endTime: Double
}

public struct ChartSection: Sendable, Identifiable {
    public var id: Int { tick }
    public var name: String
    public var tick: Int
    public var time: Double
}

public struct TrackKey: Hashable, Sendable {
    public var instrument: Instrument
    public var difficulty: Difficulty
    public init(_ i: Instrument, _ d: Difficulty) { instrument = i; difficulty = d }
}

public struct TrackChart: Sendable {
    public var instrument: Instrument
    public var difficulty: Difficulty
    public var chords: [Chord] = []
    public var starPower: [Phrase] = []
    public var solos: [Phrase] = []
    public var fills: [Phrase] = []
    /// Only meaningful for drums: what the chart was authored as.
    public var drumType: DrumType = .fourLane

    public var noteCount: Int {
        instrument.kind == .drums ? chords.reduce(0) { $0 + $1.gems.count } : chords.count
    }
}

public struct Lyric: Sendable {
    public var time: Double
    public var text: String
}

public final class SongChart: @unchecked Sendable {
    public let resolution: Int
    public let tempo: TempoMap
    public var sections: [ChartSection]
    public var tracks: [TrackKey: TrackChart]
    public var lyrics: [Lyric]
    /// Time of an explicit [end] event, if any.
    public var endEventTime: Double?

    init(resolution: Int, tempo: TempoMap, sections: [ChartSection], tracks: [TrackKey: TrackChart], lyrics: [Lyric], endEventTime: Double?) {
        self.resolution = resolution
        self.tempo = tempo
        self.sections = sections
        self.tracks = tracks
        self.lyrics = lyrics
        self.endEventTime = endEventTime
    }

    public func track(_ i: Instrument, _ d: Difficulty) -> TrackChart? { tracks[TrackKey(i, d)] }

    public var availableParts: [Instrument: [Difficulty]] {
        var out: [Instrument: [Difficulty]] = [:]
        for (k, t) in tracks where !t.chords.isEmpty {
            out[k.instrument, default: []].append(k.difficulty)
        }
        return out.mapValues { $0.sorted() }
    }

    /// Time of the last note or sustain end across every track.
    public var lastNoteTime: Double {
        var t = 0.0
        for tr in tracks.values { if let c = tr.chords.last { t = max(t, c.sustainEndTime) } }
        return t
    }
}

// MARK: - Tempo map

public struct TempoMap: Sendable {
    public struct Tempo: Sendable { public var tick: Int; public var usPerQuarter: Double; public var time: Double }
    public struct TimeSig: Sendable { public var tick: Int; public var numerator: Int; public var denominator: Int }
    public enum BeatKind: Sendable { case measure, beat, half }
    public struct BeatLine: Sendable { public var time: Double; public var kind: BeatKind }

    public let resolution: Int
    public private(set) var tempos: [Tempo]
    public private(set) var timeSigs: [TimeSig]
    /// Chart-to-audio shift in seconds (chart Offset + song.ini delay).
    public let offset: Double

    init(resolution: Int, tempos rawTempos: [(Int, Double)], timeSigs rawSigs: [(Int, Int, Int)], offset: Double) {
        self.resolution = max(1, resolution)
        self.offset = offset
        var ts = rawTempos.filter { $0.1 > 0 }.sorted { $0.0 < $1.0 }
        if ts.first?.0 != 0 { ts.insert((0, 500_000), at: 0) }
        // Later duplicates at the same tick win.
        var dedup: [(Int, Double)] = []
        for t in ts { if dedup.last?.0 == t.0 { dedup[dedup.count - 1] = t } else { dedup.append(t) } }
        var out: [Tempo] = []
        var time = offset
        for (i, t) in dedup.enumerated() {
            if i > 0 {
                let p = dedup[i - 1]
                time += Double(t.0 - p.0) / Double(self.resolution) * p.1 / 1_000_000
            }
            out.append(Tempo(tick: t.0, usPerQuarter: t.1, time: time))
        }
        tempos = out
        var sigs = rawSigs.filter { $0.1 > 0 && $0.2 > 0 }.sorted { $0.0 < $1.0 }.map { TimeSig(tick: $0.0, numerator: $0.1, denominator: $0.2) }
        if sigs.first?.tick != 0 { sigs.insert(TimeSig(tick: 0, numerator: 4, denominator: 4), at: 0) }
        timeSigs = sigs
    }

    private func tempoIndex(tick: Double) -> Int {
        var lo = 0, hi = tempos.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if Double(tempos[mid].tick) <= tick { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    public func time(at tick: Int) -> Double { time(atTick: Double(tick)) }

    public func time(atTick tick: Double) -> Double {
        let t = tempos[tempoIndex(tick: tick)]
        return t.time + (tick - Double(t.tick)) / Double(resolution) * t.usPerQuarter / 1_000_000
    }

    public func tick(at time: Double) -> Double {
        var lo = 0, hi = tempos.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if tempos[mid].time <= time { lo = mid } else { hi = mid - 1 }
        }
        let t = tempos[lo]
        return Double(t.tick) + (time - t.time) * 1_000_000 / t.usPerQuarter * Double(resolution)
    }

    /// Beats (quarter notes) elapsed between two times — used for sustain
    /// scoring and star power drain, which are tempo-relative.
    public func beats(from a: Double, to b: Double) -> Double {
        (tick(at: b) - tick(at: a)) / Double(resolution)
    }

    public func bpm(at time: Double) -> Double {
        var lo = 0, hi = tempos.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if tempos[mid].time <= time { lo = mid } else { hi = mid - 1 }
        }
        return 60_000_000 / tempos[lo].usPerQuarter
    }

    /// Measure, beat and half-beat lines up to `endTime`.
    public func beatLines(until endTime: Double) -> [BeatLine] {
        var out: [BeatLine] = []
        let endTick = Int(tick(at: endTime)) + resolution
        for (i, sig) in timeSigs.enumerated() {
            let stop = i + 1 < timeSigs.count ? timeSigs[i + 1].tick : endTick
            let step = max(1, resolution * 4 / max(1, sig.denominator))
            var t = sig.tick
            var beat = 0
            while t < stop {
                out.append(BeatLine(time: time(at: t), kind: beat % max(1, sig.numerator) == 0 ? .measure : .beat))
                if step >= 2 && t + step / 2 < stop {
                    out.append(BeatLine(time: time(at: t + step / 2), kind: .half))
                }
                t += step
                beat += 1
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    /// Ticks per measure at a tick (for star power drain across time sigs).
    public func beatsPerMeasure(atTick tick: Int) -> Double {
        var sig = timeSigs[0]
        for s in timeSigs where s.tick <= tick { sig = s }
        return Double(sig.numerator) * 4.0 / Double(sig.denominator)
    }
}
