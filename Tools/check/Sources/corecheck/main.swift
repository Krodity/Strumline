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

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
