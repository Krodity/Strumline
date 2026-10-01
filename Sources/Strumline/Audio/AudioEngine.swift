import AVFoundation
import QuartzCore
import StrumCore

/// Seconds on the same clock as CACurrentMediaTime / UITouch.timestamp.
private let machToSeconds: Double = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return Double(tb.numer) / Double(tb.denom) / 1_000_000_000
}()

func hostSeconds(_ machTime: UInt64) -> Double {
    Double(machTime) * machToSeconds
}

/// Owns the AVAudioEngine. A song plays through a `StemMixer` wrapped in an
/// AVAudioSourceNode; `songTime(at:)` turns any host time into song time.
final class AudioEngine: @unchecked Sendable {
    static let shared = AudioEngine()

    let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let timePitch = AVAudioUnitTimePitch()
    private let sfxPlayer = AVAudioPlayerNode()
    private var sfxBuffers: [Sfx: AVAudioPCMBuffer] = [:]
    private(set) var mixer: StemMixer?
    private(set) var outputRate: Double = 48000
    private(set) var speed: Double = 1

    // Written by the render thread: song frame at the start of the last
    // rendered buffer and that buffer's host time. Two slots + index in raw
    // memory (no Swift array copy-on-write on the audio thread) so readers
    // never see a torn pair: [frame0, host0, frame1, host1, index].
    private let clock: UnsafeMutablePointer<Double> = {
        let p = UnsafeMutablePointer<Double>.allocate(capacity: 5)
        p.initialize(repeating: 0, count: 5)
        return p
    }()
    private var lastSongTime: Double = -.infinity

    enum Sfx: CaseIterable { case miss, spReady, spActivate, tick, click }

    private init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setPreferredIOBufferDuration(0.005)
        try? session.setActive(true)
        outputRate = session.sampleRate > 0 ? session.sampleRate : 48000

        engine.attach(timePitch)
        engine.attach(sfxPlayer)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
        engine.connect(timePitch, to: engine.mainMixerNode, format: fmt)
        engine.connect(sfxPlayer, to: engine.mainMixerNode, format: fmt)
        makeSfx(format: fmt)

        AudioDecoders.platformFactory = { pkg, name in AVFileDecoder.open(pkg: pkg, name: name) }

        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            self?.restartIfNeeded()
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restartIfNeeded()
        }
        startEngine()
    }

    private func startEngine() {
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
    }

    func restartIfNeeded() {
        try? AVAudioSession.sharedInstance().setActive(true)
        startEngine()
    }

    /// Output latency the device reports (Bluetooth headphones are large).
    var outputLatency: Double {
        let s = AVAudioSession.sharedInstance()
        return s.outputLatency + s.ioBufferDuration + (speed != 1 ? 0.03 : 0)
    }

    // MARK: Song playback

    func load(stems: [(StemRole, AudioDecoder)]) -> StemMixer {
        unload()
        let m = StemMixer(outputRate: outputRate, stems: stems)
        mixer = m
        let fmt = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
        let clock = self.clock
        // Captures the mixer and clock directly: the render thread never
        // touches `self`'s Swift properties.
        let node = AVAudioSourceNode(format: fmt) { _, timestamp, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard list.count >= 2, let l = list[0].mData?.assumingMemoryBound(to: Float.self), let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let start = m.render(left: l, right: r, frames: Int(frameCount))
            let ts = timestamp.pointee
            let host = ts.mFlags.contains(.hostTimeValid) ? hostSeconds(ts.mHostTime) : CACurrentMediaTime()
            let next = clock[4] == 0 ? 1 : 0
            clock[next * 2] = Double(start)
            clock[next * 2 + 1] = host
            clock[4] = Double(next)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: timePitch, format: fmt)
        source = node
        m.start()
        startEngine()
        return m
    }

    func unload() {
        mixer?.setPaused(true)
        mixer?.stop()
        if let s = source {
            engine.disconnectNodeOutput(s)
            engine.detach(s)
        }
        source = nil
        mixer = nil
        lastSongTime = -.infinity
    }

    func setSpeed(_ s: Double) {
        speed = s
        timePitch.rate = Float(s)
        timePitch.bypass = s == 1
    }

    /// Song time (seconds) being heard at host time `h`, before the user's
    /// calibration offset.
    func songTime(at h: Double) -> Double {
        guard let m = mixer else { return 0 }
        let i = Int(clock[4]) * 2
        let frame = clock[i], host = clock[i + 1]
        if m.isPaused || host == 0 {
            return Double(m.positionFrames) / outputRate - outputLatency * speed
        }
        let t = frame / outputRate + (h - host) * speed - outputLatency * speed
        return t
    }

    /// Monotonic variant for rendering (never steps backwards on jitter).
    func smoothSongTime(at h: Double) -> Double {
        let t = songTime(at: h)
        if t < lastSongTime && lastSongTime - t < 0.05 { return lastSongTime }
        lastSongTime = t
        return t
    }

    func resetClock() {
        clock.update(repeating: 0, count: 5)
        lastSongTime = -.infinity
    }

    // MARK: SFX

    var sfxVolume: Float = 0.7

    func play(_ sfx: Sfx) {
        guard let b = sfxBuffers[sfx] else { return }
        sfxPlayer.volume = sfxVolume
        sfxPlayer.scheduleBuffer(b, at: nil, options: [], completionHandler: nil)
        if !sfxPlayer.isPlaying { sfxPlayer.play() }
    }

    /// Metronome clicks at exact host times (for calibration).
    func scheduleTicks(startHost: Double, count: Int, interval: Double) {
        guard let b = sfxBuffers[.tick] else { return }
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        sfxPlayer.volume = max(0.5, sfxVolume)
        if !sfxPlayer.isPlaying { sfxPlayer.play() }
        for i in 0..<count {
            let secs = startHost + Double(i) * interval
            let mach = UInt64(secs * 1_000_000_000 * Double(tb.denom) / Double(tb.numer))
            sfxPlayer.scheduleBuffer(b, at: AVAudioTime(hostTime: mach), options: [], completionHandler: nil)
        }
    }

    func stopSfx() { sfxPlayer.stop() }

    private func makeSfx(format: AVAudioFormat) {
        let sr = format.sampleRate
        func buffer(_ dur: Double, _ f: (Double) -> Float) -> AVAudioPCMBuffer {
            let n = AVAudioFrameCount(dur * sr)
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
            b.frameLength = n
            for i in 0..<Int(n) {
                let v = f(Double(i) / sr)
                b.floatChannelData![0][i] = v
                b.floatChannelData![1][i] = v
            }
            return b
        }
        var seed: UInt32 = 12345
        func noise() -> Float {
            seed = seed &* 1_103_515_245 &+ 12345
            return Float(Int32(bitPattern: seed)) / Float(Int32.max)
        }
        // Dull clank for misses.
        sfxBuffers[.miss] = buffer(0.18) { t in
            let e = Float(exp(-t * 28))
            return (Float(sin(2 * .pi * 110 * t)) * 0.5 + Float(sin(2 * .pi * 173 * t)) * 0.3 + noise() * 0.35) * e * 0.5
        }
        sfxBuffers[.spReady] = buffer(0.35) { t in
            let f = t < 0.12 ? 880.0 : 1320.0
            return Float(sin(2 * .pi * f * t)) * Float(exp(-t * 8)) * 0.35
        }
        sfxBuffers[.spActivate] = buffer(0.8) { t in
            let f = 300 + 1400 * t
            return (Float(sin(2 * .pi * f * t)) * 0.3 + noise() * 0.25 * Float(max(0, 1 - t * 1.5))) * Float(exp(-t * 3))
        }
        sfxBuffers[.tick] = buffer(0.05) { t in Float(sin(2 * .pi * 1500 * t)) * Float(exp(-t * 90)) * 0.6 }
        sfxBuffers[.click] = buffer(0.03) { t in Float(sin(2 * .pi * 2200 * t)) * Float(exp(-t * 150)) * 0.3 }
    }
}

/// mp3 / m4a / flac / aiff through AVAudioFile. `.sng` contents are written
/// to a temp file first because AVAudioFile needs a URL.
final class AVFileDecoder: AudioDecoder {
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    let sampleRate: Double
    let channels: Int
    let lengthFrames: Int?

    static func open(pkg: SongPackage, name: String) -> AudioDecoder? {
        var url = pkg.directURL(named: name)
        if url == nil, let d = try? pkg.data(named: name) {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
            if (try? d.write(to: tmp)) != nil { url = tmp }
        }
        guard let u = url, let f = try? AVAudioFile(forReading: u, commonFormat: .pcmFormatFloat32, interleaved: false) else { return nil }
        return AVFileDecoder(file: f)
    }

    init?(file: AVAudioFile) {
        self.file = file
        let fmt = file.processingFormat
        sampleRate = fmt.sampleRate
        channels = Int(fmt.channelCount)
        lengthFrames = Int(file.length)
        guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4096) else { return nil }
        buffer = b
    }

    func read(_ out: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        var done = 0
        while done < frames {
            let want = AVAudioFrameCount(min(4096, frames - done))
            buffer.frameLength = 0
            do { try file.read(into: buffer, frameCount: want) } catch { break }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            for c in 0..<channels {
                let src = buffer.floatChannelData![c]
                for i in 0..<n { out[(done + i) * channels + c] = src[i] }
            }
            done += n
        }
        return done
    }

    func seek(toFrame frame: Int) {
        file.framePosition = AVAudioFramePosition(max(0, min(frame, Int(file.length))))
    }
}
