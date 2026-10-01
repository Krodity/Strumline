import Foundation

/// A host's song, ready to send: what's offered and how to read it.
public struct NetSongSource: Sendable {
    public var offer: NetSongOffer
    /// Reads `length` bytes of file `index` from `offset` (nil if it can't).
    public var read: @Sendable (_ index: Int, _ offset: Int64, _ length: Int) -> Data?

    public init(offer: NetSongOffer, read: @escaping @Sendable (Int, Int64, Int) -> Data?) {
        self.offer = offer
        self.read = read
    }

    /// What a host sends for a library song: a .sng as-is, or a folder's
    /// chart, song.ini, audio stems (not preview.*) and album art.
    public static func make(for entry: SongEntry) -> NetSongSource? {
        let song = NetSong(chartHash: entry.chartHash, name: entry.name, artist: entry.artist, lengthMs: entry.lengthMs)
        switch entry.kind {
        case .sng:
            guard let data = try? Data(contentsOf: entry.url, options: .mappedIfSafe) else { return nil }
            let offer = NetSongOffer(song: song, files: [.init(name: entry.url.lastPathComponent, size: Int64(data.count))], isSng: true)
            return NetSongSource(offer: offer) { _, off, len in slice(data, off, len) }
        case .folder:
            guard let pkg = try? FolderPackage(url: entry.url) else { return nil }
            var names = [entry.chartFile]
            if let ini = pkg.find("song.ini") { names.append(ini) }
            names += SongLoader.stems(in: pkg).filter { $0.key != .preview }.map(\.value).sorted()
            if let art = entry.albumArt { names.append(art) }
            var files: [NetSongOffer.File] = []
            var datas: [Data] = []
            for n in names where !files.contains(where: { $0.name == n }) && NetSongOffer.isSafeName(n) {
                guard let d = try? pkg.data(named: n) else { continue }  // memory-mapped
                files.append(.init(name: n, size: Int64(d.count)))
                datas.append(d)
            }
            guard files.contains(where: { $0.name == entry.chartFile }) else { return nil }
            let offer = NetSongOffer(song: song, files: files, isSng: false)
            let contents = datas  // immutable copy for the @Sendable reader
            return NetSongSource(offer: offer) { i, off, len in i < contents.count ? slice(contents[i], off, len) : nil }
        }
    }

    private static func slice(_ d: Data, _ off: Int64, _ len: Int) -> Data? {
        let o = Int(off)
        guard o >= 0, len >= 0, o + len <= d.count else { return nil }
        return d.subdata(in: (d.startIndex + o)..<(d.startIndex + o + len))
    }
}

/// Receives a song a host sends, into a session cache folder (never the
/// library). Files must arrive in order; sizes and the chart hash are
/// checked before the song is used.
public final class NetSongReceiver {
    public let offer: NetSongOffer
    public let folder: URL
    public private(set) var received: Int64 = 0
    public private(set) var done = false
    private var file = 0
    private var offset: Int64 = 0
    private var handle: FileHandle?

    public enum Failure: Error, CustomStringConvertible {
        case outOfOrder, tooMuch, badSong(String)
        public var description: String {
            switch self {
            case .outOfOrder: return "Song data arrived out of order"
            case .tooMuch: return "More data than the song's size"
            case .badSong(let s): return "The song didn't check out: \(s)"
            }
        }
    }

    /// Why a guest should refuse an offer, or nil if it's fine.
    public static func problem(with o: NetSongOffer) -> String? {
        if o.files.isEmpty { return "No files" }
        if o.files.count > Net.maxSongFiles { return "Too many files" }
        if o.totalBytes > Net.maxSongBytes { return "Too big (\(o.totalBytes / 1_000_000) MB)" }
        if o.files.contains(where: { !NetSongOffer.isSafeName($0.name) || $0.size < 0 }) { return "Unsafe file name" }
        if Set(o.files.map(\.name)).count != o.files.count { return "Duplicate file names" }
        if o.song.chartHash.isEmpty || !o.song.chartHash.allSatisfy({ $0.isHexDigit }) { return "Bad song id" }
        return nil
    }

    /// Clears `cache` (one received song at a time) and prepares the folder.
    public init(offer: NetSongOffer, cache: URL) throws {
        self.offer = offer
        let fm = FileManager.default
        try? fm.removeItem(at: cache)
        folder = cache.appendingPathComponent(offer.song.chartHash, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try openCurrent()
    }

    private func openCurrent() throws {
        try? handle?.close()
        handle = nil
        // Zero-length files have nothing to wait for.
        while file < offer.files.count {
            let url = folder.appendingPathComponent(offer.files[file].name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            if offer.files[file].size > 0 { handle = try FileHandle(forWritingTo: url); return }
            file += 1
        }
    }

    /// Writes a chunk. Returns the song once the last byte has arrived and
    /// it checked out; throws if anything is wrong.
    public func write(_ c: NetChunk) throws -> SongEntry? {
        guard !done else { return nil }
        guard c.file == file, c.offset == offset, let h = handle else { throw Failure.outOfOrder }
        let size = offer.files[file].size
        guard offset + Int64(c.bytes.count) <= size else { throw Failure.tooMuch }
        try h.write(contentsOf: c.bytes)
        offset += Int64(c.bytes.count)
        received += Int64(c.bytes.count)
        if offset == size {
            file += 1
            offset = 0
            try openCurrent()
        }
        guard file >= offer.files.count else { return nil }
        done = true
        return try verify()
    }

    /// Loads what arrived like any other song and checks it is the song
    /// that was offered (same chart hash).
    private func verify() throws -> SongEntry {
        do {
            let entry: SongEntry
            if offer.isSng {
                let u = folder.appendingPathComponent(offer.files[0].name)
                entry = try SongLoader.makeEntry(pkg: SngPackage(url: u), path: u.path, kind: .sng, modified: 0, folderName: offer.song.name)
            } else {
                entry = try SongLoader.makeEntry(pkg: FolderPackage(url: folder), path: folder.path, kind: .folder, modified: 0, folderName: offer.song.name)
            }
            guard entry.chartHash == offer.song.chartHash else { throw Failure.badSong("chart doesn't match") }
            return entry
        } catch let f as Failure {
            cancel(); throw f
        } catch {
            cancel(); throw Failure.badSong("\(error)")
        }
    }

    /// Stops and deletes what arrived.
    public func cancel() {
        try? handle?.close()
        handle = nil
        done = true
        try? FileManager.default.removeItem(at: folder)
    }
}
