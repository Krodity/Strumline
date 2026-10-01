import Foundation

/// Turns a parsed track into the one that is played: modifiers (note type,
/// Mirror, Shuffle, Double Notes, drum filters) and drum-kit conversion.
public enum TrackPrep {
    /// Applies modifiers and drum-kit conversion. Returns the playable track.
    public static func prepare(_ src: TrackChart, modifiers: Modifiers, drumMode: DrumPlayMode) -> TrackChart {
        var t = src
        switch t.instrument.kind {
        case .fiveFret, .sixFret:
            let six = t.instrument.kind == .sixFret
            let open = six ? Lane.open6 : Lane.open5
            let lanes = six ? 6 : 5
            var rng = SplitMix(state: 0x5354_524D + UInt64(t.chords.count))
            for i in t.chords.indices {
                var c = t.chords[i]
                switch modifiers.notes {
                case .none: break
                case .allStrums: c.kind = .strum
                case .allHopos: c.kind = .hopo
                case .allTaps: c.kind = .tap
                case .allOpens:
                    let end = c.gems.map(\.endTick).max() ?? c.tick
                    let endT = c.gems.map(\.endTime).max() ?? c.time
                    c.gems = [Gem(lane: open, endTick: end, endTime: endT)]
                    c.kind = .strum
                }
                if modifiers.hoposToTaps && c.kind == .hopo { c.kind = .tap }
                let isOpen = c.gems.count == 1 && c.gems[0].lane == open
                if modifiers.shuffle && !isOpen {
                    var pool = Array(0..<lanes)
                    var used = Set<Int>()
                    for g in c.gems.indices {
                        var l: Int
                        repeat { l = pool.remove(at: rng.int(pool.count)) } while used.contains(l) && !pool.isEmpty
                        used.insert(l)
                        c.gems[g].lane = l
                    }
                }
                if modifiers.doubleNotes && !isOpen && c.gems.count < 3 {
                    // Add the nearest free lane above (or below) the highest note.
                    let taken = Set(c.gems.map(\.lane))
                    let top = c.gems.map(\.lane).max() ?? 0
                    let cand = ((top + 1)..<lanes).first { !taken.contains($0) } ?? (0..<top).reversed().first { !taken.contains($0) }
                    if let l = cand, var g = c.gems.first { g.lane = l; c.gems.append(g) }
                }
                if modifiers.mirror {
                    for g in c.gems.indices where c.gems[g].lane != open {
                        let l = c.gems[g].lane
                        c.gems[g].lane = six ? (l / 3) * 3 + (2 - l % 3) : 4 - l
                    }
                }
                c.gems.sort { $0.lane < $1.lane }
                t.chords[i] = c
            }
        case .drums:
            for i in t.chords.indices {
                var gems = t.chords[i].gems
                if !modifiers.twoXKick { gems.removeAll { $0.doubleKick } }
                gems = convertDrums(gems, from: t.drumType, to: drumMode)
                if modifiers.noKick { gems.removeAll { $0.lane == Lane.kick } }
                if modifiers.onlyKicks, var k = gems.first { k.lane = Lane.kick; k.cymbal = false; gems = [k] }
                if modifiers.shuffle {
                    var rng = SplitMix(state: UInt64(t.chords[i].tick) &* 31 &+ 7)
                    var pool = Array(1...drumMode.laneCount)
                    for g in gems.indices where gems[g].lane != Lane.kick && !pool.isEmpty {
                        gems[g].lane = pool.remove(at: rng.int(pool.count))
                    }
                }
                if modifiers.mirror {
                    let n = drumMode.laneCount
                    for g in gems.indices where gems[g].lane != Lane.kick { gems[g].lane = n + 1 - gems[g].lane }
                }
                t.chords[i].gems = gems
            }
            t.chords.removeAll { $0.gems.isEmpty }
            // Phrase markers may have pointed at removed chords.
            fixPhraseEnds(&t)
        }
        return t
    }

    /// After chords are removed (drum modifiers, a practice cut), make each
    /// star power phrase end on a chord that still exists.
    public static func fixPhraseEnds(_ t: inout TrackChart) {
        var lastOf: [Int: Int] = [:]
        for i in t.chords.indices {
            t.chords[i].spPhraseEnd = false
            if t.chords[i].spPhrase >= 0 { lastOf[t.chords[i].spPhrase] = i }
        }
        for (_, i) in lastOf { t.chords[i].spPhraseEnd = true }
    }

    static func convertDrums(_ gems: [Gem], from: DrumType, to: DrumPlayMode) -> [Gem] {
        func dedupe(_ g: [Gem]) -> [Gem] {
            var seen = Set<Int>()
            return g.filter { seen.insert($0.lane).inserted }
        }
        switch (from, to) {
        case (.fourLane, .fourLane), (.fourLanePro, .fourLanePro), (.fourLane, .fourLanePro), (.fiveLane, .fiveLane):
            return gems
        case (.fourLanePro, .fourLane):
            return gems.map { var g = $0; g.cymbal = false; return g }
        case (.fiveLane, .fourLane), (.fiveLane, .fourLanePro):
            let hasO = gems.contains { $0.lane == Lane.drum4 }, hasG = gems.contains { $0.lane == Lane.drum5 }
            var out: [Gem] = []
            for var g in gems {
                switch g.lane {
                case Lane.drumYellow: g.cymbal = true
                case Lane.drumBlue: g.cymbal = false
                case Lane.drum4: g.lane = Lane.drum4; g.cymbal = true
                case Lane.drum5:
                    if hasO && hasG { g.lane = Lane.drumBlue; g.cymbal = false } else { g.lane = Lane.drum4; g.cymbal = false }
                default: break
                }
                if to == .fourLane { g.cymbal = false }
                out.append(g)
            }
            return dedupe(out)
        case (.fourLanePro, .fiveLane), (.fourLane, .fiveLane):
            let pro = from == .fourLanePro
            let yTom = gems.contains { $0.lane == Lane.drumYellow && !$0.cymbal }
            let bTom = gems.contains { $0.lane == Lane.drumBlue && !$0.cymbal }
            let bCym = gems.contains { $0.lane == Lane.drumBlue && $0.cymbal }
            let gCym = gems.contains { $0.lane == Lane.drum4 && $0.cymbal }
            var out: [Gem] = []
            for var g in gems {
                if !pro {
                    // Plain 4-lane: keep lanes, green goes to 5-lane green.
                    if g.lane == Lane.drum4 { g.lane = Lane.drum5 }
                    out.append(g); continue
                }
                switch (g.lane, g.cymbal) {
                case (Lane.drumYellow, true): g.lane = Lane.drumYellow
                case (Lane.drumYellow, false): g.lane = (yTom && bTom) ? Lane.drumRed : Lane.drumBlue
                case (Lane.drumBlue, true): g.lane = (bCym && gCym) ? Lane.drumYellow : Lane.drum4
                case (Lane.drumBlue, false): g.lane = Lane.drumBlue
                case (Lane.drum4, true): g.lane = Lane.drum4
                case (Lane.drum4, false): g.lane = Lane.drum5
                default: break
                }
                out.append(g)
            }
            return dedupe(out)
        }
    }
}
