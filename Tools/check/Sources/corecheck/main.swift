import Foundation
import StrumCore

// Usage: corecheck <song folder | .sng | library root> ...
// Scans, parses every part, plays each one with a perfect bot, decodes
// every audio stem (plus a seek check), and diffs .chart against .mid when
// both versions of a song are present.

nonisolated(unsafe) var failures = 0
nonisolated func fail(_ s: String) { failures += 1; print("  ✗ " + s) }

let roots = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
var placeholders: [URL] = []
let result = LibraryScanner.scan(roots: roots, cache: [:], onPlaceholder: { placeholders.append($0) })
print("scanned \(result.songs.count) songs, \(result.errors.count) errors, \(placeholders.count) iCloud placeholders")
for e in result.errors { fail("scan: \(e)") }

func bot(_ track: TrackChart, _ chart: SongChart, mods: Modifiers = Modifiers()) -> PlayEngine {
    let mode: DrumPlayMode = .fourLanePro
    let t = TrackPrep.prepare(track, modifiers: mods, drumMode: mode)
    let eng = PlayEngine(track: t, tempo: chart.tempo, sections: chart.sections, config: EngineConfig(), drumMode: mode, modifiers: mods)
    var frets: UInt32 = 0
    var prevMask: UInt32 = 0xFFFF
    var prevTime = -10.0
    let open: UInt32 = t.instrument.kind == .sixFret ? 1 << 6 : 1 << 5
    for c in t.chords {
        if t.instrument.kind == .drums {
            for g in c.gems { eng.handle(.drum(lane: g.lane, cymbal: g.cymbal, velocity: nil), at: c.time) }
            continue
        }
        let want = c.mask == open ? 0 : c.mask
        let changeAt = max(prevTime + 0.001, c.time - 0.02)
        for lane in 0..<6 {
            let bit: UInt32 = 1 << UInt32(lane)
            if (frets & bit) != (want & bit) { eng.handle(.fret(lane: lane, down: want & bit != 0), at: changeAt) }
        }
        frets = want
        if mods.autoStrum {
            eng.advance(to: c.time + 0.008)  // a frame after the note
        } else if c.kind == .strum || c.mask == prevMask {
            eng.handle(.strum, at: c.time)
        }
        prevMask = c.mask
        prevTime = c.time
    }
    eng.advance(to: (t.chords.last?.sustainEndTime ?? 0) + 1)
    return eng
}

var charts: [String: SongChart] = [:]
for song in result.songs.sorted(by: { $0.path < $1.path }) {
    print("\n▶ \(song.name) — \(song.artist)  [\(song.kind.rawValue): \(song.chartFile)] hash \(song.chartHash)")
    print("  parts: " + song.instruments.map { "\($0.rawValue)(\(song.difficulties(for: $0).map { String($0.displayName.prefix(1)) }.joined()))" }.joined(separator: " "))
    print("  length \(song.lengthMs) ms, preview \(song.previewStartMs), drums \(song.drumType?.rawValue ?? "-"), art \(song.albumArt ?? "-")")
    do {
        let (chart, pkg, _) = try SongLoader.loadChart(entry: song)
        charts[song.path] = chart
        print("  sections: \(chart.sections.map(\.name).joined(separator: ", "))")
        for (key, track) in chart.tracks.sorted(by: { ($0.key.instrument.rawValue, $0.key.difficulty.rawValue) < ($1.key.instrument.rawValue, $1.key.difficulty.rawValue) }) {
            let eng = bot(track, chart)
            let kinds = Dictionary(grouping: track.chords, by: \.kind).mapValues(\.count)
            let line = "\(key.instrument.rawValue)/\(key.difficulty.displayName): \(track.noteCount) notes, strum \(kinds[.strum] ?? 0) hopo \(kinds[.hopo] ?? 0) tap \(kinds[.tap] ?? 0), sp \(track.starPower.count), solos \(track.solos.count), fills \(track.fills.count) → bot \(eng.notesHit)/\(eng.notesTotal) over \(eng.overstrums) score \(eng.score) stars \(eng.stars(base: eng.baseScore)) spHit \(eng.spPhrasesHit)"
            if eng.notesHit != eng.notesTotal || eng.overstrums != 0 { fail(line) } else { print("  ✓ " + line) }
        }
        // Modifier smoke test on expert guitar/drums.
        for inst in [Instrument.guitar, .drums] {
            guard let tr = chart.track(inst, .expert) else { continue }
            for (name, m) in [("allTaps", { var m = Modifiers(); m.notes = .allTaps; return m }()),
                              ("mirror+shuffle+double", { var m = Modifiers(); m.mirror = true; m.shuffle = true; m.doubleNotes = true; return m }()),
                              ("precision", { var m = Modifiers(); m.precision = true; return m }()),
                              ("autoStrum", { var m = Modifiers(); m.autoStrum = true; return m }()),
                              ("noKick", { var m = Modifiers(); m.noKick = true; return m }())] {
                let e = bot(tr, chart, mods: m)
                let l = "  mod \(inst.rawValue) \(name): \(e.notesHit)/\(e.notesTotal) over \(e.overstrums)"
                if e.notesHit != e.notesTotal || e.overstrums != 0 { fail(l) } else { print("  ✓" + l) }
            }
        }
        // Audio
        for (role, name) in SongLoader.stems(in: pkg).sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard let dec = AudioDecoders.open(pkg: pkg, name: name) else { fail("cannot decode \(name)"); continue }
            let ch = dec.channels
            var buf = [Float](repeating: 0, count: 4096 * ch)
            var total = 0
            var sumsq = 0.0
            var all: [Float] = []
            while true {
                let n = buf.withUnsafeMutableBufferPointer { dec.read($0.baseAddress!, frames: 4096) }
                if n == 0 { break }
                for i in 0..<(n * ch) { sumsq += Double(buf[i] * buf[i]) }
                if all.count < Int(dec.sampleRate) * 40 * ch { all.append(contentsOf: buf[0..<(n * ch)]) }
                total += n
            }
            let rms = sqrt(sumsq / Double(max(1, total * ch)))
            // Seek check: frame 20 s in should match the linear decode.
            let at = Int(dec.sampleRate * 20)
            dec.seek(toFrame: at)
            var seg = [Float](repeating: 0, count: 1024 * ch)
            let n = seg.withUnsafeMutableBufferPointer { dec.read($0.baseAddress!, frames: 1024) }
            var maxErr: Float = 0
            if n == 1024 && all.count >= (at + 1024) * ch {
                for i in 0..<(1024 * ch) { maxErr = max(maxErr, abs(seg[i] - all[at * ch + i])) }
            }
            let line = "audio \(role.rawValue) \(name): \(type(of: dec)) \(Int(dec.sampleRate)) Hz ×\(ch), \(String(format: "%.2f", Double(total) / dec.sampleRate)) s (len \(dec.lengthFrames ?? -1)), rms \(String(format: "%.3f", rms)), seek err \(String(format: "%.4f", maxErr))"
            if total == 0 || rms < 0.001 || maxErr > 0.05 { fail(line) } else { print("  ✓ " + line) }
        }
        // Mixer: 1 s of output at 48 kHz, starting in the lead-in.
        let decs = SongLoader.stems(in: pkg).compactMap { r, n in AudioDecoders.open(pkg: pkg, name: n).map { (r, $0) } }
        let mixer = StemMixer(outputRate: 48000, stems: decs)
        mixer.seek(to: -0.5)
        mixer.setPaused(false)
        var l = [Float](repeating: 0, count: 48000), r = [Float](repeating: 0, count: 48000)
        var energyLead = 0.0, energyAfter = 0.0
        for block in 0..<2 {
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                _ = mixer.render(left: lp.baseAddress!, right: rp.baseAddress!, frames: 24000)
            } }
            let e = l[0..<24000].reduce(0.0) { $0 + Double($1 * $1) }
            if block == 0 { energyLead = e } else { energyAfter = e }
        }
        let ml = "mixer: lead-in energy \(String(format: "%.3f", energyLead)), after 0 s \(String(format: "%.1f", energyAfter)), position \(String(format: "%.3f", mixer.position)) s"
        if energyLead != 0 || energyAfter <= 0 || abs(mixer.position - 0.5) > 0.001 { fail(ml) } else { print("  ✓ " + ml) }
        mixer.stop()
    } catch {
        fail("load: \(error)")
    }
}

// .chart vs .mid for the same song name
let byName = Dictionary(grouping: result.songs, by: \.name)
for (name, songs) in byName where songs.count > 1 {
    guard let c = songs.first(where: { $0.chartFile.hasSuffix(".chart") && $0.kind == .folder }), let m = songs.first(where: { $0.chartFile.hasSuffix(".mid") }),
          let a = charts[c.path], let b = charts[m.path] else { continue }
    print("\n⇄ \(name): .chart vs .mid")
    for (key, ta) in a.tracks.sorted(by: { ($0.key.instrument.rawValue, $0.key.difficulty.rawValue) < ($1.key.instrument.rawValue, $1.key.difficulty.rawValue) }) {
        guard let tb = b.tracks[key] else { fail("\(key) missing in .mid"); continue }
        var diffs: [String] = []
        if ta.chords.count != tb.chords.count { diffs.append("count \(ta.chords.count) vs \(tb.chords.count)") }
        for (x, y) in zip(ta.chords, tb.chords) where diffs.count < 4 {
            if x.tick != y.tick || x.mask != y.mask || x.kind != y.kind || x.gems.map(\.endTick) != y.gems.map(\.endTick) || x.spPhrase != y.spPhrase || (x.solo >= 0) != (y.solo >= 0) || x.gems.map(\.cymbal) != y.gems.map(\.cymbal) || x.activation != y.activation {
                diffs.append("@\(x.tick): mask \(x.mask)/\(y.mask) kind \(x.kind)/\(y.kind) ends \(x.gems.map(\.endTick))/\(y.gems.map(\.endTick)) sp \(x.spPhrase)/\(y.spPhrase) solo \(x.solo)/\(y.solo) cym \(x.gems.map(\.cymbal))/\(y.gems.map(\.cymbal)) act \(x.activation)/\(y.activation)")
            }
        }
        if diffs.isEmpty { print("  ✓ \(key.instrument.rawValue)/\(key.difficulty.displayName) identical (\(ta.chords.count) chords)") }
        else { fail("\(key.instrument.rawValue)/\(key.difficulty.displayName): " + diffs.joined(separator: "; ")) }
    }
}

// MARK: - Regression checks (synthetic, need no song arguments)

print("\n▶ regressions")
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("corecheck-\(getpid())", isDirectory: true)
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

// B1: a corrupt .sng index (negative / out-of-file entry) must throw, not trap.
do {
    func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }
    for (label, len, off) in [("negative length", UInt64.max, UInt64(0)), ("offset past end", UInt64(4), UInt64(1) << 40), ("negative offset", UInt64(4), UInt64.max - 3)] {
        var b = Array("SNGPKG".utf8) + [1, 0, 0, 0] + [UInt8](repeating: 0, count: 16)
        b += le64(8) + le64(0)                      // metadata: 0 pairs
        // Named notes.chart so the library scan actually reads the bad entry.
        let idx = le64(1) + [11] + Array("notes.chart".utf8) + le64(len) + le64(off)
        b += le64(UInt64(idx.count)) + idx
        b += le64(4) + [1, 2, 3, 4]                 // file data
        let u = scratch.appendingPathComponent("bad-\(label.replacingOccurrences(of: " ", with: "-")).sng")
        try Data(b).write(to: u)
        if (try? SngPackage(url: u)) == nil { print("  ✓ B1 corrupt .sng (\(label)) rejected") } else { fail("B1 corrupt .sng (\(label)) accepted") }
    }
    let scan = LibraryScanner.scan(roots: [scratch], cache: [:])
    if scan.songs.isEmpty && scan.errors.count == 3 { print("  ✓ B1 library scan reports corrupt .sng files as errors") } else { fail("B1 scan: \(scan.songs.count) songs, \(scan.errors.count) errors") }
} catch { fail("B1 setup: \(error)") }

// B2: whammying the sustain of a phrase's last note still fills star power.
do {
    let dir = scratch.appendingPathComponent("whammy", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // 120 BPM: 4 single notes, the last one a 4-beat sustain, all in one SP phrase.
    let chart = """
    [Song]
    {
      Resolution = 192
    }
    [SyncTrack]
    {
      0 = TS 4
      0 = B 120000
    }
    [Events]
    {
    }
    [ExpertSingle]
    {
      768 = N 0 0
      960 = N 1 0
      1152 = N 2 0
      1344 = N 3 768
      768 = S 2 600
    }
    """
    try chart.write(to: dir.appendingPathComponent("notes.chart"), atomically: true, encoding: .utf8)
    let pkg = try FolderPackage(url: dir)
    let song = try SongLoader.loadChart(pkg: pkg, file: "notes.chart", ini: IniFile())
    guard let track = song.track(.guitar, .expert) else { throw ChartError.invalid("no track") }
    func run(whammy: Bool) -> Double {
        let eng = PlayEngine(track: track, tempo: song.tempo, sections: [], config: EngineConfig(), drumMode: .fourLanePro)
        for c in track.chords {
            eng.handle(.fret(lane: c.gems[0].lane, down: true), at: c.time - 0.02)
            eng.handle(.strum, at: c.time)
        }
        let last = track.chords.last!
        var t = last.time + 0.05, v = 0.0
        while t < last.sustainEndTime {
            if whammy { v = v == 0 ? 0.8 : 0; eng.handle(.whammy(v), at: t) } else { eng.advance(to: t) }
            t += 0.05
        }
        eng.advance(to: last.sustainEndTime + 0.5)
        return eng.spMeter
    }
    let still = run(whammy: false), wham = run(whammy: true)
    let line = "B2 SP after last-note sustain: \(String(format: "%.3f", still)) still, \(String(format: "%.3f", wham)) whammied"
    if abs(still - 0.25) < 1e-9 && wham > 0.25 + 0.1 { print("  ✓ " + line) } else { fail(line) }
} catch { fail("B2 setup: \(error)") }

// B3: after an underrun a stem must line back up with the song clock.
final class RampDecoder: AudioDecoder {
    let sampleRate = 48000.0, channels = 1
    let lengthFrames: Int? = 400_000
    var pos = 0
    func read(_ out: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let n = min(frames, lengthFrames! - pos)
        for i in 0..<max(0, n) { out[i] = Float(pos + i) / 1_000_000 }  // sample value = source frame
        pos += max(0, n)
        return max(0, n)
    }
    func seek(toFrame frame: Int) { pos = max(0, frame) }
}
do {
    let mixer = StemMixer(outputRate: 48000, stems: [(.song, RampDecoder())])
    mixer.seek(to: 0)  // prefills the ring; no feeder thread, so it then runs dry
    mixer.setPaused(false)
    var l = [Float](repeating: 0, count: 1000), r = [Float](repeating: 0, count: 1000)
    func block() -> Int64 { l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in mixer.render(left: lp.baseAddress!, right: rp.baseAddress!, frames: 1000) } } }
    for _ in 0..<140 { _ = block() }  // ~131k frames buffered → ~9k frames of underrun
    mixer.prefill()
    let at = block()
    let heard = Int((Double(l[0]) * 1_000_000).rounded())
    let line = "B3 after underrun: song frame \(at), stem frame \(heard)"
    if abs(heard - Int(at)) <= 1 { print("  ✓ " + line) } else { fail(line + " (out of sync by \(Int(at) - heard))") }
    mixer.stop()
}

// P7: the WAV header is read in place (no copy), including from a Data
// slice whose startIndex isn't 0.
do {
    func le(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    let frames = 1000
    var pcm: [UInt8] = []
    for i in 0..<frames { pcm += le(i * 16, 2) + le(-i * 16, 2) }  // stereo ramp, L = -R
    let fmt = Array("fmt ".utf8) + le(16, 4) + le(1, 2) + le(2, 2) + le(44100, 4) + le(44100 * 4, 4) + le(4, 2) + le(16, 2)
    let body = Array("WAVE".utf8) + fmt + Array("data".utf8) + le(pcm.count, 4) + pcm
    let wav = Array("RIFF".utf8) + le(body.count, 4) + body
    let padded = Data([0xAA, 0xBB, 0xCC] + wav)
    for (label, d) in [("whole", Data(wav)), ("slice", padded[3...])] {
        guard let dec = AudioDecoders.open(data: d) else { fail("P7 WAV (\(label)) not recognised"); continue }
        var out = [Float](repeating: 0, count: 2 * frames)
        let n = out.withUnsafeMutableBufferPointer { dec.read($0.baseAddress!, frames: frames) }
        let ok = n == frames && dec.channels == 2 && dec.sampleRate == 44100
            && abs(out[2 * 500] - Float(500 * 16) / 32768) < 1e-6 && abs(out[2 * 500 + 1] + Float(500 * 16) / 32768) < 1e-6
        if ok { print("  ✓ P7 WAV (\(label)): \(n) frames decoded correctly") } else { fail("P7 WAV (\(label)): n \(n) ch \(dec.channels) sr \(dec.sampleRate) s500 \(out[1000])") }
    }
}

// Q4: saved settings decode over defaults — missing keys keep defaults,
// a key that no longer decodes resets alone, the rest of the save survives.
do {
    struct Saved: Codable, Equatable {
        var speed = 1.0
        var lefty = false
        var mods = Modifiers()
        var added = "new default"  // a field newer than the save
    }
    let json = #"{"speed": 1.5, "lefty": true, "mods": {"mirror": true, "modchart": "notACase", "songSpeed": 0.75}}"#
    let plain = try? JSONDecoder().decode(Saved.self, from: Data(json.utf8))
    if let s = SavedState.decode(Data(json.utf8), over: Saved()) {
        let ok = s.speed == 1.5 && s.lefty && s.mods.mirror && s.mods.songSpeed == 0.75 && s.mods.modchart == .off && s.mods.twoXKick && s.added == "new default"
        let line = "Q4 settings over defaults: speed \(s.speed) lefty \(s.lefty) mirror \(s.mods.mirror) modchart \(s.mods.modchart) added \"\(s.added)\" (plain Codable: \(plain == nil ? "fails" : "ok"))"
        if ok { print("  ✓ " + line) } else { fail(line) }
    } else { fail("Q4 settings over defaults: decode failed") }
    if SavedState.decode(Data("[1,2]".utf8), over: Saved()) == nil { print("  ✓ Q4 non-object save rejected") } else { fail("Q4 non-object save accepted") }
}

/// Writes a song folder with `notes.chart` (+ a tiny WAV so it counts as a song).
func makeSongFolder(_ name: String, chart: String) throws -> URL {
    let dir = scratch.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try chart.write(to: dir.appendingPathComponent("notes.chart"), atomically: true, encoding: .utf8)
    func le(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    let pcm = [UInt8](repeating: 0, count: 400)
    let fmt = Array("fmt ".utf8) + le(16, 4) + le(1, 2) + le(1, 2) + le(44100, 4) + le(88200, 4) + le(2, 2) + le(16, 2)
    let body = Array("WAVE".utf8) + fmt + Array("data".utf8) + le(pcm.count, 4) + pcm
    try Data(Array("RIFF".utf8) + le(body.count, 4) + body).write(to: dir.appendingPathComponent("song.wav"))
    return dir
}
func chartText(ts: String = "4", notes: String) -> String {
    "[Song]\n{\n  Resolution = 192\n}\n[SyncTrack]\n{\n  0 = TS \(ts)\n  0 = B 120000\n}\n[Events]\n{\n}\n[ExpertSingle]\n{\n\(notes)\n}\n"
}

// B13: a full star power meter lasts 8 measures, so 7/4 drains faster than 4/4.
do {
    func spSeconds(ts: String) throws -> Double {
        // Two one-note phrases fill the meter to 0.5 (4 measures).
        let dir = try makeSongFolder("sp-\(ts.replacingOccurrences(of: " ", with: "-"))", chart: chartText(ts: ts, notes: "  192 = N 0 0\n  192 = S 2 1\n  384 = N 0 0\n  384 = S 2 1"))
        let song = try SongLoader.loadChart(pkg: try FolderPackage(url: dir), file: "notes.chart", ini: IniFile())
        guard let tr = song.track(.guitar, .expert) else { throw ChartError.invalid("no track") }
        let eng = PlayEngine(track: tr, tempo: song.tempo, sections: [], config: EngineConfig(), drumMode: .fourLanePro)
        eng.handle(.fret(lane: 0, down: true), at: 0.3)
        for c in tr.chords { eng.handle(.strum, at: c.time) }
        let start = 2.0
        eng.handle(.starPower, at: start)
        var t = start
        while eng.spActive && t < start + 60 { t += 0.005; eng.advance(to: t) }
        return t - start
    }
    let four = try spSeconds(ts: "4"), seven = try spSeconds(ts: "7")
    // 120 BPM: 4 measures of 4/4 = 16 beats = 8 s; of 7/4 = 28 beats = 14 s.
    let line = "B13 half-meter SP lasts \(String(format: "%.2f", four)) s in 4/4, \(String(format: "%.2f", seven)) s in 7/4 (want 8, 14)"
    if abs(four - 8) < 0.05 && abs(seven - 14) < 0.05 { print("  ✓ " + line) } else { fail(line) }
} catch { fail("B13 setup: \(error)") }

// B11: anchoring (lower frets held under a HOPO) isn't ghosting, so No
// Ghosting doesn't block the HOPO.
do {
    // Red strum at 2.0 s, then a natural HOPO on blue 50 ticks later.
    let dir = try makeSongFolder("anchor", chart: chartText(notes: "  768 = N 1 0\n  818 = N 3 0"))
    let song = try SongLoader.loadChart(pkg: try FolderPackage(url: dir), file: "notes.chart", ini: IniFile())
    guard let tr = song.track(.guitar, .expert), tr.chords.count == 2, tr.chords[1].kind == .hopo else { throw ChartError.invalid("expected strum then HOPO") }
    var mods = Modifiers(); mods.noGhosting = true
    let eng = PlayEngine(track: tr, tempo: song.tempo, sections: [], config: EngineConfig(), drumMode: .fourLanePro, modifiers: mods)
    eng.handle(.fret(lane: 1, down: true), at: 1.98)
    eng.handle(.strum, at: 2.0)
    eng.handle(.fret(lane: 0, down: true), at: 2.05)   // anchor green
    eng.handle(.fret(lane: 2, down: true), at: 2.07)   // anchor yellow
    eng.handle(.fret(lane: 3, down: true), at: tr.chords[1].time)  // hammer on blue
    eng.advance(to: 3)
    let line = "B11 anchored HOPO with No Ghosting: \(eng.notesHit)/2 hit"
    if eng.notesHit == 2 { print("  ✓ " + line) } else { fail(line) }
} catch { fail("B11 setup: \(error)") }

// B14: .chart metadata is read from the first 8 KB; a cut inside a UTF-8
// character must not turn the whole sample into CP1252 mojibake.
do {
    let pre = "[Song]\n{\n  Name = \"Café\"\n  Album = \""
    let pad = String(repeating: "x", count: 8191 - pre.utf8.count)  // "é" starts at byte 8191
    let chart = pre + pad + "éé\"\n  Resolution = 192\n}\n[SyncTrack]\n{\n  0 = TS 4\n  0 = B 120000\n}\n[Events]\n{\n}\n[ExpertSingle]\n{\n  768 = N 0 0\n}\n"
    let dir = try makeSongFolder("mojibake", chart: chart)
    let e = try SongLoader.makeEntry(pkg: try FolderPackage(url: dir), path: dir.path, kind: .folder, modified: 0, folderName: "mojibake")
    let line = "B14 .chart name with an 8 KB cut inside UTF-8: \"\(e.name)\""
    if e.name == "Café" { print("  ✓ " + line) } else { fail(line) }
} catch { fail("B14 setup: \(error)") }

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
