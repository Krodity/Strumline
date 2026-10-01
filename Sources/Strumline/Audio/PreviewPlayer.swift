import Foundation
import StrumCore

/// Song-select preview: plays preview.* if the song has one, otherwise the
/// full mix from preview_start_time, faded in and looped every 30 s.
@MainActor
final class PreviewPlayer {
    private var generation = 0
    private var fadeTimer: Timer?
    private(set) var current: String?
    var volume: Double = 0.6

    func play(_ song: SongEntry) {
        guard current != song.path else { return }
        current = song.path
        generation += 1
        let gen = generation
        stopAudio()
        Task.detached(priority: .userInitiated) {
            guard let pkg = try? SongLoader.package(for: song) else { return }
            let stems = SongLoader.stems(in: pkg)
            var decs: [(StemRole, AudioDecoder)] = []
            var start = max(0, Double(song.previewStartMs) / 1000)
            if let p = stems[.preview], let d = AudioDecoders.open(pkg: pkg, name: p) {
                decs = [(.preview, d)]
                start = 0
            } else {
                for (r, n) in stems where r != .preview {
                    if let d = AudioDecoders.open(pkg: pkg, name: n) { decs.append((r, d)) }
                }
                if song.previewStartMs < 0 { start = Double(song.lengthMs) / 1000 * 0.35 }
            }
            guard !decs.isEmpty else { return }
            let decoders = decs
            let s = start
            await MainActor.run {
                guard gen == self.generation else { return }
                // The mixer takes ownership; start after a short debounce so
                // fast scrolling doesn't thrash the audio engine.
                let mixer = AudioEngine.shared.load(stems: decoders)
                mixer.setMasterGain(0)
                mixer.seek(to: s)
                mixer.setPaused(false)
                self.fade(mixer, gen: gen, start: s)
            }
        }
    }

    private func fade(_ mixer: StemMixer, gen: Int, start: Double) {
        fadeTimer?.invalidate()
        let began = Date()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, gen == self.generation else { timer.invalidate(); return }
                let el = Date().timeIntervalSince(began)
                let cycle = el.truncatingRemainder(dividingBy: 30)
                var g = min(1, cycle / 1.0)
                if cycle > 28 { g = max(0, (30 - cycle) / 2) }
                mixer.setMasterGain(g * self.volume)
                if cycle < 1 / 30 && el > 1 {
                    mixer.setPaused(true)
                    mixer.seek(to: start)
                    mixer.setPaused(false)
                }
            }
        }
    }

    private func stopAudio() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        AudioEngine.shared.unload()
    }

    func stop() {
        generation += 1
        current = nil
        stopAudio()
    }
}
