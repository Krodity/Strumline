import Foundation
import QuartzCore
import AVFoundation
import UIKit
import StrumCore

struct PracticeRange: Equatable {
    var startSection: Int
    var endSection: Int
}

struct GameResult {
    var song: SongEntry
    var instrument: Instrument
    var difficulty: Difficulty
    var stats: PlayStats
    var modifiers: Modifiers
    var newBest = false
    var playerName = "Player 1"
    var playerIndex = 0
}

/// A floating label on the highway ("Solo! 94%", "100 Note Streak").
struct Banner {
    var text: String
    var detail: String = ""
    var time: Double
    var color: UIColor = .white
}

/// Who plays what, with which settings and device.
struct PlayerSetup {
    var name: String
    var instrument: Instrument
    var difficulty: Difficulty
    var settings: GameSettings
}

/// One player's highway: chart, engine and everything drawn for them.
final class PlayerRun {
    let index: Int
    let name: String
    let instrument: Instrument
    let difficulty: Difficulty
    let settings: GameSettings
    let modifiers: Modifiers
    let drumMode: DrumPlayMode
    let track: TrackChart
    let baseScore: Double
    let stems: Set<StemRole>
    var engine: PlayEngine
    var banners: [Banner] = []
    var hitOffsets: [(time: Double, offset: Double)] = []
    var lastMissTime: Double = -.infinity
    var spActivatedAt: Double = -.infinity
    var muted = false
    /// Replaces `stems` when the song lacks this part's stem.
    var stemsOverride: Set<StemRole>?
    var playerStems: Set<StemRole> { stemsOverride ?? stems }
    /// Custom highway image, resolved once (the renderer runs every frame).
    let highwayImageURL: URL?

    init(index: Int, setup: PlayerSetup, chart: SongChart, practice: PracticeRange?, loop: (Double, Double)) throws {
        self.index = index
        name = setup.name
        settings = setup.settings
        var mods = setup.settings.modifiers
        if practice != nil { mods.brutal = false }
        modifiers = mods
        drumMode = setup.settings.drumMode
        // Fall back to a charted part if this exact one isn't.
        let parts = chart.availableParts
        var inst = setup.instrument
        if parts[inst] == nil { inst = parts.keys.sorted { $0.rawValue < $1.rawValue }.first { $0.kind == setup.instrument.kind } ?? parts.keys.sorted { $0.rawValue < $1.rawValue }.first ?? inst }
        let diffs = parts[inst] ?? []
        let diff = diffs.contains(setup.difficulty) ? setup.difficulty : (diffs.min { abs($0.rawValue - setup.difficulty.rawValue) < abs($1.rawValue - setup.difficulty.rawValue) } ?? setup.difficulty)
        instrument = inst
        difficulty = diff
        guard let raw = chart.track(inst, diff) else { throw ChartError.invalid("That part isn't charted") }
        var prepared = TrackPrep.prepare(raw, modifiers: mods, drumMode: drumMode)
        if practice != nil {
            prepared.chords = prepared.chords.filter { $0.time >= loop.0 - 0.001 && $0.time < loop.1 - 0.001 }
            TrackPrep.fixPhraseEnds(&prepared)
        }
        track = prepared
        engine = PlayEngine(track: prepared, tempo: chart.tempo, sections: chart.sections, config: setup.settings.engineConfig, drumMode: drumMode, modifiers: mods)
        baseScore = engine.baseScore
        stems = Set(inst.stems)
        highwayImageURL = CustomAssets.highwayURL(setup.settings.highwayImage)
    }

    func resetEngine(chart: SongChart) {
        engine = PlayEngine(track: track, tempo: chart.tempo, sections: chart.sections, config: settings.engineConfig, drumMode: drumMode, modifiers: modifiers)
        banners = []
        hitOffsets = []
        muted = false
    }

    var soloProgress: (hit: Int, total: Int)? {
        let s = engine.currentSolo
        guard s >= 0, s < engine.soloTotals.count else { return nil }
        return (engine.soloHits[s], engine.soloTotals[s])
    }
}

/// One song being played by 1-4 players: loads chart + audio, runs every
/// player's engine off the shared audio clock.
final class GameSession: ObservableObject {
    let song: SongEntry
    let settings: GameSettings
    let chart: SongChart
    let pkg: SongPackage
    let practice: PracticeRange?
    let runs: [PlayerRun]
    let beatLines: [TempoMap.BeatLine]
    private let mixer: StemMixer
    private let routing: (map: [String: Int], fallback: Int?)

    // Player 1 shortcuts (single-player UI).
    var instrument: Instrument { runs[0].instrument }
    var difficulty: Difficulty { runs[0].difficulty }
    var modifiers: Modifiers { runs[0].modifiers }
    var drumMode: DrumPlayMode { runs[0].drumMode }
    var engine: PlayEngine { runs[0].engine }
    var track: TrackChart { runs[0].track }

    let startTime: Double
    let endTime: Double
    /// Practice loop bounds (chart time).
    let loopStart: Double
    let loopEnd: Double

    @Published var paused = false
    @Published var resumeCountdown: Int? = nil
    /// Highlighted pause-menu row for keyboard/controller navigation.
    @Published var pauseSelection = 0
    /// Runs a pause-menu row (set by GameView).
    var pauseAction: ((Int) -> Void)?
    static let pauseItems = 4
    var onFinish: (([GameResult]) -> Void)?
    var onQuit: (() -> Void)?

    // Render-facing state (read every frame; not @Published).
    private(set) var now: Double = 0
    private(set) var currentSection = -1
    private(set) var practiceRuns = 0
    private(set) var fps: Double = 0
    private var lastFrameHost: Double = 0
    private var finished = false
    /// `finish` has been dispatched (the frame loop keeps running until it lands).
    private var finishQueued = false

    let background: UIImage?
    let albumArt: UIImage?
    private(set) var videoPlayer: AVPlayer?
    private let videoStart: Double

    init(song: SongEntry, players: [PlayerSetup], settings: GameSettings, routing: (map: [String: Int], fallback: Int?), practice: PracticeRange?) throws {
        self.song = song
        self.settings = settings
        self.practice = practice
        self.routing = routing

        let (chart, pkg, ini) = try SongLoader.loadChart(entry: song)
        self.chart = chart
        self.pkg = pkg

        var ls = -Double.infinity, le = Double.infinity
        if let p = practice, !chart.sections.isEmpty {
            let s = chart.sections[max(0, min(p.startSection, chart.sections.count - 1))]
            let endIdx = min(p.endSection + 1, chart.sections.count)
            ls = s.time
            le = endIdx < chart.sections.count ? chart.sections[endIdx].time : chart.lastNoteTime + 0.5
        }
        loopStart = ls
        loopEnd = le
        var runs: [PlayerRun] = []
        for (i, setup) in players.enumerated() {
            runs.append(try PlayerRun(index: i, setup: setup, chart: chart, practice: practice, loop: (ls, le)))
        }
        guard !runs.isEmpty else { throw ChartError.invalid("No players") }
        self.runs = runs

        let firstNote = runs.compactMap { $0.track.chords.first?.time }.min() ?? 0
        if practice != nil {
            startTime = max(ls - 2.5, -1.5)
            endTime = le + 0.5
        } else {
            startTime = min(-1.5, firstNote - 2.5)
            let last = max(runs.compactMap { $0.track.chords.last?.sustainEndTime }.max() ?? 0, chart.endEventTime ?? 0)
            endTime = last + 2.5
        }
        beatLines = chart.tempo.beatLines(until: endTime + 5)

        // Audio
        let stems = SongLoader.stems(in: pkg)
        var decoders: [(StemRole, AudioDecoder)] = []
        for (role, name) in stems where role != .preview {
            if let d = AudioDecoders.open(pkg: pkg, name: name) { decoders.append((role, d)) }
        }
        if decoders.isEmpty { throw ChartError.invalid("Couldn't decode any audio for this song") }
        let roles = Set(decoders.map(\.0))
        // Bass charts fall back to the rhythm stem when there's no bass stem.
        for r in runs where (r.instrument == .bass || r.instrument == .bassGHL) && !roles.contains(.bass) {
            r.stemsOverride = [.rhythm]
        }
        mixer = AudioEngine.shared.load(stems: decoders)
        mixer.setMasterGain(1)
        AudioEngine.shared.setSpeed(settings.modifiers.songSpeed)

        // Visuals
        func image(_ name: String?) -> UIImage? {
            guard let n = name, let d = try? pkg.data(named: n) else { return nil }
            return UIImage(data: d)
        }
        background = image(song.background)
        albumArt = image(song.albumArt)
        videoStart = Double(ini.int("video_start_time") ?? 0) / 1000
        if settings.showVideos, let v = song.video, let url = pkg.directURL(named: v) {
            let p = AVPlayer(url: url)
            p.isMuted = true
            videoPlayer = p
        }
        applyGains()
    }

    /// Player-owned stems play at the instrument volume unless that player
    /// is muted after a miss; everything else at the band volume.
    private func applyGains() {
        for role in mixer.roles {
            let owners = runs.filter { $0.playerStems.contains(role) }
            if owners.isEmpty {
                mixer.setGain(settings.musicVolume, forRole: role)
            } else {
                let muted = settings.muteOnMiss && owners.contains { $0.muted }
                mixer.setGain(muted ? 0 : settings.instrumentVolume, forRole: role)
            }
        }
    }

    // MARK: Lifecycle

    func start() {
        InputManager.shared.gameplayActive = true
        InputManager.shared.clearQueue()
        InputManager.shared.startTilt(settings.tiltStarPower && runs.count == 1)
        UIApplication.shared.isIdleTimerDisabled = true
        seek(to: startTime)
        mixer.setPaused(false)
        syncVideo(playing: true)
    }

    private func seek(to t: Double) {
        mixer.setPaused(true)
        AudioEngine.shared.resetClock()
        mixer.seek(to: t)
        now = t
    }

    func setPaused(_ p: Bool) {
        guard !finished else { return }
        if p {
            // Pausing also cancels a resume countdown in progress.
            guard !paused || resumeCountdown != nil else { return }
            paused = true
            pauseSelection = 0
            resumeCountdown = nil
            countdownToken += 1
            mixer.setPaused(true)
            syncVideo(playing: false)
        } else {
            // Stay paused through a 3-2-1 count-in, like Clone Hero, then
            // restart the audio (the song clock follows it).
            guard paused, resumeCountdown == nil else { return }
            countdownToken += 1
            resumeCountdown = 3
            tickCountdown(token: countdownToken)
        }
    }

    private var countdownToken = 0

    private func tickCountdown(token: Int) {
        guard token == countdownToken, let c = resumeCountdown, !finished else { return }
        if c <= 0 {
            resumeCountdown = nil
            InputManager.shared.clearQueue()
            mixer.setPaused(false)
            paused = false
            syncVideo(playing: true)
            return
        }
        AudioEngine.shared.play(.tick)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, token == self.countdownToken else { return }
            self.resumeCountdown = c - 1
            self.tickCountdown(token: token)
        }
    }

    func quit() {
        teardown()
        onQuit?()
    }

    func quitSilently() { teardown() }

    private func teardown() {
        finished = true
        InputManager.shared.gameplayActive = false
        InputManager.shared.startTilt(false)
        UIApplication.shared.isIdleTimerDisabled = false
        videoPlayer?.pause()
        AudioEngine.shared.unload()
        AudioEngine.shared.setSpeed(1)
    }

    private func finish() {
        guard !finished else { return }
        let results = runs.map { r in
            GameResult(song: song, instrument: r.instrument, difficulty: r.difficulty, stats: r.engine.stats(base: r.baseScore),
                       modifiers: r.modifiers, playerName: r.name, playerIndex: r.index)
        }
        teardown()
        onFinish?(results)
    }

    /// The video's own time zero is still ahead (lead-in, or a negative
    /// video_start_time): `frame` starts it when the song gets there.
    private var videoWaiting = false

    private func syncVideo(playing: Bool) {
        guard let v = videoPlayer else { return }
        let t = now + videoStart
        if playing && t >= 0 {
            videoWaiting = false
            v.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            v.rate = Float(settings.modifiers.songSpeed)
        } else if playing {
            // Hold on the first frame until the song reaches the video's start.
            videoWaiting = true
            v.pause()
            v.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            videoWaiting = false
            v.pause()
        }
    }

    // MARK: Frame

    /// Chart time now, for judging (audio clock minus calibration).
    func judgeTime(host: Double) -> Double {
        AudioEngine.shared.songTime(at: host) - settings.audioOffsetMs / 1000
    }

    /// Called once per display frame by the renderer. Returns the time the
    /// highway should be drawn at.
    @discardableResult
    func frame(host: Double) -> Double {
        if lastFrameHost > 0 {
            let dt = host - lastFrameHost
            if dt > 0.0005 { fps = fps * 0.9 + (1 / dt) * 0.1 }
        }
        if host == lastFrameHost { return now + settings.videoOffsetMs / 1000 }
        lastFrameHost = host
        guard !finished else { return now }

        let events = InputManager.shared.drain()
        if paused {
            if resumeCountdown == nil { navigatePause(events) }
            return now + settings.videoOffsetMs / 1000
        }
        for e in events { apply(e) }
        let t = judgeTime(host: host)
        now = max(now, AudioEngine.shared.smoothSongTime(at: host) - settings.audioOffsetMs / 1000)
        for r in runs {
            r.engine.advance(to: t)
            handleEngineEvents(r)
        }
        updateSection()
        if videoWaiting && now + videoStart >= 0 { syncVideo(playing: true) }

        if practice != nil {
            if now > loopEnd + 0.8 {
                practiceRuns += 1
                seek(to: startTime)
                for r in runs {
                    let acc = r.engine.notesTotal > 0 ? Int(Double(r.engine.notesHit) / Double(r.engine.notesTotal) * 100) : 0
                    r.resetEngine(chart: chart)
                    r.banners.append(Banner(text: "Run \(practiceRuns): \(acc)%", time: startTime))
                }
                mixer.setPaused(false)
                syncVideo(playing: true)
                applyGains()
            }
        } else if !finishQueued, now > endTime || (mixer.duration > 0 && now > mixer.duration + 0.5 && now > (runs.compactMap { $0.track.chords.last?.sustainEndTime }.max() ?? 0) + 0.5) {
            finishQueued = true
            DispatchQueue.main.async { self.finish() }
        }
        return now + settings.videoOffsetMs / 1000
    }

    /// Pause menu: every action bound to one press arrives with the same
    /// timestamp; group them so e.g. Return (strum + confirm) is one intent.
    private func navigatePause(_ events: [ActionEvent]) {
        var groups: [(Double, Set<GameAction>)] = []
        for e in events where e.down {
            if let last = groups.last, last.0 == e.time { groups[groups.count - 1].1.insert(e.action) }
            else { groups.append((e.time, [e.action])) }
        }
        for (_, actions) in groups {
            if actions.contains(.pause) && !actions.contains(.menuBack) {
                DispatchQueue.main.async { self.setPaused(false) }
                return
            }
            guard let nav = MenuNav(actions) else { continue }
            let n = GameSession.pauseItems
            switch nav {
            case .up, .left: DispatchQueue.main.async { self.pauseSelection = (self.pauseSelection + n - 1) % n }
            case .down, .right: DispatchQueue.main.async { self.pauseSelection = (self.pauseSelection + 1) % n }
            case .confirm: DispatchQueue.main.async { self.pauseAction?(self.pauseSelection) }
            case .back: DispatchQueue.main.async { self.setPaused(false) }
            case .pageUp, .pageDown: break
            }
        }
    }

    private func run(for device: String) -> PlayerRun? {
        if runs.count == 1 { return runs[0] }
        if let i = routing.map[device], i < runs.count { return runs[i] }
        if let f = routing.fallback, f < runs.count { return runs[f] }
        return nil
    }

    private func apply(_ e: ActionEvent) {
        if e.action == .pause {
            if e.down { DispatchQueue.main.async { self.setPaused(true) } }
            return
        }
        guard let r = run(for: e.device) else { return }
        let t = judgeTime(host: e.time)
        let engine = r.engine
        switch e.action {
        case .starPower, .tilt:
            if e.down { engine.handle(.starPower, at: t) }
            return
        default: break
        }
        switch r.instrument.kind {
        case .fiveFret, .sixFret:
            switch e.action {
            case .fret1, .fret2, .fret3, .fret4, .fret5, .fret6:
                let idx = [GameAction.fret1, .fret2, .fret3, .fret4, .fret5, .fret6].firstIndex(of: e.action)!
                if r.instrument.kind == .fiveFret && idx > 4 { return }
                engine.handle(.fret(lane: idx, down: e.down), at: t)
            case .strumUp, .strumDown:
                if e.down { engine.handle(.strum, at: t) }
            case .whammy:
                engine.handle(.whammy(e.value), at: t)
            default: break
            }
        case .drums:
            guard e.down else { return }
            let five = r.drumMode == .fiveLane
            var hit: (Int, Bool)?
            switch e.action {
            case .kick: hit = (Lane.kick, false)
            case .padRed: hit = (Lane.drumRed, false)
            case .padYellow: hit = (Lane.drumYellow, false)
            case .padBlue: hit = (Lane.drumBlue, false)
            case .padGreen: hit = five ? (Lane.drum5, false) : (Lane.drum4, false)
            case .padOrange: hit = (Lane.drum4, true)
            case .cymYellow: hit = (Lane.drumYellow, true)
            case .cymBlue: hit = five ? (Lane.drum4, true) : (Lane.drumBlue, true)
            case .cymGreen: hit = (Lane.drum4, true)
            default: break
            }
            if let (lane, cym) = hit { engine.handle(.drum(lane: lane, cymbal: cym, velocity: e.velocity), at: t) }
        }
    }

    private func handleEngineEvents(_ r: PlayerRun) {
        var gainsChanged = false
        for ev in r.engine.drainEvents() {
            switch ev {
            case .hit(let ci, _):
                if r.muted { r.muted = false; gainsChanged = true }
                if r.settings.showHitTiming, ci >= 0, ci < r.track.chords.count {
                    r.hitOffsets.append((now, now - r.track.chords[ci].time))
                    if r.hitOffsets.count > 30 { r.hitOffsets.removeFirst() }
                }
            case .miss, .overstrum:
                r.lastMissTime = now
                if !r.muted { r.muted = true; gainsChanged = true }
                if settings.missSounds { AudioEngine.shared.play(.miss) }
            case .spPhraseComplete:
                AudioEngine.shared.play(.click)
            case .spReady:
                AudioEngine.shared.play(.spReady)
            case .spActivated:
                r.spActivatedAt = now
                AudioEngine.shared.play(.spActivate)
            case .spEnded, .spPhraseBroken, .soloStart:
                break
            case .soloEnd(let hit, let total, let bonus):
                let pct = total > 0 ? hit * 100 / total : 0
                let word = pct == 100 ? "Perfect Solo!" : pct >= 95 ? "Awesome Solo!" : pct >= 90 ? "Great Solo!" : pct >= 80 ? "Good Solo!" : pct >= 70 ? "Solid Solo" : pct >= 60 ? "Okay Solo" : "Messy Solo"
                r.banners.append(Banner(text: word, detail: "\(pct)%  +\(bonus)", time: now, color: .systemYellow))
            case .streak(let n):
                if n % 100 == 0 || n == 50 { r.banners.append(Banner(text: "\(n) Note Streak!", time: now, color: .systemOrange)) }
            }
        }
        r.banners.removeAll { now - $0.time > 2.5 || $0.time - now > 3 }
        if gainsChanged { applyGains() }
    }

    private func updateSection() {
        var idx = -1
        for (i, s) in chart.sections.enumerated() where s.time <= now { idx = i }
        if idx != currentSection {
            currentSection = idx
            if idx >= 0, now > startTime + 0.5 {
                for r in runs { r.banners.append(Banner(text: chart.sections[idx].name, time: now, color: UIColor(white: 0.85, alpha: 1))) }
            }
        }
    }

    // MARK: Render helpers

    var songProgress: Double {
        let total = max(1, endTime - 2.5)
        return min(1, max(0, now / total))
    }
}
