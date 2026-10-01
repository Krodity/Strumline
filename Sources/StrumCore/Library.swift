import Foundation

public let audioExtensions = ["opus", "ogg", "mp3", "wav", "m4a", "aac", "flac", "aiff", "aif"]
public let imageExtensions = ["png", "jpg", "jpeg"]
public let videoExtensions = ["mp4", "m4v", "mov"]

/// One song in the library. Codable so scans can be cached.
public struct SongEntry: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable { case folder, sng }

    public var id: String { path }
    public var path: String
    public var kind: Kind
    public var modified: Double
    public var chartFile: String
    public var chartHash: String

    public var name: String
    public var artist: String
    public var album: String
    public var genre: String
    public var year: String
    public var charter: String
    public var playlist: String
    public var loadingPhrase: String
    public var icon: String
    public var lengthMs: Int
    public var previewStartMs: Int
    public var albumTrack: Int
    public var playlistTrack: Int
    /// song.ini difficulty intensities (0-6, -1 = unknown).
    public var intensities: [String: Int]
    /// Charted parts: instrument raw value -> difficulty raw values.
    public var parts: [String: [Int]]
    public var drumType: DrumType?
    public var albumArt: String?
    public var background: String?
    public var video: String?
    public var hasLyrics: Bool

    public var url: URL { URL(fileURLWithPath: path) }

    public func difficulties(for i: Instrument) -> [Difficulty] {
        (parts[i.rawValue] ?? []).compactMap(Difficulty.init(rawValue:))
    }
    public var instruments: [Instrument] {
        Instrument.allCases.filter { parts[$0.rawValue]?.isEmpty == false }
    }
    public func intensity(_ i: Instrument) -> Int { intensities[i.rawValue] ?? -1 }

    public static func == (a: SongEntry, b: SongEntry) -> Bool { a.path == b.path && a.modified == b.modified }
    public func hash(into h: inout Hasher) { h.combine(path) }
}

/// FNV-1a 64 — stable key for saved scores that survives renames.
func fnv1a(_ data: Data) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
        for byte in b {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
    }
    return String(h, radix: 16)
}

public enum SongLoader {
    public static func package(for entry: SongEntry) throws -> SongPackage {
        switch entry.kind {
        case .folder: return try FolderPackage(url: entry.url)
        case .sng: return try SngPackage(url: entry.url)
        }
    }

    public static func ini(for pkg: SongPackage) -> IniFile {
        if let e = pkg.embeddedIni { return e }
        if let n = pkg.find("song.ini"), let d = try? pkg.data(named: n) { return IniFile(data: d) }
        return IniFile()
    }

    /// Which chart file to read: notes.mid, notes.chart, then any other
    /// .chart/.mid (preferring the ones marked [Y]/[F] for forced notes).
    public static func chartFile(in pkg: SongPackage) -> String? {
        if let n = pkg.find("notes.mid") { return n }
        if let n = pkg.find("notes.chart") { return n }
        let candidates = pkg.fileNames.filter {
            let l = $0.lowercased()
            return l.hasSuffix(".chart") || l.hasSuffix(".mid")
        }
        func score(_ n: String) -> Int {
            let l = n.lowercased()
            if l.contains("[y]") || l.contains("[f]") || l.contains("(y)") || l.contains("(f)") { return 0 }
            if l.contains("[n]") || l.contains("(n)") { return 2 }
            return 1
        }
        return candidates.sorted { (score($0), $0) < (score($1), $1) }.first
    }

    public static func loadChart(pkg: SongPackage, file: String, ini: IniFile) throws -> SongChart {
        let data = try pkg.data(named: file)
        if file.lowercased().hasSuffix(".mid") || file.lowercased().hasSuffix(".midi") {
            return try MidiChartParser.parse(data, ini: ini)
        }
        return try DotChartParser.parse(data, ini: ini)
    }

    public static func loadChart(entry: SongEntry) throws -> (SongChart, SongPackage, IniFile) {
        let pkg = try package(for: entry)
        let ini = ini(for: pkg)
        return (try loadChart(pkg: pkg, file: entry.chartFile, ini: ini), pkg, ini)
    }

    /// Audio stems present in the package, by role.
    public static func stems(in pkg: SongPackage) -> [StemRole: String] {
        var out: [StemRole: String] = [:]
        for role in StemRole.allCases {
            if let n = pkg.find(base: role.fileBase, extensions: audioExtensions) { out[role] = n }
        }
        // Numbered stems replace the single-stem versions.
        if out.keys.contains(where: { [.drums1, .drums2, .drums3, .drums4].contains($0) }) { out[.drums] = nil }
        if out[.vocals1] != nil || out[.vocals2] != nil { out[.vocals] = nil }
        // Charts that name their audio in the .chart but use other file names.
        if out.isEmpty || (out.count == 1 && out[.preview] != nil) {
            let others = pkg.fileNames.filter { n in audioExtensions.contains { n.lowercased().hasSuffix("." + $0) } && !n.lowercased().hasPrefix("preview.") }
            if let first = others.sorted().first { out[.song] = first }
        }
        return out
    }

    static func chartSongField(_ data: Data, _ key: String) -> String? {
        // Only the start of the file is needed, but cutting mid-character
        // would fail UTF-8 and fall back to CP1252 (mojibake): end the sample
        // at its last full line.
        var head = data.prefix(8192)
        if head.count < data.count, let nl = head.lastIndex(of: 0x0A) { head = head[..<nl] }
        let text = TextDecoding.decode(head)
        guard let r = text.range(of: "[Song]") else { return nil }
        for line in text[r.upperBound...].split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l == "}" { break }
            guard let eq = l.firstIndex(of: "=") else { continue }
            if l[..<eq].trimmingCharacters(in: .whitespaces) == key {
                var v = l[l.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 { v = String(v.dropFirst().dropLast()) }
                if v.hasPrefix(", ") { v = String(v.dropFirst(2)) }
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    /// Reads and fully parses one song for the library.
    public static func makeEntry(pkg: SongPackage, path: String, kind: SongEntry.Kind, modified: Double, folderName: String) throws -> SongEntry {
        guard let chartFile = chartFile(in: pkg) else { throw ChartError.invalid("No chart file") }
        let ini = ini(for: pkg)
        let data = try pkg.data(named: chartFile)
        let isMid = chartFile.lowercased().hasSuffix(".mid")
        let chart = isMid ? try MidiChartParser.parse(data, ini: ini) : try DotChartParser.parse(data, ini: ini)

        func chartField(_ k: String) -> String? { isMid ? nil : chartSongField(data, k) }
        var intensities: [String: Int] = [:]
        for i in Instrument.allCases { if let v = ini.int(i.iniDifficultyKey) { intensities[i.rawValue] = v } }
        var parts: [String: [Int]] = [:]
        for (i, ds) in chart.availableParts { parts[i.rawValue] = ds.map(\.rawValue) }
        let stems = stems(in: pkg)
        var length = ini.int("song_length") ?? 0
        if length <= 0 { length = Int((max(chart.lastNoteTime, chart.endEventTime ?? 0) + 2) * 1000) }
        let preview = ini.int("preview_start_time") ?? chartField("PreviewStart").flatMap(Double.init).map { Int($0 * 1000) } ?? -1

        let bg = ini.string("background").flatMap { pkg.find($0.lowercased()) } ?? pkg.find(base: "background", extensions: imageExtensions)
        let video = ini.string("video").flatMap { pkg.find($0.lowercased()) } ?? pkg.find(base: "video", extensions: videoExtensions)
        let art = ini.string("cover").flatMap { pkg.find($0.lowercased()) } ?? pkg.find(base: "album", extensions: imageExtensions)

        if stems.isEmpty { throw ChartError.invalid("No audio") }
        return SongEntry(
            path: path, kind: kind, modified: modified, chartFile: chartFile, chartHash: fnv1a(data),
            name: ini.string("name") ?? chartField("Name") ?? folderName,
            artist: ini.string("artist") ?? chartField("Artist") ?? "Unknown Artist",
            album: ini.string("album") ?? chartField("Album") ?? "",
            genre: ini.string("genre") ?? chartField("Genre") ?? "",
            year: (ini.string("year") ?? chartField("Year") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ", ")),
            charter: ini.string("charter", "frets") ?? chartField("Charter") ?? "",
            playlist: ini.string("playlist") ?? "",
            loadingPhrase: ini.string("loading_phrase") ?? "",
            icon: ini.string("icon") ?? "",
            lengthMs: length, previewStartMs: preview,
            albumTrack: ini.int("album_track", "track") ?? 0,
            playlistTrack: ini.int("playlist_track") ?? 0,
            intensities: intensities, parts: parts,
            drumType: chart.track(.drums, .expert)?.drumType ?? chart.tracks.first(where: { $0.key.instrument == .drums })?.value.drumType,
            albumArt: art, background: bg, video: video, hasLyrics: !chart.lyrics.isEmpty
        )
    }
}

/// Walks song folders; reuses cached entries whose modification time matches.
public enum LibraryScanner {
    public struct Result: Sendable {
        public var songs: [SongEntry]
        public var errors: [String]
    }

    /// `roots` may be folders or individual `.sng` files (linked from the
    /// Files app). `onPlaceholder` receives iCloud files that are not on the
    /// device yet (`.name.icloud`) so the app can ask for them to download.
    public static func scan(roots: [URL], cache: [String: SongEntry], progress: (@Sendable (Int, String) -> Void)? = nil, onPlaceholder: ((URL) -> Void)? = nil, onSong: ((SongEntry) -> Void)? = nil) -> Result {
        var songs: [SongEntry] = []
        var errors: [String] = []
        let fm = FileManager.default
        var seen = Set<String>()
        func add(_ e: SongEntry) {
            songs.append(e)
            onSong?(e)
        }

        func modTime(_ url: URL, _ names: [String]) -> Double {
            // A folder's mtime doesn't change when a file inside is replaced,
            // so combine the chart and ini times too.
            var t = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            for n in names {
                let l = n.lowercased()
                if l.hasSuffix(".chart") || l.hasSuffix(".mid") || l == "song.ini" {
                    t += (try? fm.attributesOfItem(atPath: url.appendingPathComponent(n).path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                }
            }
            return t
        }

        func visit(_ dir: URL, depth: Int) {
            guard depth < 12, let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            let path = dir.standardizedFileURL.path
            guard seen.insert(path).inserted else { return }
            let lower = names.map { $0.lowercased() }
            let isSong = lower.contains { $0.hasSuffix(".chart") || $0.hasSuffix(".mid") }
                && lower.contains { l in audioExtensions.contains { l.hasSuffix("." + $0) } }
            if isSong {
                let m = modTime(dir, names)
                if let c = cache[path], c.modified == m {
                    add(c)
                } else {
                    do {
                        let e = try SongLoader.makeEntry(pkg: FolderPackage(url: dir, fileNames: names), path: path, kind: .folder, modified: m, folderName: dir.lastPathComponent)
                        add(e)
                    } catch {
                        errors.append("\(dir.lastPathComponent): \(error)")
                    }
                }
                progress?(songs.count, dir.lastPathComponent)
            }
            for n in names where n.hasPrefix(".") && n.hasSuffix(".icloud") {
                // ".song.ini.icloud" -> "song.ini"
                let real = String(n.dropFirst().dropLast(7))
                onPlaceholder?(dir.appendingPathComponent(real))
            }
            for n in names.sorted() where !n.hasPrefix(".") {
                let u = dir.appendingPathComponent(n)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    visit(u, depth: depth + 1)
                } else if n.lowercased().hasSuffix(".sng") {
                    visitSng(u)
                }
            }
        }
        func visitSng(_ u: URL) {
            let n = u.lastPathComponent
            let p = u.standardizedFileURL.path
            guard seen.insert(p).inserted else { return }
            let m = (try? fm.attributesOfItem(atPath: p)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            if let c = cache[p], c.modified == m { add(c); return }
            do {
                let e = try SongLoader.makeEntry(pkg: SngPackage(url: u), path: p, kind: .sng, modified: m, folderName: (n as NSString).deletingPathExtension)
                add(e)
            } catch {
                errors.append("\(n): \(error)")
            }
            progress?(songs.count, n)
        }
        for r in roots {
            if r.pathExtension.lowercased() == "sng" { visitSng(r) } else { visit(r, depth: 0) }
        }
        return Result(songs: songs, errors: errors)
    }
}
