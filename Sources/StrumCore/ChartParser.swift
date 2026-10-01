import Foundation

public enum ChartError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String {
        switch self { case .invalid(let s): return s }
    }
}

/// Parser for Moonscraper/FeedBack `.chart` files.
enum DotChartParser {
    private static let difficulties: [(String, Difficulty)] = [("Expert", .expert), ("Hard", .hard), ("Medium", .medium), ("Easy", .easy)]
    private static let instruments: [(String, Instrument)] = [
        ("Single", .guitar), ("DoubleGuitar", .guitarCoop), ("DoubleBass", .bass), ("DoubleRhythm", .rhythm),
        ("Keyboard", .keys), ("Drums", .drums), ("GHLGuitar", .guitarGHL), ("GHLBass", .bassGHL),
        ("GHLRhythm", .rhythmGHL), ("GHLCoop", .coopGHL),
    ]

    struct Line { var tick: Int; var type: Substring; var values: [Substring]; var rest: Substring }

    static func parse(_ data: Data, ini: IniFile) throws -> SongChart {
        let text = TextDecoding.decode(data)
        var sections: [String: [Substring]] = [:]
        var current: String? = nil
        var body: [Substring] = []
        var inBody = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if !inBody, line.hasPrefix("[") {
                current = String(line.dropFirst().prefix { $0 != "]" })
                continue
            }
            if line == "{" { inBody = true; body = []; continue }
            if line == "}" {
                if let c = current, sections[c] == nil { sections[c] = body }
                inBody = false
                current = nil
                continue
            }
            if inBody { body.append(Substring(line)) }
        }
        guard let songLines = sections["Song"] else { throw ChartError.invalid("No [Song] section") }

        var song: [String: String] = [:]
        for l in songLines {
            guard let eq = l.firstIndex(of: "=") else { continue }
            let k = l[..<eq].trimmingCharacters(in: .whitespaces)
            var v = l[l.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            song[k] = v
        }
        let resolution = Int(song["Resolution"] ?? "") ?? 192
        // song.ini `delay` (ms, later notes) and .chart `Offset` (s, audio sooner) both push notes later.
        let offset = (Double(song["Offset"] ?? "") ?? 0) + Double(ini.int("delay") ?? 0) / 1000

        var tempos: [(Int, Double)] = []
        var sigs: [(Int, Int, Int)] = []
        for l in (sections["SyncTrack"] ?? []).compactMap(parseLine) {
            switch l.type {
            case "B":
                if let v = l.values.first.flatMap({ Double($0) }), v > 0 { tempos.append((l.tick, 60_000_000_000 / v)) }
            case "TS":
                let n = l.values.first.flatMap { Int($0) } ?? 4
                let e = l.values.count > 1 ? (Int(l.values[1]) ?? 2) : 2
                sigs.append((l.tick, n, 1 << max(0, min(e, 6))))
            default: break
            }
        }
        let tempo = TempoMap(resolution: resolution, tempos: tempos, timeSigs: sigs, offset: offset)

        var chartSections: [ChartSection] = []
        var lyrics: [Lyric] = []
        var endTime: Double? = nil
        for l in (sections["Events"] ?? []).compactMap(parseLine) where l.type == "E" {
            var text = l.rest.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("\"") { text.removeFirst() }
            if text.hasSuffix("\"") { text.removeLast() }
            if text.hasPrefix("[") && text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
            if let name = sectionName(text) {
                chartSections.append(ChartSection(name: name, tick: l.tick, time: tempo.time(at: l.tick)))
            } else if text.hasPrefix("lyric ") {
                lyrics.append(Lyric(time: tempo.time(at: l.tick), text: String(text.dropFirst(6))))
            } else if text == "end" {
                endTime = tempo.time(at: l.tick)
            }
        }

        let opts = BuildOptions(format: .chart, resolution: resolution, ini: ini)
        var tracks: [TrackKey: TrackChart] = [:]
        for (dName, diff) in difficulties {
            for (iName, inst) in instruments {
                guard let lines = sections[dName + iName] else { continue }
                let raw = rawTrack(lines.compactMap(parseLine), instrument: inst)
                if raw.isEmpty { continue }
                tracks[TrackKey(inst, diff)] = ChartBuilder.build(instrument: inst, difficulty: diff, raw: raw, tempo: tempo, opts: opts)
            }
        }
        return SongChart(resolution: resolution, tempo: tempo, sections: chartSections, tracks: tracks, lyrics: lyrics, endEventTime: endTime)
    }

    static func sectionName(_ text: String) -> String? {
        for p in ["section ", "section_", "prc_"] where text.hasPrefix(p) {
            return String(text.dropFirst(p.count)).replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func parseLine(_ l: Substring) -> Line? {
        guard let eq = l.firstIndex(of: "=") else { return nil }
        guard let tick = Int(l[..<eq].trimmingCharacters(in: .whitespaces)) else { return nil }
        let rhs = l[l.index(after: eq)...].drop { $0 == " " || $0 == "\t" }
        let typeEnd = rhs.firstIndex { $0 == " " || $0 == "\t" } ?? rhs.endIndex
        let type = rhs[..<typeEnd]
        let rest = rhs[typeEnd...].drop { $0 == " " || $0 == "\t" }
        let values = rest.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return Line(tick: tick, type: type, values: values, rest: rest)
    }

    static func rawTrack(_ lines: [Line], instrument: Instrument) -> RawTrack {
        let raw = RawTrack()
        var soloStart: Int? = nil
        for l in lines {
            switch l.type {
            case "N":
                guard let n = l.values.first.flatMap({ Int($0) }) else { continue }
                let len = l.values.count > 1 ? max(0, Int(l.values[1]) ?? 0) : 0
                switch instrument.kind {
                case .fiveFret:
                    switch n {
                    case 0...4: raw.gems.append(RawGem(tick: l.tick, length: len, lane: n))
                    case 7: raw.gems.append(RawGem(tick: l.tick, length: len, lane: Lane.open5))
                    case 5: raw.flipTicks.insert(l.tick)
                    case 6: raw.tapTicks.insert(l.tick)
                    default: break
                    }
                case .sixFret:
                    let lanes: [Int: Int] = [0: Lane.white1, 1: Lane.white2, 2: Lane.white3, 3: Lane.black1, 4: Lane.black2, 8: Lane.black3, 7: Lane.open6]
                    if let lane = lanes[n] { raw.gems.append(RawGem(tick: l.tick, length: len, lane: lane)) }
                    else if n == 5 { raw.flipTicks.insert(l.tick) }
                    else if n == 6 { raw.tapTicks.insert(l.tick) }
                case .drums:
                    switch n {
                    case 0...5: raw.gems.append(RawGem(tick: l.tick, length: len, lane: n))
                    case 32: raw.gems.append(RawGem(tick: l.tick, length: 0, lane: Lane.kick, doubleKick: true))
                    case 34...38: raw.accentMarks.insert(l.tick * 8 + (n - 33))
                    case 40...44: raw.ghostMarks.insert(l.tick * 8 + (n - 39))
                    case 66...68: raw.cymbalMarks.insert(l.tick * 8 + (n - 64))
                    default: break
                    }
                }
            case "S":
                guard let t = l.values.first.flatMap({ Int($0) }) else { continue }
                let len = l.values.count > 1 ? max(0, Int(l.values[1]) ?? 0) : 0
                if t == 2 { raw.starPower.append(TickRange(start: l.tick, end: l.tick + len, inclusive: false)) }
                if t == 64 { raw.fills.append(TickRange(start: l.tick, end: l.tick + len, inclusive: true)) }
            case "E":
                let text = l.rest.trimmingCharacters(in: CharacterSet(charactersIn: " \"[]"))
                if text == "solo" { soloStart = l.tick }
                else if text == "soloend", let s = soloStart {
                    raw.solos.append(TickRange(start: s, end: l.tick, inclusive: true))
                    soloStart = nil
                }
            default: break
            }
        }
        if let s = soloStart { raw.solos.append(TickRange(start: s, end: Int.max / 2, inclusive: true)) }
        return raw
    }
}
