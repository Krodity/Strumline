import Foundation

/// A song's files, whether they sit in a folder or inside a `.sng` container.
public protocol SongPackage: Sendable {
    /// Lower-cased file name -> real name.
    var fileNames: [String] { get }
    func data(named name: String) throws -> Data
    /// A URL a system media API can open directly (folder songs only).
    func directURL(named name: String) -> URL?
    /// Extra metadata that stands in for song.ini (.sng keeps it in its header).
    var embeddedIni: IniFile? { get }
}

extension SongPackage {
    public func find(_ lowerName: String) -> String? {
        fileNames.first { $0.lowercased() == lowerName }
    }
    public func find(base: String, extensions: [String]) -> String? {
        for ext in extensions { if let n = find(base + "." + ext) { return n } }
        return nil
    }
}

public struct FolderPackage: SongPackage {
    public let url: URL
    public let fileNames: [String]
    public var embeddedIni: IniFile? { nil }

    public init(url: URL) throws {
        self.url = url
        fileNames = try FileManager.default.contentsOfDirectory(atPath: url.path)
    }
    public init(url: URL, fileNames: [String]) {
        self.url = url
        self.fileNames = fileNames
    }
    public func data(named name: String) throws -> Data {
        try Data(contentsOf: url.appendingPathComponent(name), options: .mappedIfSafe)
    }
    public func directURL(named name: String) -> URL? { url.appendingPathComponent(name) }
}

/// `.sng` container (https://github.com/mdsitton/SngFileFormat).
public struct SngPackage: SongPackage {
    struct Entry: Sendable { var name: String; var length: Int; var offset: Int }
    public let url: URL
    let mask: [UInt8]
    let entries: [Entry]
    public let metadata: [String: String]

    public var fileNames: [String] { entries.map(\.name) }
    public var embeddedIni: IniFile? {
        var v: [String: String] = [:]
        for (k, val) in metadata { v[k.lowercased()] = val }
        return IniFile(values: v)
    }
    public func directURL(named name: String) -> URL? { nil }

    public init(url: URL) throws {
        self.url = url
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let header = try fh.read(upToCount: 26) ?? Data()
        guard header.count == 26, Array(header.prefix(6)) == Array("SNGPKG".utf8) else { throw ChartError.invalid("Not an .sng file") }
        mask = Array(header[10..<26])

        func u64(_ d: Data, _ at: Int) -> Int {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(d[d.startIndex + at + i]) << (8 * UInt64(i)) }
            return Int(truncatingIfNeeded: v)
        }
        func i32(_ d: Data, _ at: Int) -> Int {
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(d[d.startIndex + at + i]) << (8 * UInt32(i)) }
            return Int(Int32(bitPattern: v))
        }

        guard let lenD = try fh.read(upToCount: 8), lenD.count == 8 else { throw ChartError.invalid("Truncated .sng") }
        let metaLen = u64(lenD, 0)
        guard metaLen >= 8, metaLen < 16 << 20, let meta = try fh.read(upToCount: metaLen), meta.count == metaLen else { throw ChartError.invalid("Bad .sng metadata") }
        var md: [String: String] = [:]
        let count = u64(meta, 0)
        var p = 8
        for _ in 0..<max(0, count) {
            guard p + 4 <= meta.count else { break }
            let kl = i32(meta, p); p += 4
            guard kl >= 0, p + kl + 4 <= meta.count else { break }
            let k = String(decoding: meta[meta.startIndex + p ..< meta.startIndex + p + kl], as: UTF8.self); p += kl
            let vl = i32(meta, p); p += 4
            guard vl >= 0, p + vl <= meta.count else { break }
            let v = String(decoding: meta[meta.startIndex + p ..< meta.startIndex + p + vl], as: UTF8.self); p += vl
            md[k] = v
        }
        metadata = md

        guard let idxLenD = try fh.read(upToCount: 8), idxLenD.count == 8 else { throw ChartError.invalid("Truncated .sng") }
        let idxLen = u64(idxLenD, 0)
        guard idxLen >= 8, idxLen < 16 << 20, let idx = try fh.read(upToCount: idxLen), idx.count == idxLen else { throw ChartError.invalid("Bad .sng index") }
        var entries: [Entry] = []
        let fcount = u64(idx, 0)
        p = 8
        for _ in 0..<max(0, fcount) {
            guard p + 1 <= idx.count else { break }
            let nl = Int(idx[idx.startIndex + p]); p += 1
            guard p + nl + 16 <= idx.count else { break }
            let name = String(decoding: idx[idx.startIndex + p ..< idx.startIndex + p + nl], as: UTF8.self); p += nl
            let len = u64(idx, p); p += 8
            let off = u64(idx, p); p += 8
            entries.append(Entry(name: name, length: len, offset: off))
        }
        self.entries = entries
    }

    public func data(named name: String) throws -> Data {
        guard let e = entries.first(where: { $0.name == name }) else { throw ChartError.invalid("\(name) not in .sng") }
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        try fh.seek(toOffset: UInt64(e.offset))
        guard var d = try fh.read(upToCount: e.length), d.count == e.length else { throw ChartError.invalid("Truncated .sng entry") }
        d.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            let b = buf.bindMemory(to: UInt8.self)
            for i in 0..<b.count {
                b[i] ^= mask[i & 15] ^ UInt8(truncatingIfNeeded: i)
            }
        }
        return d
    }
}
