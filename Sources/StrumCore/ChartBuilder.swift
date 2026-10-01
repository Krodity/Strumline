import Foundation

enum ChartFormat { case chart, mid }

struct TickRange {
    var start: Int
    var end: Int
    /// Most phrases exclude their end tick; a few (tap SysEx, .chart solos
    /// and fills) include it.
    var inclusive: Bool

    func contains(_ tick: Int) -> Bool {
        if start == end { return tick == start }
        return tick >= start && (inclusive ? tick <= end : tick < end)
    }
}

struct RawGem {
    var tick: Int
    var length: Int
    var lane: Int
    var doubleKick = false
    var accent = false
    var ghost = false
}

/// Format-independent parse result for one instrument difficulty.
final class RawTrack {
    var gems: [RawGem] = []
    // 5/6-fret forcing
    var flipTicks = Set<Int>()          // .chart N 5
    var tapTicks = Set<Int>()           // .chart N 6
    var forceHopo: [TickRange] = []     // .mid
    var forceStrum: [TickRange] = []    // .mid
    var taps: [TickRange] = []          // .mid note 104 / SysEx
    var opens: [TickRange] = []         // .mid SysEx
    // drums
    var cymbalMarks = Set<Int>()        // .chart: tick * 8 + lane
    var accentMarks = Set<Int>()        // .chart
    var ghostMarks = Set<Int>()         // .chart
    var toms: [Int: [TickRange]] = [:]  // .mid: lane -> tom marker ranges
    // phrases
    var starPower: [TickRange] = []
    var solos: [TickRange] = []
    var fills: [TickRange] = []

    var isEmpty: Bool { gems.isEmpty }
}

struct BuildOptions {
    var format: ChartFormat
    var resolution: Int
    var hopoThreshold: Int
    var sustainCutoff: Int
    var proDrums: Bool?
    var fiveLaneDrums: Bool?

    init(format: ChartFormat, resolution: Int, ini: IniFile) {
        self.format = format
        self.resolution = resolution
        switch format {
        case .chart: hopoThreshold = resolution * 65 / 192
        case .mid: hopoThreshold = resolution / 3 + 1
        }
        if let f = ini.int("hopo_frequency", "hopofreq"), f > 0 {
            // Old FoFiX-style hopofreq is a 0-5 enum rather than ticks.
            if ini["hopo_frequency"] == nil, f <= 5 {
                let steps = [24, 16, 12, 8, 6, 4]  // 1/24 … 1/4 notes
                hopoThreshold = resolution * 4 / steps[f]
            } else {
                hopoThreshold = f
            }
        } else if ini.bool("eighthnote_hopo") == true {
            hopoThreshold = resolution / 2 + (format == .mid ? 1 : 0)
        }
        if let c = ini.int("sustain_cutoff_threshold"), c >= 0 {
            sustainCutoff = c
        } else {
            sustainCutoff = format == .mid ? resolution / 3 : 0
        }
        proDrums = ini.bool("pro_drums")
        fiveLaneDrums = ini.bool("five_lane_drums")
    }
}

enum ChartBuilder {
    static func build(instrument: Instrument, difficulty: Difficulty, raw: RawTrack, tempo: TempoMap, opts: BuildOptions) -> TrackChart {
        var track = TrackChart(instrument: instrument, difficulty: difficulty)
        switch instrument.kind {
        case .fiveFret, .sixFret:
            track.chords = buildFretted(raw: raw, tempo: tempo, opts: opts, sixFret: instrument.kind == .sixFret)
        case .drums:
            let (chords, type) = buildDrums(raw: raw, tempo: tempo, opts: opts)
            track.chords = chords
            track.drumType = type
        }
        applyPhrases(&track, raw: raw, tempo: tempo)
        return track
    }

    private static func groupByTick(_ gems: [RawGem]) -> [[RawGem]] {
        let sorted = gems.sorted { $0.tick != $1.tick ? $0.tick < $1.tick : $0.lane < $1.lane }
        var groups: [[RawGem]] = []
        for g in sorted {
            if let last = groups.last?.first, last.tick == g.tick {
                if !groups[groups.count - 1].contains(where: { $0.lane == g.lane }) {
                    groups[groups.count - 1].append(g)
                } else if let i = groups[groups.count - 1].firstIndex(where: { $0.lane == g.lane }) {
                    groups[groups.count - 1][i].length = max(groups[groups.count - 1][i].length, g.length)
                }
            } else {
                groups.append([g])
            }
        }
        return groups
    }

    static func buildFretted(raw: RawTrack, tempo: TempoMap, opts: BuildOptions, sixFret: Bool) -> [Chord] {
        let openLane = sixFret ? Lane.open6 : Lane.open5
        var chords: [Chord] = []
        chords.reserveCapacity(raw.gems.count)
        var prevMask: UInt32 = 0
        var prevTick = Int.min / 2
        var prevWasChord = false

        for var group in groupByTick(raw.gems) {
            let tick = group[0].tick
            // .mid open-note SysEx turns everything in it into an open note.
            if raw.opens.contains(where: { $0.contains(tick) }) {
                let len = group.map(\.length).max() ?? 0
                group = [RawGem(tick: tick, length: len, lane: openLane)]
            }
            // An open note can't share a tick with frets.
            if group.count > 1, group.contains(where: { $0.lane == openLane }) {
                group.removeAll { $0.lane == openLane }
            }
            let gems = group.map { g -> Gem in
                var len = g.length
                if len < opts.sustainCutoff { len = 0 }
                let end = tick + max(0, len)
                return Gem(lane: g.lane, endTick: end, endTime: tempo.time(at: end))
            }
            var chord = Chord(tick: tick, time: tempo.time(at: tick), gems: gems)
            let mask = chord.mask

            // Natural HOPO: close to the previous note, a single note, a
            // different lane, and not one of the previous chord's notes.
            var hopo = false
            if !chords.isEmpty, gems.count == 1, tick - prevTick <= opts.hopoThreshold, mask != prevMask {
                hopo = !(prevWasChord && (prevMask & mask) != 0)
            }
            switch opts.format {
            case .chart:
                if raw.flipTicks.contains(tick) { hopo.toggle() }
            case .mid:
                if raw.forceHopo.contains(where: { $0.contains(tick) }) { hopo = true }
                else if raw.forceStrum.contains(where: { $0.contains(tick) }) { hopo = false }
            }
            chord.kind = hopo ? .hopo : .strum
            let tap = raw.tapTicks.contains(tick) || raw.taps.contains(where: { $0.contains(tick) })
            if tap { chord.kind = mask == 1 << UInt32(openLane) ? .hopo : .tap }

            prevMask = mask
            prevTick = tick
            prevWasChord = gems.count > 1
            chords.append(chord)
        }
        return chords
    }

    static func buildDrums(raw: RawTrack, tempo: TempoMap, opts: BuildOptions) -> ([Chord], DrumType) {
        let hasProMarks: Bool = opts.format == .chart ? !raw.cymbalMarks.isEmpty : raw.toms.values.contains { !$0.isEmpty }
        let hasFiveLane = raw.gems.contains { $0.lane == Lane.drum5 }
        var type: DrumType
        if opts.proDrums == true { type = .fourLanePro }
        else if opts.fiveLaneDrums == true { type = .fiveLane }
        else if hasProMarks { type = .fourLanePro }
        else if hasFiveLane { type = .fiveLane }
        else { type = .fourLane }
        // song.ini pro_drums on a .mid with no tom markers means "all cymbals".

        var chords: [Chord] = []
        for group in groupByTick(raw.gems) {
            let tick = group[0].tick
            let t = tempo.time(at: tick)
            var gems: [Gem] = []
            for g in group {
                var gem = Gem(lane: g.lane, endTick: tick, endTime: t)
                gem.doubleKick = g.doubleKick
                gem.accent = g.accent || raw.accentMarks.contains(tick * 8 + g.lane)
                gem.ghost = g.ghost || raw.ghostMarks.contains(tick * 8 + g.lane)
                if type == .fourLanePro, (Lane.drumYellow...Lane.drum4).contains(g.lane) {
                    switch opts.format {
                    case .chart: gem.cymbal = raw.cymbalMarks.contains(tick * 8 + g.lane)
                    case .mid: gem.cymbal = !(raw.toms[g.lane]?.contains { $0.contains(tick) } ?? false)
                    }
                }
                if type == .fiveLane, g.lane == Lane.drumYellow || g.lane == Lane.drum4 {
                    gem.cymbal = true
                }
                gems.append(gem)
            }
            chords.append(Chord(tick: tick, time: t, gems: gems))
        }
        return (chords, type)
    }

    static func applyPhrases(_ track: inout TrackChart, raw: RawTrack, tempo: TempoMap) {
        func phrases(_ ranges: [TickRange]) -> [(TickRange, Phrase)] {
            ranges.sorted { $0.start < $1.start }.map {
                ($0, Phrase(startTick: $0.start, endTick: $0.end, startTime: tempo.time(at: $0.start), endTime: tempo.time(at: $0.end)))
            }
        }
        // Star power: keep only phrases that contain notes.
        var sp: [Phrase] = []
        var ci = 0
        for (range, phrase) in phrases(raw.starPower) {
            while ci < track.chords.count && track.chords[ci].tick < range.start { ci += 1 }
            var j = ci
            var last = -1
            while j < track.chords.count && range.contains(track.chords[j].tick) {
                if track.chords[j].spPhrase < 0 {
                    track.chords[j].spPhrase = sp.count
                    last = j
                }
                j += 1
            }
            if last >= 0 {
                track.chords[last].spPhraseEnd = true
                sp.append(phrase)
            }
        }
        track.starPower = sp

        var solos: [Phrase] = []
        for (range, phrase) in phrases(raw.solos) {
            var any = false
            for i in track.chords.indices where range.contains(track.chords[i].tick) && track.chords[i].solo < 0 {
                track.chords[i].solo = solos.count
                any = true
            }
            if any { solos.append(phrase) }
        }
        track.solos = solos

        if track.instrument.kind == .drums {
            var fills: [Phrase] = []
            for (range, phrase) in phrases(raw.fills) {
                if let last = track.chords.lastIndex(where: { range.contains($0.tick) }) {
                    track.chords[last].activation = true
                    fills.append(phrase)
                }
            }
            track.fills = fills
        }
    }
}
