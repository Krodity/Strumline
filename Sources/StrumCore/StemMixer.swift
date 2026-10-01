import Foundation
import CAtomics

/// Mixes every stem of a song to stereo at the output rate.
///
/// A feeder thread decodes and resamples each stem into a lock-free ring;
/// the audio thread's `render` only copies and sums. The song position is
/// counted in output frames and may start negative (lead-in silence).
public final class StemMixer: @unchecked Sendable {
    final class Stem {
        let role: StemRole
        let decoder: AudioDecoder
        let capacity: Int  // frames, power of two
        let ring: UnsafeMutablePointer<Float>  // stereo interleaved
        var written: Int64 = 0  // atomic, frames
        var consumed: Int64 = 0  // atomic, frames
        var gain: Double = 1  // atomic target gain
        var current: Float = 1  // audio thread only
        /// Frames the song clock moved past while this stem's ring was empty
        /// (an underrun); dropped from the ring once they arrive so the stem
        /// stays in step with the chart. Audio thread only (reset on seek).
        var skip = 0
        var ended = false
        // resampler (feeder thread only)
        let step: Double
        var frac: Double = 0
        var hist: [Float] = [0, 0, 0, 0, 0, 0, 0, 0]  // 4 stereo frames: p0 p1 p2 p3
        var histFill = 0
        var tail = 0
        var decodeBuf: [Float]
        var srcFrames: [Float] = []
        var srcPos = 0

        init(role: StemRole, decoder: AudioDecoder, outRate: Double) {
            self.role = role
            self.decoder = decoder
            capacity = 1 << 17
            ring = .allocate(capacity: capacity * 2)
            ring.initialize(repeating: 0, count: capacity * 2)
            step = decoder.sampleRate / outRate
            decodeBuf = [Float](repeating: 0, count: 4096 * max(1, decoder.channels))
        }
        deinit { ring.deallocate() }

        func reset() {
            sl_store64(&written, 0)
            sl_store64(&consumed, 0)
            frac = 0
            histFill = 0
            tail = 0
            skip = 0
            srcFrames.removeAll(keepingCapacity: true)
            srcPos = 0
            ended = false
            for i in hist.indices { hist[i] = 0 }
        }

        /// Next source frame as stereo, or nil at the end.
        func nextSource() -> (Float, Float)? {
            if srcPos >= srcFrames.count {
                let ch = max(1, decoder.channels)
                let n = decodeBuf.withUnsafeMutableBufferPointer { decoder.read($0.baseAddress!, frames: 4096) }
                if n <= 0 { return nil }
                srcFrames.removeAll(keepingCapacity: true)
                for i in 0..<n {
                    let l = decodeBuf[i * ch]
                    let r = ch > 1 ? decodeBuf[i * ch + 1] : l
                    srcFrames.append(l)
                    srcFrames.append(r)
                }
                srcPos = 0
            }
            defer { srcPos += 2 }
            return (srcFrames[srcPos], srcFrames[srcPos + 1])
        }

        /// Fills the ring as far as it will go. Returns frames produced.
        func fill(maxFrames: Int) -> Int {
            if ended { return 0 }
            let w = sl_load64(&written), c = sl_load64(&consumed)
            let free = capacity - Int(w - c) - 1
            let want = min(free, maxFrames)
            if want <= 0 { return 0 }
            var produced = 0
            let mask = capacity - 1
            // Prime the 4-frame history (p0 is a duplicate of the first frame).
            while histFill < 4 {
                if let (l, r) = nextSource() {
                    if histFill == 0 { hist[0] = l; hist[1] = r; hist[2] = l; hist[3] = r; histFill = 2 }
                    else { hist[histFill * 2] = l; hist[histFill * 2 + 1] = r; histFill += 1 }
                } else {
                    if histFill == 0 { ended = true; return 0 }
                    hist[histFill * 2] = hist[histFill * 2 - 2]; hist[histFill * 2 + 1] = hist[histFill * 2 - 1]
                    histFill += 1
                }
            }
            while produced < want {
                // Catmull-Rom between p1 and p2.
                let t = Float(frac)
                for ch in 0..<2 {
                    let p0 = hist[ch], p1 = hist[2 + ch], p2 = hist[4 + ch], p3 = hist[6 + ch]
                    let a = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3
                    let b = p0 - 2.5 * p1 + 2 * p2 - 0.5 * p3
                    let cc = -0.5 * p0 + 0.5 * p2
                    ring[((Int(w) + produced) & mask) * 2 + ch] = ((a * t + b) * t + cc) * t + p1
                }
                produced += 1
                frac += step
                while frac >= 1 {
                    frac -= 1
                    hist[0] = hist[2]; hist[1] = hist[3]; hist[2] = hist[4]; hist[3] = hist[5]; hist[4] = hist[6]; hist[5] = hist[7]
                    if let (l, r) = nextSource() { hist[6] = l; hist[7] = r }
                    else {
                        // Source finished: run out the interpolator on silence.
                        hist[6] = 0; hist[7] = 0
                        tail += 1
                        if tail >= 3 { ended = true; break }
                    }
                }
                if ended { break }
            }
            sl_store64(&written, w + Int64(produced))
            return produced
        }
    }

    public let outputRate: Double
    private let stems: [Stem]
    private var songFrame: Int64 = 0  // atomic
    private var running = false
    private var paused: Int64 = 1  // atomic bool
    private var feederThread: Thread?
    private let wake = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    public var masterGain: Double = 1  // atomic via sl_*d

    public init(outputRate: Double, stems: [(StemRole, AudioDecoder)]) {
        self.outputRate = outputRate
        self.stems = stems.map { Stem(role: $0.0, decoder: $0.1, outRate: outputRate) }
    }

    deinit { stop() }

    public var roles: [StemRole] { stems.map(\.role) }

    /// Longest stem in seconds (0 if unknown).
    public var duration: Double {
        stems.map { s in Double(s.decoder.lengthFrames ?? 0) / s.decoder.sampleRate }.max() ?? 0
    }

    public func setGain(_ gain: Double, for roles: Set<StemRole>) {
        for s in stems where roles.contains(s.role) { sl_stored(&s.gain, gain) }
    }

    public func setGain(_ gain: Double, forRole role: StemRole) {
        for s in stems where s.role == role { sl_stored(&s.gain, gain) }
    }

    public func setMasterGain(_ g: Double) { sl_stored(&masterGain, g) }

    public var position: Double { Double(sl_load64(&songFrame)) / outputRate }
    public var positionFrames: Int64 { sl_load64(&songFrame) }

    /// Starts the feeder thread. Call once.
    public func start() {
        guard !running else { return }
        running = true
        let t = Thread { [weak self] in self?.feedLoop() }
        t.qualityOfService = .userInteractive
        t.name = "StemMixer.feed"
        feederThread = t
        t.start()
    }

    public func stop() {
        running = false
        wake.signal()
    }

    public func setPaused(_ p: Bool) { sl_store64(&paused, p ? 1 : 0); wake.signal() }
    public var isPaused: Bool { sl_load64(&paused) != 0 }

    /// Seek to a song time (may be negative). Only call while paused.
    public func seek(to time: Double) {
        lock.lock()
        let frame = Int64((time * outputRate).rounded())
        sl_store64(&songFrame, frame)
        for s in stems {
            s.reset()
            let srcFrame = max(0, Int(Double(max(0, frame)) * s.step))
            s.decoder.seek(toFrame: srcFrame)
        }
        lock.unlock()
        prefill()
    }

    /// Fills rings synchronously (before playback starts).
    public func prefill() {
        lock.lock()
        for s in stems { while s.fill(maxFrames: 8192) > 0 {} }
        lock.unlock()
    }

    private func feedLoop() {
        while running {
            lock.lock()
            var work = false
            for s in stems where s.fill(maxFrames: 4096) > 0 { work = true }
            lock.unlock()
            if !work { _ = wake.wait(timeout: .now() + .milliseconds(8)) }
        }
    }

    /// Audio-thread render. Writes `frames` stereo frames; returns the song
    /// frame of the first rendered frame.
    @discardableResult
    public func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Int64 {
        let start = sl_load64(&songFrame)
        left.update(repeating: 0, count: frames)
        right.update(repeating: 0, count: frames)
        if sl_load64(&paused) != 0 { return start }
        let master = Float(sl_loadd(&masterGain))
        // Lead-in: silence until the song position reaches 0.
        let lead = start < 0 ? min(frames, Int(-start)) : 0
        for s in stems {
            let target = Float(sl_loadd(&s.gain)) * master
            var g = s.current
            var c = sl_load64(&s.consumed)
            var avail = Int(sl_load64(&s.written) - c)
            // Catch up after an underrun instead of playing late forever.
            if s.skip > 0 && avail > 0 {
                let d = min(s.skip, avail)
                c += Int64(d)
                avail -= d
                s.skip -= d
                sl_store64(&s.consumed, c)
            }
            let want = frames - lead
            let n = min(want, avail)
            if n < want { s.skip += want - max(0, n) }  // harmless once the stem has ended
            let mask = s.capacity - 1
            if n > 0 {
                // ~5 ms gain ramp avoids clicks on mute/unmute.
                let rampStep = (target - g) / Float(max(1, min(n, 240)))
                for i in 0..<n {
                    if g != target {
                        g += rampStep
                        if (rampStep > 0 && g > target) || (rampStep < 0 && g < target) { g = target }
                    }
                    let idx = ((Int(c) + i) & mask) * 2
                    left[lead + i] += s.ring[idx] * g
                    right[lead + i] += s.ring[idx + 1] * g
                }
                sl_store64(&s.consumed, c + Int64(n))
            } else {
                g = target
            }
            s.current = g
        }
        sl_store64(&songFrame, start + Int64(frames))
        wake.signal()
        return start
    }
}
