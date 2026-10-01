import Foundation

public struct EngineConfig: Codable, Sendable {
    /// Total hit window in seconds (split evenly early/late). Clone Hero uses 140 ms.
    public var hitWindow: Double = 0.14
    /// A strum may come this long before the frets that complete it.
    public var strumLeniency: Double = 0.05
    /// Strums this soon after a hammer-on/pull-off/tap hit are ignored.
    public var hopoLeniency: Double = 0.08
    /// Releasing a sustain this close to its end still counts as holding it.
    public var sustainDropLeniency: Double = 0.06
    /// How long a whammy movement keeps star power filling.
    public var whammyBuffer: Double = 0.25
    public var drumOverhitBreaksCombo = false
    public init() {}
}

public enum PlayInput: Sendable {
    case fret(lane: Int, down: Bool)
    case strum
    case whammy(Double)
    case starPower
    /// `velocity` 1-127 from MIDI kits; nil for pads without velocity.
    case drum(lane: Int, cymbal: Bool, velocity: Int?)
}

public enum JudgeEvent: Sendable {
    case hit(chord: Int, lanes: UInt32)
    case miss(chord: Int)
    case overstrum
    case spPhraseComplete
    case spPhraseBroken
    case spReady
    case spActivated
    case spEnded
    case soloStart(Int)
    case soloEnd(hit: Int, total: Int, bonus: Int)
    case streak(Int)
}

public struct SectionStat: Sendable, Codable {
    public var name: String
    public var hit: Int
    public var total: Int
    /// Index into the chart's sections (for practising it), or -1 when the
    /// chart has none and the whole song is one "section".
    public var index: Int = -1
    public var accuracy: Double { total > 0 ? Double(hit) / Double(total) : 0 }
}

public struct PlayStats: Sendable, Codable {
    public var score = 0
    public var notesHit = 0
    public var notesTotal = 0
    public var bestStreak = 0
    public var overstrums = 0
    public var spPhrasesHit = 0
    public var spPhrasesTotal = 0
    public var stars = 0
    public var sections: [SectionStat] = []
    public var fullCombo: Bool { notesHit == notesTotal && overstrums == 0 && notesTotal > 0 }
    public var accuracy: Double { notesTotal == 0 ? 0 : Double(notesHit) / Double(notesTotal) }
}

/// Scores one player on one track. Feed it timestamped inputs in time order
/// and call `advance(to:)` every frame; both run on the same thread.
public final class PlayEngine {
    public let track: TrackChart
    public let tempo: TempoMap
    public let config: EngineConfig
    public let isDrums: Bool
    public let enforceCymbals: Bool
    private let front: Double
    private let back: Double
    /// Per-chord half hit window (Precision Mode shrinks it for fast notes).
    private let half: [Double]
    public let modifiers: Modifiers
    private let hopoLeniency: Double
    private var ghostPresses = 0
    private var ghostPenalised = false
    private let maxMultiplier: Int
    private let openLane: Int
    private let sixFret: Bool

    public enum State: UInt8 { case pending, hit, missed }
    public private(set) var chordState: [State]
    /// Drums: per-chord bitmask of gem indices already hit.
    public private(set) var gemHit: [UInt32]
    public private(set) var gemMissed: [UInt32]

    public private(set) var scoreValue: Double = 0
    public var score: Int { Int(scoreValue) }
    public private(set) var combo = 0
    public private(set) var bestCombo = 0
    public private(set) var notesHit = 0
    public private(set) var overstrums = 0
    public private(set) var spMeter: Double = 0
    public private(set) var spActive = false
    public private(set) var spPhrasesHit = 0
    public private(set) var frets: UInt32 = 0
    public private(set) var whammy: Double = 0
    public private(set) var now: Double = -.infinity
    public private(set) var soloHits: [Int]
    public private(set) var soloTotals: [Int]
    public private(set) var currentSolo: Int = -1
    public private(set) var lastHitTime: [Double]  // per lane, for hit flashes

    private var brokenPhrases = Set<Int>()
    /// Phrases already completed and awarded (kept apart from `brokenPhrases`
    /// so whammying the last note's sustain still fills the meter).
    private var completedPhrases = Set<Int>()
    private var next = 0
    private var lastFretChange: Double = -.infinity
    private var lastWhammyMove: Double = -.infinity
    private var strumIgnoreUntil: Double = -.infinity
    private var pendingStrum: Double? = nil
    private var lastFretHitTime: Double = -.infinity
    private var sectionIndex: [Int]  // per chord
    private var sectionHit: [Int]
    private var sectionTotal: [Int]
    private let sectionNames: [String]
    private let hasSections: Bool
    private var events: [JudgeEvent] = []
    private var sustainScoreBank: Double = 0

    public struct Sustain { public var chord: Int; public var lane: Int; public var end: Double; public var lastTime: Double; public var sp: Bool }
    public private(set) var sustains: [Sustain] = []

    public var multiplier: Int {
        let base = min(1 + combo / 10, maxMultiplier)
        return spActive ? base * 2 : base
    }
    /// Progress toward the next multiplier step, 0...1.
    public var multiplierProgress: Double {
        let base = 1 + combo / 10
        if base >= maxMultiplier { return 1 }
        return Double(combo % 10) / 10
    }

    public init(track: TrackChart, tempo: TempoMap, sections: [ChartSection], config: EngineConfig, drumMode: DrumPlayMode, modifiers: Modifiers = Modifiers()) {
        self.modifiers = modifiers
        self.track = track
        self.tempo = tempo
        self.config = config
        isDrums = track.instrument.kind == .drums
        sixFret = track.instrument.kind == .sixFret
        enforceCymbals = drumMode == .fourLanePro && track.drumType != .fourLane
        front = config.hitWindow / 2
        back = config.hitWindow / 2
        var h = [Double](repeating: config.hitWindow / 2, count: track.chords.count)
        if modifiers.precision {
            let isDrum = track.instrument.kind == .drums
            let (lo, hi) = isDrum ? (0.035, 0.05) : (0.03, 0.05)
            for i in h.indices {
                let prev = i > 0 ? track.chords[i].time - track.chords[i - 1].time : 1
                let nxt = i + 1 < h.count ? track.chords[i + 1].time - track.chords[i].time : 1
                h[i] = min(hi, max(lo, min(prev, nxt) * 0.45))
            }
        }
        half = h
        hopoLeniency = modifiers.drunk ? 0.12 : modifiers.precision ? 0.04 : config.hopoLeniency
        maxMultiplier = track.instrument.maxMultiplier
        openLane = sixFret ? Lane.open6 : Lane.open5
        chordState = Array(repeating: .pending, count: track.chords.count)
        gemHit = Array(repeating: 0, count: track.chords.count)
        gemMissed = Array(repeating: 0, count: track.chords.count)
        soloHits = Array(repeating: 0, count: track.solos.count)
        soloTotals = Array(repeating: 0, count: track.solos.count)
        lastHitTime = Array(repeating: -.infinity, count: 8)
        for c in track.chords where c.solo >= 0 {
            soloTotals[c.solo] += isDrums ? c.gems.count : 1
        }
        var names = sections.map(\.name)
        var idx = [Int](repeating: 0, count: track.chords.count)
        if names.isEmpty { names = ["Song"] }
        var s = 0
        for (i, c) in track.chords.enumerated() {
            while s + 1 < sections.count && sections[s + 1].tick <= c.tick { s += 1 }
            idx[i] = sections.isEmpty ? 0 : s
        }
        sectionNames = names
        hasSections = !sections.isEmpty
        sectionIndex = idx
        sectionHit = Array(repeating: 0, count: names.count)
        sectionTotal = Array(repeating: 0, count: names.count)
        for (i, c) in track.chords.enumerated() { sectionTotal[idx[i]] += isDrums ? c.gems.count : 1 }
    }

    public var notesTotal: Int { track.noteCount }

    /// Events produced since the last call.
    public func drainEvents() -> [JudgeEvent] {
        defer { events.removeAll(keepingCapacity: true) }
        return events
    }

    // MARK: Time

    public func advance(to t: Double) {
        guard t > now else { return }
        let prev = now
        if prev.isFinite { tickSustainsAndSP(from: prev, to: t) }
        now = t
        processMisses(at: t)
        if let p = pendingStrum, t > p + config.strumLeniency {
            pendingStrum = nil
            overstrum()
        }
        if !isDrums { tryFretHit(at: t, onlyFreshFrets: true) }
    }

    private func tickSustainsAndSP(from a: Double, to b: Double) {
        if !sustains.isEmpty {
            var kept: [Sustain] = []
            for var s in sustains {
                let end = min(b, s.end)
                if end > s.lastTime {
                    let beats = tempo.beats(from: s.lastTime, to: end)
                    // 25 points per beat per sustained note.
                    scoreValue += 25 * beats * Double(multiplier)
                    if s.sp && (spActive || !brokenPhrases.contains(track.chords[s.chord].spPhrase)) {
                        if b - lastWhammyMove <= config.whammyBuffer {
                            addSP(beats / 32)
                        }
                    }
                    s.lastTime = end
                }
                if b < s.end { kept.append(s) }
            }
            sustains = kept
        }
        if spActive {
            // A full meter lasts 8 measures (half lasts 4), whatever the time
            // signature: 32 beats in 4/4, 28 in 7/4, 24 in 6/8.
            let perMeasure = tempo.beatsPerMeasure(atTick: Int(tempo.tick(at: a)))
            spMeter -= tempo.beats(from: a, to: b) / max(0.5, perMeasure) / 8
            if spMeter <= 0 {
                spMeter = 0
                spActive = false
                events.append(.spEnded)
            }
        }
    }

    private func addSP(_ v: Double) {
        let wasReady = spMeter >= 0.5
        spMeter = min(1, spMeter + v)
        if !wasReady && spMeter >= 0.5 && !spActive { events.append(.spReady) }
    }

    private func processMisses(at t: Double) {
        while next < track.chords.count {
            let c = track.chords[next]
            if c.time + half[next] >= t { break }
            if isDrums {
                var all: UInt32 = 0
                for g in c.gems.indices { all |= 1 << UInt32(g) }
                let missing = all & ~gemHit[next]
                if missing != 0 {
                    gemMissed[next] |= missing
                    let fillSkip = c.activation && fillActive
                    if !fillSkip {
                        breakCombo()
                        breakPhrase(c.spPhrase)
                        events.append(.miss(chord: next))
                    }
                }
                chordState[next] = gemHit[next] == all ? .hit : .missed
                phraseEndCheck(next)
            } else if chordState[next] == .pending {
                chordState[next] = .missed
                breakCombo()
                breakPhrase(c.spPhrase)
                events.append(.miss(chord: next))
                phraseEndCheck(next)
            }
            soloCheck(after: next)
            next += 1
        }
    }

    // MARK: Input

    public func handle(_ input: PlayInput, at t: Double) {
        advance(to: t)
        switch input {
        case .fret(let lane, let down):
            let old = frets
            if down { frets |= 1 << UInt32(lane) } else { frets &= ~(1 << UInt32(lane)) }
            if frets != old {
                lastFretChange = t
                if down, let i = firstPending(inWindowAt: t + front) ?? (next < track.chords.count ? next : nil),
                   track.chords[i].mask & (1 << UInt32(lane)) == 0, !isAnchor(lane: lane, for: track.chords[i]) {
                    ghostPresses += 1
                    if modifiers.deadlyGhosting && ghostPresses > 2 && !ghostPenalised {
                        ghostPenalised = true
                        breakCombo()
                        events.append(.overstrum)
                    }
                }
                dropBrokenSustains()
                if let p = pendingStrum, t - p <= config.strumLeniency, strumHit(at: t) {
                    pendingStrum = nil
                } else {
                    tryFretHit(at: t, onlyFreshFrets: false)
                }
            }
        case .strum:
            if t < strumIgnoreUntil { strumIgnoreUntil = -.infinity; return }
            if pendingStrum != nil { pendingStrum = nil; overstrum() }
            if !strumHit(at: t) {
                if firstPending(inWindowAt: t) != nil { pendingStrum = t } else { overstrum() }
            }
        case .whammy(let v):
            if abs(v - whammy) > 0.02 { lastWhammyMove = t }
            whammy = v
        case .starPower:
            activateSP()
        case .drum(let lane, let cymbal, let velocity):
            drumHit(lane: lane, cymbal: cymbal, velocity: velocity, at: t)
        }
    }

    public func activateSP() {
        guard !spActive, spMeter >= 0.5 else { return }
        spActive = true
        events.append(.spActivated)
    }

    private var fillActive: Bool { !spActive && spMeter >= 0.5 }
    /// Drums: whether activation notes are currently shown.
    public var showFills: Bool { fillActive }

    private func firstPending(inWindowAt t: Double) -> Int? {
        var i = next
        while i < track.chords.count {
            let c = track.chords[i]
            if c.time - front > t { return nil }
            if chordState[i] == .pending && c.time + half[i] >= t && c.time - half[i] <= t { return i }
            i += 1
        }
        return nil
    }

    /// Holding a lower fret under a single note is anchoring, not ghosting.
    private func isAnchor(lane: Int, for c: Chord) -> Bool {
        guard !sixFret, c.gems.count == 1, c.gems[0].lane != openLane else { return false }
        return lane < c.gems[0].lane
    }

    private func matches(_ c: Chord) -> Bool {
        let playable: UInt32 = sixFret ? 0x3F : 0x1F
        let held = frets & playable
        let m = c.mask
        if m == 1 << UInt32(openLane) { return held == 0 }
        if sixFret || c.gems.count > 1 { return held == m }
        // Single note: that fret held, nothing above it (anchoring allowed;
        // Drunk Mode allows anchoring in both directions).
        let lane = UInt32(c.gems[0].lane)
        if modifiers.drunk { return held & (1 << lane) != 0 }
        return held & (1 << lane) != 0 && held >> (lane + 1) == 0
    }

    private func strumHit(at t: Double) -> Bool {
        var i = next
        while i < track.chords.count {
            let c = track.chords[i]
            if c.time - front > t { break }
            if modifiers.strumlessHopos && c.kind != .strum && chordState[i] == .pending && abs(c.time - t) <= half[i] { return false }
            if chordState[i] == .pending && c.time + half[i] >= t && c.time - half[i] <= t && matches(c) {
                // Skipping ahead misses anything earlier still pending.
                for j in next..<i where chordState[j] == .pending {
                    chordState[j] = .missed
                    breakCombo()
                    breakPhrase(track.chords[j].spPhrase)
                    events.append(.miss(chord: j))
                    phraseEndCheck(j)
                }
                hitChord(i, at: t)
                return true
            }
            i += 1
        }
        return false
    }

    private func canHopo(_ i: Int) -> Bool {
        let c = track.chords[i]
        if c.kind == .tap || modifiers.autoStrum { return true }
        if c.kind != .hopo { return false }
        return i == 0 || chordState[i - 1] == .hit && combo > 0
    }

    /// Hammer-ons, pull-offs and taps: hit by fretting alone.
    private func tryFretHit(at t: Double, onlyFreshFrets: Bool) {
        guard let i = firstPending(inWindowAt: t), canHopo(i) else { return }
        if modifiers.noGhosting && ghostPresses > 1 && track.chords[i].kind != .tap { return }
        // Auto Strum: notes that need no fret change (repeats, opens) are
        // strummed for you right on time.
        if modifiers.autoStrum && t >= track.chords[i].time && matches(track.chords[i]) {
            hitChord(i, at: t)
            lastFretHitTime = t
            return
        }
        if onlyFreshFrets && lastFretChange <= lastFretHitTime { return }
        if onlyFreshFrets && i > 0 && lastFretChange < track.chords[i - 1].time - front { return }
        if matches(track.chords[i]) {
            hitChord(i, at: t)
            lastFretHitTime = t
            strumIgnoreUntil = t + hopoLeniency
        }
    }

    private func hitChord(_ i: Int, at t: Double) {
        let c = track.chords[i]
        chordState[i] = .hit
        combo += 1
        bestCombo = max(bestCombo, combo)
        notesHit += 1
        ghostPresses = 0
        ghostPenalised = false
        sectionHit[sectionIndex[i]] += 1
        scoreValue += Double(50 * c.gems.count * multiplier)
        if c.solo >= 0 {
            if currentSolo != c.solo { currentSolo = c.solo; events.append(.soloStart(c.solo)) }
            soloHits[c.solo] += 1
        }
        for g in c.gems where g.lane < lastHitTime.count { lastHitTime[g.lane] = t }
        events.append(.hit(chord: i, lanes: c.mask))
        if combo % 50 == 0 { events.append(.streak(combo)) }
        // Hitting a new note ends sustains on frets it doesn't use.
        sustains.removeAll { s in !c.gems.contains { $0.lane == s.lane } && s.lane != openLane }
        for g in c.gems where g.endTime > c.time {
            sustains.append(Sustain(chord: i, lane: g.lane, end: g.endTime, lastTime: max(t, c.time), sp: c.spPhrase >= 0))
        }
        phraseEndCheck(i)
        if i == next { next += 1; soloCheck(after: i) }
    }

    private func dropBrokenSustains() {
        guard !sustains.isEmpty else { return }
        let before = sustains.count
        sustains.removeAll { s in
            if s.end - now <= config.sustainDropLeniency { return false }
            if s.lane == openLane { return frets & (sixFret ? 0x3F : 0x1F) != 0 }
            return frets & (1 << UInt32(s.lane)) == 0
        }
        if modifiers.droplessSustains && sustains.count < before { breakCombo(); events.append(.miss(chord: -1)) }
    }

    private func overstrum() {
        overstrums += 1
        breakCombo()
        events.append(.overstrum)
    }

    private func breakCombo() {
        combo = 0
    }

    private func breakPhrase(_ p: Int) {
        guard p >= 0, !brokenPhrases.contains(p), !completedPhrases.contains(p) else { return }
        brokenPhrases.insert(p)
        events.append(.spPhraseBroken)
    }

    private func phraseEndCheck(_ i: Int) {
        let c = track.chords[i]
        guard c.spPhraseEnd, c.spPhrase >= 0, chordState[i] != .pending else { return }
        if isDrums {
            var all: UInt32 = 0
            for g in c.gems.indices { all |= 1 << UInt32(g) }
            if gemHit[i] != all { return }
        }
        if chordState[i] == .hit && !brokenPhrases.contains(c.spPhrase) && completedPhrases.insert(c.spPhrase).inserted {
            spPhrasesHit += 1
            addSP(0.25)
            events.append(.spPhraseComplete)
        }
    }

    private func soloCheck(after i: Int) {
        guard currentSolo >= 0 || track.chords[i].solo >= 0 else { return }
        let s = track.chords[i].solo
        let nextSolo = i + 1 < track.chords.count ? track.chords[i + 1].solo : -1
        if s >= 0 && nextSolo != s {
            let hit = soloHits[s], total = soloTotals[s]
            let bonus = hit * 100
            scoreValue += Double(bonus)
            events.append(.soloEnd(hit: hit, total: total, bonus: bonus))
            currentSolo = -1
        } else if s >= 0 && currentSolo != s {
            currentSolo = s
            events.append(.soloStart(s))
        }
    }

    // MARK: Drums

    private func drumHit(lane: Int, cymbal: Bool, velocity: Int?, at t: Double) {
        if lane < lastHitTime.count { lastHitTime[lane] = t }
        var i = next
        var best: (Int, Int)? = nil
        while i < track.chords.count {
            let c = track.chords[i]
            if c.time - front > t { break }
            if c.time + half[i] >= t && c.time - half[i] <= t {
                for (gi, g) in c.gems.enumerated() where g.lane == lane && gemHit[i] & (1 << UInt32(gi)) == 0 {
                    if enforceCymbals && lane != Lane.kick && lane != Lane.drumRed && g.cymbal != cymbal { continue }
                    best = (i, gi)
                    break
                }
                if best != nil { break }
            }
            i += 1
        }
        guard let (ci, gi) = best else {
            if config.drumOverhitBreaksCombo { overstrum() }
            return
        }
        let c = track.chords[ci]
        gemHit[ci] |= 1 << UInt32(gi)
        combo += 1
        bestCombo = max(bestCombo, combo)
        notesHit += 1
        sectionHit[sectionIndex[ci]] += 1
        scoreValue += Double(50 * multiplier)
        if c.solo >= 0 {
            if currentSolo != c.solo { currentSolo = c.solo; events.append(.soloStart(c.solo)) }
            soloHits[c.solo] += 1
        }
        events.append(.hit(chord: ci, lanes: 1 << UInt32(lane)))
        if combo % 50 == 0 { events.append(.streak(combo)) }
        // Deadly Dynamics: accents must be hit hard, ghosts soft.
        if modifiers.deadlyDynamics, let v = velocity {
            let g = c.gems[gi]
            if (g.accent && v < 100) || (g.ghost && v > 50) { breakCombo(); events.append(.overstrum) }
        }
        if c.activation && fillActive { activateSP() }
        var all: UInt32 = 0
        for g in c.gems.indices { all |= 1 << UInt32(g) }
        if gemHit[ci] == all {
            chordState[ci] = .hit
            phraseEndCheck(ci)
            if ci == next { next += 1; soloCheck(after: ci) }
        }
    }

    // MARK: Results

    /// Base score (no multipliers) used for star thresholds.
    public var baseScore: Double {
        var s = 0.0
        for c in track.chords {
            s += Double(50 * c.gems.count)
            for g in c.gems where g.endTime > c.time { s += 25 * tempo.beats(from: c.time, to: g.endTime) }
        }
        return max(1, s)
    }

    public static func starThresholds(_ i: Instrument) -> [Double] {
        switch i {
        case .bass, .bassGHL: return [0.21, 0.50, 0.90, 2.77, 4.62, 6.78]
        case .drums: return [0.29, 0.58, 0.87, 1.74, 2.90, 4.29]
        default: return [0.21, 0.46, 0.77, 1.85, 3.08, 4.52]
        }
    }

    /// 0-5 stars, 6 = gold.
    public func stars(base: Double) -> Int {
        let ratio = scoreValue / base
        var n = 0
        for th in PlayEngine.starThresholds(track.instrument) where ratio >= th { n += 1 }
        return n
    }

    public func stats(base: Double) -> PlayStats {
        var s = PlayStats()
        s.score = score
        s.notesHit = notesHit
        s.notesTotal = notesTotal
        s.bestStreak = bestCombo
        s.overstrums = overstrums
        s.spPhrasesHit = spPhrasesHit
        s.spPhrasesTotal = track.starPower.count
        s.stars = stars(base: base)
        s.sections = sectionNames.indices.compactMap { i in
            sectionTotal[i] > 0 ? SectionStat(name: sectionNames[i], hit: sectionHit[i], total: sectionTotal[i], index: hasSections ? i : -1) : nil
        }
        return s
    }
}
