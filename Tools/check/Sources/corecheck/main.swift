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

// Q10: scripted (non-perfect) play, the situations a bot run never hits.
func scripted(_ name: String, _ notes: String) throws -> (TrackChart, SongChart) {
    let dir = try makeSongFolder("q10-" + name, chart: chartText(notes: notes))
    let song = try SongLoader.loadChart(pkg: try FolderPackage(url: dir), file: "notes.chart", ini: IniFile())
    guard let tr = song.track(.guitar, .expert) else { throw ChartError.invalid("no track") }
    return (tr, song)
}
func check(_ ok: Bool, _ line: String) { if ok { print("  ✓ " + line) } else { fail(line) } }
do {
    // Overstrum: strumming with no note near breaks the combo.
    var (tr, song) = try scripted("over", "  768 = N 0 0\n  1536 = N 0 0")
    var eng = PlayEngine(track: tr, tempo: song.tempo, sections: [], config: EngineConfig(), drumMode: .fourLanePro)
    eng.handle(.fret(lane: 0, down: true), at: 1.9)
    eng.handle(.strum, at: tr.chords[0].time)
    let comboBefore = eng.combo
    eng.handle(.strum, at: tr.chords[0].time + 0.8)  // nothing there
    eng.advance(to: tr.chords[0].time + 0.9)
    check(comboBefore == 1 && eng.combo == 0 && eng.overstrums == 1, "Q10 overstrum: combo \(comboBefore) → \(eng.combo), overstrums \(eng.overstrums)")

    // A HOPO right after a missed note can't be hammered; it needs a strum.
    (tr, song) = try scripted("hopo-after-miss", "  768 = N 1 0\n  818 = N 3 0")
    eng = PlayEngine(track: tr, tempo: song.tempo, sections: [], config: EngineConfig(), drumMode: .fourLanePro)
    let hopo = tr.chords[1]
    eng.handle(.fret(lane: 3, down: true), at: hopo.time - 0.01)   // fret only: first note missed
    eng.advance(to: hopo.time + 0.01)
    let hammered = eng.notesHit
    eng.handle(.strum, at: hopo.time + 0.02)
    eng.advance(to: 3)
    check(hopo.kind == .hopo && hammered == 0 && eng.notesHit == 1, "Q10 HOPO after a miss: fretting alone hit \(hammered), with a strum \(eng.notesHit)/1")

    // Letting go of a sustain early ends it and scores less than holding it.
    (tr, song) = try scripted("sustain", "  768 = N 2 768")
    func sustainScore(releaseAfter: Double?) -> (Int, Int) {
        let e = PlayEngine(track: tr, tempo: song.tempo, sections: [], config: EngineConfig(), drumMode: .fourLanePro)
        let c = tr.chords[0]
        e.handle(.fret(lane: 2, down: true), at: c.time - 0.02)
        e.handle(.strum, at: c.time)
        if let r = releaseAfter { e.handle(.fret(lane: 2, down: false), at: c.time + r) }
        e.advance(to: c.time + 0.5)
        let active = e.sustains.count
        e.advance(to: c.sustainEndTime + 0.5)
        return (e.score, active)
    }
    let held = sustainScore(releaseAfter: nil), dropped = sustainScore(releaseAfter: 0.3)
    check(held.0 > dropped.0 && held.1 == 1 && dropped.1 == 0, "Q10 sustain: held \(held.0) pts, released early \(dropped.0) pts (sustain dropped: \(dropped.1 == 0))")

    // Solo: +100 per note hit in it.
    func soloScore(_ notes: String, name: String) throws -> Int {
        let (t, s) = try scripted(name, notes)
        let e = PlayEngine(track: t, tempo: s.tempo, sections: [], config: EngineConfig(), drumMode: .fourLanePro)
        e.handle(.fret(lane: 0, down: true), at: 1)
        for c in t.chords { e.handle(.strum, at: c.time) }
        e.advance(to: 5)
        return e.score
    }
    let plain = try soloScore("  768 = N 0 0\n  960 = N 0 0", name: "nosolo")
    let solo = try soloScore("  700 = E solo\n  768 = N 0 0\n  960 = N 0 0\n  1000 = E soloend", name: "solo")
    check(solo - plain == 200, "Q10 solo bonus: \(solo - plain) for 2 notes (want 200)")

    // Star power doubles the multiplier.
    (tr, song) = try scripted("sp-mult", "  192 = N 0 0\n  192 = S 2 1\n  384 = N 0 0\n  384 = S 2 1\n  1536 = N 0 0")
    eng = PlayEngine(track: tr, tempo: song.tempo, sections: [], config: EngineConfig(), drumMode: .fourLanePro)
    eng.handle(.fret(lane: 0, down: true), at: 0.3)
    eng.handle(.strum, at: tr.chords[0].time)
    eng.handle(.strum, at: tr.chords[1].time)
    let before = eng.multiplier
    eng.handle(.starPower, at: tr.chords[1].time + 0.3)
    let during = eng.multiplier
    let scoreBefore = eng.score
    eng.handle(.strum, at: tr.chords[2].time)
    check(eng.spActive && during == before * 2 && eng.score - scoreBefore == 50 * during, "Q10 star power: multiplier \(before) → \(during), last note +\(eng.score - scoreBefore)")
} catch { fail("Q10 setup: \(error)") }

// F1: online protocol — framing survives arbitrary packet splits, rejects
// junk; clock sync recovers the host offset despite uneven delays.
do {
    var stats = PlayStats(); stats.score = 12345; stats.notesHit = 99; stats.notesTotal = 100
    stats.sections = [SectionStat(name: "Solo", hit: 9, total: 10, index: 3)]
    let msgs: [NetMessage] = [
        .hello(version: Net.protocolVersion, player: NetPlayer(id: "g1", name: "Ant ✓", instrument: .drums, difficulty: .hard)),
        .ping(t0: 1.25), .pong(t0: 1.25, hostTime: 99.5),
        .pick(NetSong(chartHash: "abc123", name: "Strumline Demo", artist: "Strumline", lengthMs: 86000)),
        .start(chartHash: "abc123", hostTime: 105.0, speed: 1.0),
        .progress(NetScore(playerID: "g1", score: 500, combo: 10, notesHit: 10, notesTotal: 100, spActive: true)),
        .finished(playerID: "g1", stats: stats), .leave,
    ]
    let stream = msgs.reduce(Data()) { $0 + NetFramer.encode($1) }
    var ok = true
    for chunk in [1, 3, 7, 64, stream.count] {
        var f = NetFramer(); var got: [NetIncoming] = []
        var i = 0
        while i < stream.count { got += try f.append(stream.subdata(in: i..<min(stream.count, i + chunk))); i += chunk }
        if got != msgs.map(NetIncoming.message) { ok = false; fail("F1 framing (chunks of \(chunk)): got \(got.count)/\(msgs.count)") }
    }
    if ok { print("  ✓ F1 framing: \(msgs.count) messages round-trip through 1/3/7/64-byte and whole splits") }
    var big = NetFramer()
    let tooBig = (try? big.append(Data([0x7F, 0, 0, 0]))) == nil
    var junk = NetFramer()
    let notJSON = (try? junk.append(Data([0, 0, 0, 3, 0x41, 0x42, 0x43]))) == nil
    check(tooBig && notJSON, "F1 framing rejects an oversized frame (\(tooBig)) and a non-message (\(notJSON))")

    // Host clock = local + 37.25 s; one-way delays vary 5–80 ms, asymmetric.
    var sync = ClockSync()
    var rng = SplitMixTest(seed: 7)
    var local = 1000.0
    for _ in 0..<20 {
        let up = 0.005 + rng.next() * 0.075, down = 0.005 + rng.next() * 0.075
        let t0 = local
        let hostTime = t0 + up + 37.25
        let t2 = t0 + up + down
        sync.add(t0: t0, hostTime: hostTime, t2: t2)
        local += 0.2
    }
    let err = abs((sync.offset ?? 0) - 37.25)
    check(sync.isReady && err <= (sync.bestRTT ?? 1) / 2 + 1e-9 && err < 0.03, "F1 clock sync: offset error \(String(format: "%.1f", err * 1000)) ms (best RTT \(String(format: "%.0f", (sync.bestRTT ?? 0) * 1000)) ms)")
} catch { fail("F1 protocol: \(error)") }

// F1: a whole online session in memory — host + 2 guests with clocks off by
// +5.0 s and −3.2 s and 10–40 ms random delays: join, clock sync, pick (one
// guest has the song), synchronised start, scoreboard, results, drop-out.
do {
    var now = 0.0  // true time
    var queue: [(at: Double, run: () -> Void)] = []
    var rng = SplitMixTest(seed: 42)
    func later(_ f: @escaping () -> Void) { queue.append((now + 0.010 + rng.next() * 0.030, f)) }
    var ticks = 0  // integer tick count: float division could stall on a boundary
    func run(until t: Double, tick: () -> Void) {
        while now < t {
            queue.sort { $0.at < $1.at }
            let nextEvent = queue.first?.at ?? .infinity
            let nextTick = Double(ticks + 1) * 0.05
            if nextEvent <= nextTick { now = nextEvent; queue.removeFirst().run() } else { ticks += 1; now = nextTick; tick() }
        }
    }
    let host = NetHost(host: NetPlayer(id: "", name: "Ant", instrument: .guitar, difficulty: .expert))
    let offsets: [Double] = [5.0, -3.2]   // guest local clock − true time
    var guests: [NetGuest] = []
    var startAt: [Double?] = [nil, nil]
    var gone = Set<Int>()
    for (i, off) in offsets.enumerated() {
        let g = NetGuest(me: NetPlayer(id: "", name: i == 0 ? "PC" : "Pad", instrument: .drums, difficulty: .hard))
        g.hasSong = { _ in i == 0 }
        g.onStart = { _, at, _ in startAt[i] = at }
        g.send = { m in later { if !gone.contains(i) { host.receive(m, from: i, now: now) } } }
        guests.append(g)
        _ = off
    }
    host.send = { c, m in let g = guests[c]; let off = offsets[c]; later { if !gone.contains(c) { g.receive(m, now: now + off) } } }
    let tickAll = {
        host.tick(now: now)
        for (i, g) in guests.enumerated() where !gone.contains(i) { g.tick(now: now + offsets[i]) }
    }
    for (i, g) in guests.enumerated() { g.connected(now: now + offsets[i]) }
    run(until: 2, tick: tickAll)
    // Join order depends on the random delays; check by name.
    check(host.players.first?.name == "Ant" && Set(host.players.map(\.name)) == ["Ant", "PC", "Pad"] && guests.allSatisfy { $0.myID != nil && $0.players.count == 3 },
          "F1 session: both guests joined (\(host.players.map(\.name).joined(separator: ", ")))")
    host.pick(NetSong(chartHash: "abc", name: "Demo", artist: "S", lengthMs: 60000))
    run(until: 2.5, tick: tickAll)
    func has(_ n: String) -> Bool? { host.players.first { $0.name == n }?.hasSong }
    check(has("Ant") == true && has("PC") == true && has("Pad") == false && host.readyPlayers.count == 2, "F1 session: song status Ant/PC/Pad = \(["Ant", "PC", "Pad"].map { has($0).map(String.init) ?? "?" })")
    let hostStart = now + 3
    host.start(at: hostStart, speed: 1)
    run(until: 3, tick: tickAll)
    let errs = startAt.enumerated().map { i, at in at.map { abs(($0 - offsets[i]) - hostStart) * 1000 } ?? 999 }
    check(errs.allSatisfy { $0 < 20 }, "F1 session: synchronised start, error PC \(String(format: "%.1f", errs[0])) ms, Pad \(String(format: "%.1f", errs[1])) ms")
    guests[0].report(NetScore(playerID: "", score: 4200, combo: 30, notesHit: 31, notesTotal: 40, spActive: false))
    host.reportLocal(NetScore(playerID: "", score: 5100, combo: 35, notesHit: 36, notesTotal: 40, spActive: true))
    run(until: 3.6, tick: tickAll)
    let board = guests[1].scores.map { "\($0.playerID)=\($0.score)" }.joined(separator: ",")
    check(guests[1].scores.count == 2 && guests[1].scores.contains { $0.playerID == guests[0].myID && $0.score == 4200 }, "F1 session: scoreboard reaches the other guest (\(board))")
    gone.insert(1); host.disconnected(1)   // Pad drops out mid-song
    var st = PlayStats(); st.score = 5100
    host.finishLocal(st)
    run(until: 4, tick: tickAll)
    check(guests[0].finals["host"]?.score == 5100 && host.players.first { $0.name == "Pad" }?.connected == false,
          "F1 session: results relayed; dropped player kept on the board as disconnected")
    host.endSong(abort: false)
    check(host.phase == .lobby && host.players.count == 2, "F1 session: back to lobby without the dropped player")
}

// F1 phase 2: sending a song to a guest who doesn't have it.
do {
    // Chunk frames round-trip (binary, not JSON) between JSON frames.
    let ch = NetChunk(chartHash: "abc123", file: 3, offset: 1 << 33, bytes: Data((0..<5000).map { UInt8($0 % 251) }))
    var fr = NetFramer()
    let got = try fr.append(NetFramer.encode(.leave) + NetFramer.encode(ch) + NetFramer.encode(.abort))
    check(got == [.message(.leave), .chunk(ch), .message(.abort)], "F1 transfer: binary chunk frame round-trips between messages")

    // Hostile or broken offers are refused before anything is written.
    let s0 = NetSong(chartHash: "abc123", name: "x", artist: "y", lengthMs: 1)
    let bad: [(String, NetSongOffer)] = [
        ("path", NetSongOffer(song: s0, files: [.init(name: "../evil", size: 1)], isSng: false)),
        ("absolute", NetSongOffer(song: s0, files: [.init(name: "/etc/passwd", size: 1)], isSng: false)),
        ("hidden", NetSongOffer(song: s0, files: [.init(name: ".profile", size: 1)], isSng: false)),
        ("huge", NetSongOffer(song: s0, files: [.init(name: "song.ogg", size: Net.maxSongBytes + 1)], isSng: false)),
        ("dupes", NetSongOffer(song: s0, files: [.init(name: "a.ogg", size: 1), .init(name: "a.ogg", size: 1)], isSng: false)),
        ("hash", NetSongOffer(song: NetSong(chartHash: "../x", name: "", artist: "", lengthMs: 0), files: [.init(name: "a", size: 1)], isSng: false)),
    ]
    let refused = bad.filter { NetSongReceiver.problem(with: $0.1) != nil }.map(\.0)
    check(refused.count == bad.count, "F1 transfer: refuses unsafe offers (\(refused.joined(separator: ", ")))")

    // Whole transfer of the demo song, host → guest, with flow control.
    let demoRoot = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "../../Sources/Strumline/Resources/Songs/Strumline Demo")
    guard let demo = LibraryScanner.scan(roots: [demoRoot], cache: [:]).songs.first,
          let source = NetSongSource.make(for: demo) else { throw ChartError.invalid("no demo song to send") }
    func transfer(corruptAt: Int? = nil) throws -> (NetHost, NetGuest, SongEntry?, URL) {
        let host = NetHost(host: NetPlayer(id: "", name: "Ant", instrument: .guitar, difficulty: .expert))
        let guest = NetGuest(me: NetPlayer(id: "", name: "PC", instrument: .guitar, difficulty: .expert))
        let cache = scratch.appendingPathComponent("netcache-\(corruptAt ?? -1)", isDirectory: true)
        guest.songCache = cache
        guest.hasSong = { _ in false }
        var received: SongEntry?
        guest.onSongReceived = { received = $0 }
        var inFlight: [NetIncoming] = [], chunksSent = 0
        host.send = { _, m in inFlight.append(.message(m)) }
        host.sendChunk = { _, c in
            var c = c
            if chunksSent == corruptAt, !c.bytes.isEmpty { c.bytes[c.bytes.startIndex] ^= 0xFF }
            chunksSent += 1
            var f = NetFramer()
            inFlight += (try? f.append(NetFramer.encode(c))) ?? []
        }
        host.canSend = { _ in inFlight.count < 3 }   // a small window, like a socket buffer
        host.songSource = { $0 == source.offer.song.chartHash ? source : nil }
        guest.send = { m in host.receive(m, from: 1, now: 0) }
        guest.connected(now: 0)
        while !inFlight.isEmpty { guest.receive(inFlight.removeFirst(), now: 0) }
        host.pick(source.offer.song)
        var rounds = 0
        repeat {
            while !inFlight.isEmpty { guest.receive(inFlight.removeFirst(), now: 0) }
            host.tick(now: 0)  // one instant: this test is about bytes, not timeouts
            rounds += 1
        } while (!inFlight.isEmpty || host.sending) && rounds < 100_000
        return (host, guest, received, cache)
    }
    let (host, _, entry, cache) = try transfer()
    let mb = String(format: "%.1f", Double(source.offer.totalBytes) / 1_000_000)
    var same = entry != nil
    if let e = entry {
        for f in source.offer.files {
            let a = try? Data(contentsOf: demo.url.appendingPathComponent(f.name)), b = try? Data(contentsOf: e.url.appendingPathComponent(f.name))
            if a == nil || a != b { same = false }
        }
    }
    check(same && entry?.chartHash == demo.chartHash && host.players.last?.hasSong == true && entry?.url.path.hasPrefix(cache.path) == true,
          "F1 transfer: \(source.offer.files.count) files (\(mb) MB) arrive byte-identical, load as the same song (hash \(entry?.chartHash ?? "–")), guest marked as having it")

    // Rejoining re-sends the pick: a song already received must survive it
    // (it may be playing) and not be asked for again.
    do {
        let (h3, g3, e3, _) = try transfer(corruptAt: 999)
        var asked = false
        h3.send = { _, m in if case .songAccept = m { asked = true } }
        g3.send = { m in if case .songAccept = m { asked = true }; h3.receive(m, from: 1, now: 0) }
        g3.receive(.pick(source.offer.song), now: 0)
        let still = e3.map { FileManager.default.fileExists(atPath: $0.url.appendingPathComponent(demo.chartFile).path) } ?? false
        check(still && !asked && h3.players.last?.hasSong == true, "F1 transfer: a repeated pick (rejoin) keeps the received song and doesn't re-download")
    }

    // A corrupted byte in the chart is caught; nothing is kept.
    let (host2, _, entry2, cache2) = try transfer(corruptAt: 0)
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: cache2.path))?.count ?? 0
    check(entry2 == nil && host2.players.last?.hasSong == false && leftovers == 0,
          "F1 transfer: a corrupted chart is rejected and deleted (guest marked as not having it)")
} catch { fail("F1 transfer: \(error)") }

// F1 phase 3: silent connections time out; a guest that drops mid-song
// rejoins its own slot and keeps its score.
do {
    let host = NetHost(host: NetPlayer(id: "", name: "Ant", instrument: .guitar, difficulty: .expert))
    let guest = NetGuest(me: NetPlayer(id: "", name: "PC", instrument: .drums, difficulty: .hard))
    var conn = 1, closed: [Int] = []
    var t = 0.0
    host.send = { c, m in if c == conn { guest.receive(m, now: t) } }
    host.closeConnection = { closed.append($0) }
    guest.send = { m in host.receive(m, from: conn, now: t) }
    guest.hasSong = { _ in true }
    guest.connected(now: t)
    let firstID = guest.myID
    host.pick(NetSong(chartHash: "abc", name: "Demo", artist: "S", lengthMs: 60000))
    host.start(at: t + 4, speed: 1)
    guest.report(NetScore(playerID: "", score: 777, combo: 5, notesHit: 5, notesTotal: 6, spActive: false))
    for _ in 0..<20 { t += 0.5; host.tick(now: t); guest.tick(now: t) }
    check(closed.isEmpty && !guest.isStale(now: t), "F1 phase 3: a pinging guest stays connected (no timeout)")

    // The network dies silently: nothing more arrives either way.
    host.send = { _, _ in }; guest.send = { _ in }
    for _ in 0..<25 { t += 0.5; host.tick(now: t); guest.tick(now: t) }
    let dropped = host.players.first { $0.name == "PC" }?.connected == false
    check(closed == [1] && dropped && guest.isStale(now: t), "F1 phase 3: silent for >10 s → host drops the guest (\(closed)), guest sees the host as stale")

    // The guest reconnects on a new connection, mid-song.
    conn = 2
    host.send = { c, m in if c == conn { guest.receive(m, now: t) } }
    guest.send = { m in host.receive(m, from: conn, now: t) }
    guest.connected(now: t)
    let pc = host.players.filter { $0.name == "PC" }
    check(guest.myID == firstID && pc.count == 1 && pc[0].connected && host.scores[firstID ?? ""]?.score == 777 && host.phase == .playing,
          "F1 phase 3: rejoin mid-song restores the same slot (\(firstID ?? "–")) and score")

    // A stranger can't take over someone's slot while they're still connected.
    let other = NetGuest(me: NetPlayer(id: "", name: "Imposter", instrument: .guitar, difficulty: .easy))
    var refused = ""
    other.onEnd = { refused = $0 }
    other.send = { m in host.receive(m, from: 3, now: t) }
    host.send = { c, m in if c == 3 { other.receive(m, now: t) } else if c == conn { guest.receive(m, now: t) } }
    var hello = NetPlayer(id: firstID ?? "", name: "Imposter", instrument: .guitar, difficulty: .easy)
    hello.id = firstID ?? ""
    host.receive(.hello(version: Net.protocolVersion, player: hello), from: 3, now: t)
    check(!refused.isEmpty && host.players.filter { $0.name == "PC" }.count == 1 && host.players.allSatisfy { $0.name != "Imposter" },
          "F1 phase 3: a connected player's slot can't be taken (\(refused))")
}

// The host knows who's still finishing the last song after it's back in
// the lobby (so its Start can warn), and forgets them as they finish.
do {
    let host = NetHost(host: NetPlayer(id: "", name: "Ant", instrument: .guitar, difficulty: .expert))
    let guest = NetGuest(me: NetPlayer(id: "", name: "PC", instrument: .guitar, difficulty: .expert))
    host.send = { _, m in guest.receive(m, now: 0) }
    guest.send = { m in host.receive(m, from: 1, now: 0) }
    guest.hasSong = { _ in true }
    guest.connected(now: 0)
    host.pick(NetSong(chartHash: "abc", name: "Demo", artist: "S", lengthMs: 1000))
    host.start(at: 1, speed: 1)
    host.finishLocal(PlayStats())
    host.endSong(abort: false)
    let during = host.stillPlaying.count
    guest.finish(PlayStats())
    check(during == 1 && host.stillPlaying.isEmpty && host.phase == .lobby, "F1: host tracks a guest still finishing after it's back in the lobby (\(during) → \(host.stillPlaying.count))")
}

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)

/// Deterministic 0..<1 randoms for the synthetic checks.
struct SplitMixTest {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}
