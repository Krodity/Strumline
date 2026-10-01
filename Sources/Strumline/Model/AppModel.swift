import Foundation
import SwiftUI
import os
import StrumCore

let log = Logger(subsystem: "uk.krodity.strumline", category: "app")

/// A folder or .sng file the user linked from the Files app. Read in place
/// through a security-scoped bookmark; nothing is copied.
struct LinkedLocation: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var bookmark: Data
    var isFile: Bool
    /// Where the bookmark resolved last time; if it moves (a USB drive
    /// remounts elsewhere), cached song paths are rewritten, not rescanned.
    var lastPath: String?
}

struct ScoreRecord: Codable {
    var score: Int
    var stars: Int
    var accuracy: Double
    var fullCombo: Bool
    var bestStreak: Int
    var date: Date
    var speed: Double
    var plays: Int
}

enum Screen: Equatable {
    case menu
    case songs(practice: Bool)
    case play
    case results
    case settings
    case controls
    case library
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = GameSettings.load() {
        didSet {
            settings.save()
            AudioEngine.shared.sfxVolume = Float(settings.sfxVolume)
        }
    }
    @Published var screen: Screen = .menu
    @Published private(set) var songs: [SongEntry] = []
    @Published private(set) var scanning = false
    @Published private(set) var scanStatus = ""
    @Published private(set) var scanErrors: [String] = []
    @Published private(set) var pendingDownloads = 0
    @Published var locations: [LinkedLocation] = [] {
        didSet { saveLocations() }
    }
    @Published private(set) var scores: [String: ScoreRecord] = [:]
    @Published var session: GameSession?
    @Published var lastResult: GameResult?
    @Published var selectedSong: SongEntry?
    @Published var playError: String?
    @Published var players: [PlayerProfile] = [PlayerProfile(name: "Player 1")] {
        didSet {
            if players.isEmpty { players = [PlayerProfile(name: "Player 1")] }
            if let d = try? JSONEncoder().encode(players) { UserDefaults.standard.set(d, forKey: "players.v1") }
        }
    }
    @Published var lastResults: [GameResult] = []
    /// Controller focus on the bottom player bar (slot index), and a request
    /// to open a slot's settings.
    @Published var playerBarFocus: Int?
    @Published var playerBarOpen: Int?

    private var accessed: [URL] = []
    let preview = PreviewPlayer()

    nonisolated static let songsDir: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Songs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let readme = d.appendingPathComponent("Put songs here.txt")
        if !FileManager.default.fileExists(atPath: readme.path) {
            try? """
            Copy song folders (song.ini + notes.chart/notes.mid + audio) or .sng files into this folder, \
            then pull down on the song list in Strumline to rescan.

            To play songs that live somewhere else (iCloud Drive, a USB drive, another app's folder) without \
            copying them, use Library → Link Folder in the app.
            """.write(to: readme, atomically: true, encoding: .utf8)
        }
        return d
    }()

    nonisolated static var supportDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    nonisolated static var cacheFile: URL { supportDir.appendingPathComponent("library-cache.json") }
    nonisolated static var scoresFile: URL { supportDir.appendingPathComponent("scores.json") }
    nonisolated static var bundledSongs: URL? { Bundle.module.url(forResource: "Songs", withExtension: nil, subdirectory: "Resources") }

    init() {
        _ = AudioEngine.shared
        _ = InputManager.shared
        AudioEngine.shared.sfxVolume = Float(settings.sfxVolume)
        if let d = UserDefaults.standard.data(forKey: "locations.v1"), let l = try? JSONDecoder().decode([LinkedLocation].self, from: d) {
            locations = l
        }
        if let d = try? Data(contentsOf: AppModel.scoresFile), let s = try? JSONDecoder().decode([String: ScoreRecord].self, from: d) {
            scores = s
        }
        if let d = UserDefaults.standard.data(forKey: "players.v1"), let p = try? JSONDecoder().decode([PlayerProfile].self, from: d), !p.isEmpty {
            players = p
        }
        InputManager.shared.joinHandler = { [weak self] device in
            MainActor.assumeIsolated { self?.join(device: device) ?? false }
        }
        // The library is scanned once and kept on the device; it is only
        // rescanned when asked (Rescan / pull to refresh). New links scan
        // just the new location.
        if let d = try? Data(contentsOf: AppModel.cacheFile), let c = try? JSONDecoder().decode([SongEntry].self, from: d) {
            songs = c
        }
        rebaseAppPaths()
        _ = resolveRoots()
        if songs.isEmpty { rescan() } else { scanStatus = "\(songs.count) songs" }
    }

    /// The app's own container path changes on reinstall/update, so cached
    /// paths into the bundle or Documents/Songs are rebased, not rescanned.
    private func rebaseAppPaths() {
        var changed = false
        let anchors: [(String, URL?)] = [("/Strumline_Strumline.bundle/Resources/Songs", AppModel.bundledSongs), ("/Documents/Songs", AppModel.songsDir)]
        songs = songs.map { e in
            for (marker, base) in anchors {
                guard let base, let r = e.path.range(of: marker) else { continue }
                let fixed = base.standardizedFileURL.path + e.path[r.upperBound...]
                if fixed != e.path { var m = e; m.path = fixed; changed = true; return m }
            }
            return e
        }
        if changed { saveCache() }
    }

    private func saveLocations() {
        if let d = try? JSONEncoder().encode(locations) { UserDefaults.standard.set(d, forKey: "locations.v1") }
    }

    // MARK: Library

    func link(urls: [URL]) {
        var added: [LinkedLocation] = []
        for url in urls {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            guard let bm = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { continue }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if locations.contains(where: { $0.lastPath == url.standardizedFileURL.path }) { continue }
            let loc = LinkedLocation(name: url.lastPathComponent, bookmark: bm, isFile: !isDir.boolValue, lastPath: url.standardizedFileURL.path)
            locations.append(loc)
            added.append(loc)
        }
        _ = resolveRoots()
        let newRoots = added.compactMap { resolve($0) }
        if !newRoots.isEmpty { scan(roots: newRoots, mode: .add) }
    }

    func unlink(_ loc: LinkedLocation) {
        let root = resolve(loc)?.standardizedFileURL.path ?? loc.lastPath
        locations.removeAll { $0.id == loc.id }
        if let root {
            songs.removeAll { $0.path == root || $0.path.hasPrefix(root + "/") }
            saveCache()
        }
        _ = resolveRoots()
    }

    private func resolve(_ loc: LinkedLocation) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: loc.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    private func saveCache() {
        let list = songs
        Task.detached(priority: .utility) {
            if let d = try? JSONEncoder().encode(list) { try? d.write(to: AppModel.cacheFile, options: .atomic) }
        }
    }

    /// Resolves bookmarks and keeps their security scope open for the app's
    /// lifetime, so songs inside can be read at any time.
    private func resolveRoots() -> [URL] {
        for u in accessed { u.stopAccessingSecurityScopedResource() }
        accessed = []
        var roots: [URL] = []
        if let b = AppModel.bundledSongs { roots.append(b) }
        roots.append(AppModel.songsDir)
        var updated = locations
        for (i, loc) in locations.enumerated() {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: loc.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            if url.startAccessingSecurityScopedResource() { accessed.append(url) }
            if stale, let bm = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                updated[i].bookmark = bm
            }
            let now = url.standardizedFileURL.path
            if let old = loc.lastPath, old != now {
                // Same location, new mount path: rewrite cached song paths.
                songs = songs.map { e in
                    guard e.path == old || e.path.hasPrefix(old + "/") else { return e }
                    var m = e
                    m.path = now + e.path.dropFirst(old.count)
                    return m
                }
                saveCache()
            }
            updated[i].lastPath = now
            roots.append(url)
        }
        if updated != locations { locations = updated }
        return roots
    }

    /// Songs found by the running scan, waiting to be merged into `songs`.
    private nonisolated let inbox = SongInbox()
    private var flushTimer: Timer?

    enum ScanMode {
        /// Every location; unchanged songs are reused from the cache.
        case refresh
        /// Every location, re-reading every chart.
        case rebuild
        /// Only the given roots, merged into the existing list.
        case add
    }

    /// Manual rescan (Rescan button, pull to refresh).
    func rescan() { scan(roots: resolveRoots(), mode: .refresh) }

    /// Manual full rebuild, ignoring the cache.
    func rebuildLibrary() { scan(roots: resolveRoots(), mode: .rebuild) }

    func scan(roots: [URL], mode: ScanMode) {
        guard !scanning else { return }
        scanning = true
        scanStatus = "Scanning…"
        var cache: [String: SongEntry] = [:]
        if mode != .rebuild { for s in songs { cache[s.path] = s } }
        if mode == .rebuild { songs = [] }
        // Merge newly found songs into the visible list a few times a second.
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushIncoming() }
        }
        let inbox = self.inbox
        Task.detached(priority: .userInitiated) { [weak self] in
            var placeholders: [URL] = []
            let result = LibraryScanner.scan(roots: roots, cache: cache, progress: { n, name in
                Task { @MainActor [weak self] in self?.scanStatus = "\(n) songs · \(name)" }
            }, onPlaceholder: { placeholders.append($0) }, onSong: { inbox.add($0) })
            // iCloud files that aren't on the device yet: ask for them, then
            // scan just those folders once they've had time to arrive.
            for p in placeholders { try? FileManager.default.startDownloadingUbiquitousItem(at: p) }
            await MainActor.run {
                guard let self else { return }
                self.flushTimer?.invalidate()
                self.flushTimer = nil
                self.flushIncoming()
                if mode != .add {
                    // Full scans also drop songs that were deleted.
                    self.songs = result.songs
                    self.scanErrors = result.errors
                } else {
                    self.scanErrors = result.errors + self.scanErrors
                }
                self.saveCache()
                self.pendingDownloads = placeholders.count
                self.scanning = false
                self.scanStatus = "\(self.songs.count) songs"
                if !placeholders.isEmpty {
                    let dirs = Array(Set(placeholders.map { $0.deletingLastPathComponent() }))
                    self.scanAfterDownloads(dirs)
                }
            }
        }
    }

    private func flushIncoming() {
        let batch = inbox.take()
        guard !batch.isEmpty else { return }
        var list = songs
        var index: [String: Int] = [:]
        for (i, s) in list.enumerated() { index[s.path] = i }
        for e in batch {
            if let i = index[e.path] { list[i] = e } else { index[e.path] = list.count; list.append(e) }
        }
        songs = list
    }

    private func scanAfterDownloads(_ dirs: [URL]) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if pendingDownloads > 0 { scan(roots: dirs, mode: .add) }
        }
    }

    func sortedSongs(filter: String) -> [SongEntry] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        var list = songs
        if !q.isEmpty {
            list = list.filter { s in
                [s.name, s.artist, s.album, s.genre, s.charter, s.year].contains { $0.lowercased().contains(q) }
            }
        }
        func k(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "the ", with: "", options: .anchored) }
        switch settings.sort {
        case .title: list.sort { k($0.name) < k($1.name) }
        case .artist: list.sort { (k($0.artist), k($0.name)) < (k($1.artist), k($1.name)) }
        case .album: list.sort { (k($0.album), $0.albumTrack, k($0.name)) < (k($1.album), $1.albumTrack, k($1.name)) }
        case .genre: list.sort { (k($0.genre), k($0.artist), k($0.name)) < (k($1.genre), k($1.artist), k($1.name)) }
        case .year: list.sort { ($0.year, k($0.artist)) < ($1.year, k($1.artist)) }
        case .charter: list.sort { (k($0.charter), k($0.name)) < (k($1.charter), k($1.name)) }
        case .length: list.sort { $0.lengthMs < $1.lengthMs }
        case .playlist: list.sort { (k(folderName($0)), $0.playlistTrack, k($0.name)) < (k(folderName($1)), $1.playlistTrack, k($1.name)) }
        case .recent: list.sort { $0.modified > $1.modified }
        }
        return list
    }

    func groupTitle(_ s: SongEntry) -> String {
        switch settings.sort {
        case .title: return String(s.name.prefix(1)).uppercased()
        case .artist: return String(s.artist.prefix(1)).uppercased()
        case .album: return s.album.isEmpty ? "Unknown Album" : s.album
        case .genre: return s.genre.isEmpty ? "Unknown Genre" : s.genre
        case .year: return s.year.isEmpty ? "Unknown Year" : s.year
        case .charter: return s.charter.isEmpty ? "Unknown Charter" : s.charter
        case .length: return "\(s.lengthMs / 60000):00+"
        case .playlist: return folderName(s)
        case .recent: return ""
        }
    }

    func folderName(_ s: SongEntry) -> String {
        if !s.playlist.isEmpty { return s.playlist }
        let parent = s.url.deletingLastPathComponent()
        return parent.lastPathComponent
    }

    // MARK: Scores

    func scoreKey(_ s: SongEntry, _ i: Instrument, _ d: Difficulty) -> String { "\(s.chartHash)|\(i.rawValue)|\(d.rawValue)" }

    func best(_ s: SongEntry, _ i: Instrument, _ d: Difficulty) -> ScoreRecord? { scores[scoreKey(s, i, d)] }

    /// Returns true for a new high score.
    func record(_ r: GameResult) -> Bool {
        let key = scoreKey(r.song, r.instrument, r.difficulty)
        var rec = scores[key]
        let plays = (rec?.plays ?? 0) + 1
        var isBest = false
        if rec == nil || r.stats.score > rec!.score {
            rec = ScoreRecord(score: r.stats.score, stars: r.stats.stars, accuracy: r.stats.accuracy, fullCombo: r.stats.fullCombo, bestStreak: r.stats.bestStreak, date: Date(), speed: r.modifiers.songSpeed, plays: plays)
            isBest = true
        } else {
            rec!.plays = plays
            rec!.fullCombo = rec!.fullCombo || r.stats.fullCombo
        }
        scores[key] = rec
        if let d = try? JSONEncoder().encode(scores) { try? d.write(to: AppModel.scoresFile) }
        return isBest
    }

    // MARK: Navigation

    private var lastPlay: (SongEntry, Instrument, Difficulty, PracticeRange?)?

    /// Rebuilds the session so changed settings take effect.
    func restartCurrent() {
        guard let (s, i, d, p) = lastPlay else { return }
        session?.quitSilently()
        play(song: s, instrument: i, difficulty: d, practice: p)
    }

    func play(song: SongEntry, instrument: Instrument, difficulty: Difficulty, practice: PracticeRange?) {
        lastPlay = (song, instrument, difficulty, practice)
        log.info("play \(song.name, privacy: .public) \(instrument.rawValue, privacy: .public)/\(difficulty.displayName, privacy: .public) practice=\(practice != nil)")
        preview.stop()
        settings.lastInstrument = instrument
        settings.lastDifficulty = difficulty
        do {
            let setups = players.indices.map { i in
                PlayerSetup(name: players[i].name,
                            instrument: i == 0 ? instrument : players[i].instrument,
                            difficulty: i == 0 ? difficulty : players[i].difficulty,
                            settings: settings(forPlayer: i))
            }
            let s = try GameSession(song: song, players: setups, settings: settings, routing: deviceRouting(), practice: practice)
            s.onFinish = { [weak self] results in
                guard let self else { return }
                var out: [GameResult] = []
                for var r in results {
                    if practice == nil && !r.modifiers.disablesScoreSaving { r.newBest = record(r) }
                    out.append(r)
                }
                lastResults = out
                lastResult = out.first
                session = nil
                screen = .results
            }
            s.onQuit = { [weak self] in
                self?.session = nil
                self?.screen = .songs(practice: practice != nil)
            }
            session = s
            screen = .play
            s.start()
        } catch {
            log.error("play failed for \(song.name, privacy: .public): \(String(describing: error), privacy: .public)")
            playError = "\(song.name): \(error)"
            scanErrors.insert("\(song.name): \(error)", at: 0)
        }
    }
}

/// Songs found by a background scan, handed to the main actor in batches.
final class SongInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SongEntry] = []
    func add(_ e: SongEntry) { lock.lock(); items.append(e); lock.unlock() }
    func take() -> [SongEntry] {
        lock.lock(); defer { items.removeAll(); lock.unlock() }
        return items
    }
}
