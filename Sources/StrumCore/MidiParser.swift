import Foundation

/// Standard MIDI File reader, tolerant of the quirks found in chart files.
struct MidiFile {
    enum Event {
        case noteOn(note: Int, velocity: Int, channel: Int)
        case noteOff(note: Int, channel: Int)
        case text(type: UInt8, text: String)
        case tempo(usPerQuarter: Int)
        case timeSig(numerator: Int, denominatorExp: Int)
        case sysex([UInt8])
    }
    struct TimedEvent { var tick: Int; var event: Event }
    struct Track { var name: String; var events: [TimedEvent] }

    var resolution: Int
    var tracks: [Track]

    init(data: Data) throws {
        let b = [UInt8](data)
        var p = 0
        func u32() throws -> Int {
            guard p + 4 <= b.count else { throw ChartError.invalid("Truncated MIDI") }
            defer { p += 4 }
            return Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3])
        }
        func u16(_ at: Int) -> Int { Int(b[at]) << 8 | Int(b[at + 1]) }
        guard b.count >= 14, b[0] == 0x4D, b[1] == 0x54, b[2] == 0x68, b[3] == 0x64 else { throw ChartError.invalid("Not a MIDI file") }
        p = 4
        let hlen = try u32()
        guard p + hlen <= b.count, hlen >= 6 else { throw ChartError.invalid("Bad MIDI header") }
        let division = u16(p + 4)
        guard division & 0x8000 == 0 else { throw ChartError.invalid("SMPTE MIDI timing is not supported") }
        resolution = max(1, division)
        p += hlen

        var tracks: [Track] = []
        while p + 8 <= b.count {
            let isTrack = b[p] == 0x4D && b[p + 1] == 0x54 && b[p + 2] == 0x72 && b[p + 3] == 0x6B
            p += 4
            let len = try u32()
            let end = min(b.count, p + len)
            if isTrack { tracks.append(MidiFile.readTrack(b, from: p, to: end)) }
            p = end
        }
        self.tracks = tracks
    }

    private static func readTrack(_ b: [UInt8], from start: Int, to end: Int) -> Track {
        var p = start
        var tick = 0
        var running: UInt8 = 0
        var events: [TimedEvent] = []
        var name = ""
        var first = true
        func vlq() -> Int {
            var v = 0
            for _ in 0..<4 {
                guard p < end else { return v }
                let c = b[p]; p += 1
                v = (v << 7) | Int(c & 0x7F)
                if c & 0x80 == 0 { break }
            }
            return v
        }
        while p < end {
            tick += vlq()
            guard p < end else { break }
            var status = b[p]
            if status < 0x80 {
                // Running status; some charts keep it across meta/SysEx events.
                guard running != 0 else { p += 1; continue }
                status = running
            } else {
                p += 1
            }
            switch status {
            case 0xFF:
                guard p < end else { break }
                let type = b[p]; p += 1
                let len = vlq()
                let dEnd = min(end, p + len)
                let data = Array(b[p..<dEnd])
                p = dEnd
                switch type {
                case 0x01...0x0F:
                    let s = String(decoding: data, as: UTF8.self)
                    if type == 0x03 && first && name.isEmpty { name = s }
                    else { events.append(TimedEvent(tick: tick, event: .text(type: type, text: s))) }
                case 0x51 where data.count >= 3:
                    events.append(TimedEvent(tick: tick, event: .tempo(usPerQuarter: Int(data[0]) << 16 | Int(data[1]) << 8 | Int(data[2]))))
                case 0x58 where data.count >= 2:
                    events.append(TimedEvent(tick: tick, event: .timeSig(numerator: Int(data[0]), denominatorExp: Int(data[1]))))
                case 0x2F:
                    p = end
                default: break
                }
            case 0xF0, 0xF7:
                let len = vlq()
                let dEnd = min(end, p + len)
                events.append(TimedEvent(tick: tick, event: .sysex(Array(b[p..<dEnd]))))
                p = dEnd
            default:
                running = status
                let kind = status & 0xF0
                let ch = Int(status & 0x0F)
                let dataLen = (kind == 0xC0 || kind == 0xD0) ? 1 : 2
                guard p + dataLen <= end else { p = end; break }
                if kind == 0x90 {
                    let n = Int(b[p]), v = Int(b[p + 1])
                    events.append(TimedEvent(tick: tick, event: v == 0 ? .noteOff(note: n, channel: ch) : .noteOn(note: n, velocity: v, channel: ch)))
                } else if kind == 0x80 {
                    events.append(TimedEvent(tick: tick, event: .noteOff(note: Int(b[p]), channel: ch)))
                }
                p += dataLen
            }
            first = false
        }
        return Track(name: name, events: events)
    }
}

enum MidiChartParser {
    private static let fretTracks: [String: Instrument] = [
        "PART GUITAR": .guitar, "T1 GEMS": .guitar, "PART GUITAR COOP": .guitarCoop, "PART BASS": .bass,
        "PART RHYTHM": .rhythm, "PART KEYS": .keys, "PART DRUMS": .drums, "PART DRUM": .drums,
        "PART GUITAR GHL": .guitarGHL, "PART BASS GHL": .bassGHL, "PART RHYTHM GHL": .rhythmGHL,
        "PART GUITAR COOP GHL": .coopGHL,
    ]

    struct NoteSpan { var start: Int; var end: Int; var velocity: Int }

    static func parse(_ data: Data, ini: IniFile) throws -> SongChart {
        let midi = try MidiFile(data: data)
        guard let first = midi.tracks.first else { throw ChartError.invalid("MIDI has no tracks") }
        var tempos: [(Int, Double)] = []
        var sigs: [(Int, Int, Int)] = []
        for e in first.events {
            switch e.event {
            case .tempo(let us): tempos.append((e.tick, Double(us)))
            case .timeSig(let n, let d): sigs.append((e.tick, n, 1 << min(d, 6)))
            default: break
            }
        }
        let tempo = TempoMap(resolution: midi.resolution, tempos: tempos, timeSigs: sigs, offset: Double(ini.int("delay") ?? 0) / 1000)
        let opts = BuildOptions(format: .mid, resolution: midi.resolution, ini: ini)

        var sections: [ChartSection] = []
        var lyrics: [Lyric] = []
        var endTime: Double? = nil
        var tracks: [TrackKey: TrackChart] = [:]
        var drums2x: MidiFile.Track? = nil

        for track in midi.tracks.dropFirst() {
            let name = track.name.trimmingCharacters(in: .whitespaces).uppercased()
            if name == "EVENTS" {
                for e in track.events {
                    guard case .text(_, var text) = e.event else { continue }
                    text = text.trimmingCharacters(in: .whitespaces)
                    if text.hasPrefix("[") && text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
                    if let s = DotChartParser.sectionName(text) {
                        sections.append(ChartSection(name: s, tick: e.tick, time: tempo.time(at: e.tick)))
                    } else if text == "end" {
                        endTime = tempo.time(at: e.tick)
                    }
                }
                continue
            }
            if name == "PART VOCALS" {
                for e in track.events {
                    if case .text(let type, let text) = e.event, type == 0x05 || (type == 0x01 && !text.hasPrefix("[")) {
                        lyrics.append(Lyric(time: tempo.time(at: e.tick), text: text))
                    }
                }
                continue
            }
            if name == "PART DRUMS_2X" { drums2x = track; continue }
            guard let inst = fretTracks[name] else { continue }
            if tracks[TrackKey(inst, .expert)] != nil || tracks[TrackKey(inst, .easy)] != nil { continue }
            for (diff, raw) in rawTracks(track, instrument: inst, ini: ini) where !raw.isEmpty {
                tracks[TrackKey(inst, diff)] = ChartBuilder.build(instrument: inst, difficulty: diff, raw: raw, tempo: tempo, opts: opts)
            }
        }
        if let t = drums2x, tracks.keys.allSatisfy({ $0.instrument != .drums }) {
            for (diff, raw) in rawTracks(t, instrument: .drums, ini: ini) where !raw.isEmpty {
                tracks[TrackKey(.drums, diff)] = ChartBuilder.build(instrument: .drums, difficulty: diff, raw: raw, tempo: tempo, opts: opts)
            }
        }
        return SongChart(resolution: midi.resolution, tempo: tempo, sections: sections.sorted { $0.tick < $1.tick }, tracks: tracks, lyrics: lyrics, endEventTime: endTime)
    }

    /// Pairs note-ons with note-offs.
    static func spans(_ track: MidiFile.Track) -> [Int: [NoteSpan]] {
        var open: [Int: (Int, Int)] = [:]  // note*16+ch -> (start, vel)
        var out: [Int: [NoteSpan]] = [:]
        for e in track.events {
            switch e.event {
            case .noteOn(let n, let v, let ch):
                let key = n * 16 + ch
                if let (s, sv) = open[key] { out[n, default: []].append(NoteSpan(start: s, end: e.tick, velocity: sv)) }
                open[key] = (e.tick, v)
            case .noteOff(let n, let ch):
                let key = n * 16 + ch
                if let (s, v) = open.removeValue(forKey: key) { out[n, default: []].append(NoteSpan(start: s, end: e.tick, velocity: v)) }
            default: break
            }
        }
        for (key, (s, v)) in open { out[key / 16, default: []].append(NoteSpan(start: s, end: s, velocity: v)) }
        return out
    }

    static func rawTracks(_ track: MidiFile.Track, instrument: Instrument, ini: IniFile) -> [(Difficulty, RawTrack)] {
        let spans = spans(track)
        var texts = Set<String>()
        for e in track.events {
            if case .text(_, let t) = e.event { texts.insert(t.trimmingCharacters(in: CharacterSet(charactersIn: " []"))) }
        }
        let enhancedOpens = texts.contains("ENHANCED_OPENS")
        let dynamics = texts.contains("ENABLE_CHART_DYNAMICS")

        // Phase Shift SysEx phrases: diff (0-3 or 0xFF) -> modifier -> ranges
        var sysex: [Int: [Int: [TickRange]]] = [:]
        var sysexOpen: [Int: Int] = [:]  // (diff*256+mod) -> start
        for e in track.events {
            guard case .sysex(let d) = e.event, d.count >= 7, d[0] == 0x50, d[1] == 0x53, d[2] == 0x00, d[3] == 0x00 else { continue }
            let diff = Int(d[4]), mod = Int(d[5]), on = d[6] == 1
            let key = diff * 256 + mod
            if on { sysexOpen[key] = e.tick }
            else if let s = sysexOpen.removeValue(forKey: key) {
                // Tap phrases include their end tick; open phrases don't.
                sysex[diff, default: [:]][mod, default: []].append(TickRange(start: s, end: e.tick, inclusive: mod == 4))
            }
        }
        func sysexRanges(_ diff: Int, _ mod: Int) -> [TickRange] {
            (sysex[diff]?[mod] ?? []) + (sysex[0xFF]?[mod] ?? [])
        }
        func ranges(_ note: Int, inclusive: Bool = false) -> [TickRange] {
            (spans[note] ?? []).map { TickRange(start: $0.start, end: $0.end, inclusive: inclusive) }
        }

        // Shared phrases.
        var spNote = 116
        if let m = ini.int("multiplier_note", "star_power_note"), m == 103 || m == 116 { spNote = m }
        else if instrument.kind == .fiveFret, spans[116] == nil, spans[103] != nil { spNote = 103 }
        let starPower = ranges(spNote)
        let solos = spNote == 103 ? [] : ranges(103)
        let taps = ranges(104)
        let fills = ranges(120, inclusive: true)

        var out: [(Difficulty, RawTrack)] = []
        for diff in Difficulty.allCases {
            let base = 60 + diff.rawValue * 12
            let raw = RawTrack()
            raw.starPower = starPower
            raw.solos = solos
            switch instrument.kind {
            case .fiveFret:
                for lane in 0...4 {
                    for s in spans[base + lane] ?? [] { raw.gems.append(RawGem(tick: s.start, length: s.end - s.start, lane: lane)) }
                }
                if enhancedOpens {
                    for s in spans[base - 1] ?? [] { raw.gems.append(RawGem(tick: s.start, length: s.end - s.start, lane: Lane.open5)) }
                }
                raw.forceHopo = ranges(base + 5)
                raw.forceStrum = ranges(base + 6)
                raw.taps = taps + sysexRanges(diff.rawValue, 4)
                raw.opens = sysexRanges(diff.rawValue, 1)
            case .sixFret:
                // base-1 = W1 … base+1 = W3, base+2 = B1 … base+4 = B3, base-2 = open
                let map: [(Int, Int)] = [(-2, Lane.open6), (-1, Lane.white1), (0, Lane.white2), (1, Lane.white3), (2, Lane.black1), (3, Lane.black2), (4, Lane.black3)]
                for (off, lane) in map {
                    for s in spans[base + off] ?? [] { raw.gems.append(RawGem(tick: s.start, length: s.end - s.start, lane: lane)) }
                }
                raw.forceHopo = ranges(base + 5)
                raw.forceStrum = ranges(base + 6)
                raw.taps = taps + sysexRanges(diff.rawValue, 4)
                raw.opens = sysexRanges(diff.rawValue, 1)
            case .drums:
                for lane in 0...5 {
                    for s in spans[base + lane] ?? [] {
                        var g = RawGem(tick: s.start, length: 0, lane: lane)
                        if dynamics && lane != Lane.kick {
                            g.accent = s.velocity == 127
                            g.ghost = s.velocity == 1
                        }
                        raw.gems.append(g)
                    }
                }
                if diff == .expert {
                    for s in spans[95] ?? [] { raw.gems.append(RawGem(tick: s.start, length: 0, lane: Lane.kick, doubleKick: true)) }
                }
                raw.toms = [Lane.drumYellow: ranges(110), Lane.drumBlue: ranges(111), Lane.drum4: ranges(112)]
                raw.fills = fills
            }
            out.append((diff, raw))
        }
        return out
    }
}
