import Foundation
import CStbVorbis
import COpus

/// Pull-style PCM source. Output is interleaved Float32 with `channels`
/// channels at `sampleRate`.
public protocol AudioDecoder: AnyObject {
    var sampleRate: Double { get }
    var channels: Int { get }
    var lengthFrames: Int? { get }
    /// Decodes up to `frames` frames; returns 0 at end of stream.
    func read(_ out: UnsafeMutablePointer<Float>, frames: Int) -> Int
    func seek(toFrame frame: Int)
}

public enum AudioDecoders {
    /// Set by the app for formats handled by the OS (mp3, m4a, …).
    nonisolated(unsafe) public static var platformFactory: ((SongPackage, String) -> AudioDecoder?)?

    public static func open(pkg: SongPackage, name: String) -> AudioDecoder? {
        if let d = try? pkg.data(named: name), let dec = open(data: d) { return dec }
        return platformFactory?(pkg, name)
    }

    /// Ogg Vorbis, Ogg Opus and WAV, recognised by content rather than name
    /// (plenty of `.ogg` stems are really Opus).
    public static func open(data: Data) -> AudioDecoder? {
        guard data.count > 64 else { return nil }
        let head = [UInt8](data.prefix(64))
        if head[0] == 0x4F, head[1] == 0x67, head[2] == 0x67, head[3] == 0x53 {
            if OggReader.firstPacketStarts(with: Array("OpusHead".utf8), in: data) { return OpusDecoder(data: data) }
            return VorbisDecoder(data: data)
        }
        if head[0] == 0x52, head[1] == 0x49, head[2] == 0x46, head[3] == 0x46 { return WavDecoder(data: data) }
        return nil
    }
}

// MARK: - Vorbis

public final class VorbisDecoder: AudioDecoder {
    private let bytes: UnsafeMutableRawPointer
    private let v: OpaquePointer
    public let sampleRate: Double
    public let channels: Int
    public let lengthFrames: Int?

    public init?(data: Data) {
        bytes = .allocate(byteCount: data.count, alignment: 16)
        data.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: data.count)
        var err: Int32 = 0
        guard let v = stb_vorbis_open_memory(bytes.assumingMemoryBound(to: UInt8.self), Int32(data.count), &err, nil) else {
            bytes.deallocate()
            return nil
        }
        self.v = v
        let info = stb_vorbis_get_info(v)
        sampleRate = Double(info.sample_rate)
        channels = Int(info.channels)
        let len = Int(stb_vorbis_stream_length_in_samples(v))
        lengthFrames = len > 0 ? len : nil
    }

    deinit {
        stb_vorbis_close(v)
        bytes.deallocate()
    }

    public func read(_ out: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        Int(stb_vorbis_get_samples_float_interleaved(v, Int32(channels), out, Int32(frames * channels)))
    }

    public func seek(toFrame frame: Int) {
        if frame <= 0 { stb_vorbis_seek_start(v) } else { stb_vorbis_seek(v, UInt32(frame)) }
    }
}

// MARK: - Ogg

enum OggReader {
    struct Page { var headerType: UInt8; var granule: Int64; var serial: UInt32; var segments: [Int]; var bodyStart: Int }

    static func pages(_ b: UnsafeRawBufferPointer) -> [Page] {
        var out: [Page] = []
        var p = 0
        let n = b.count
        while p + 27 <= n {
            guard b[p] == 0x4F, b[p + 1] == 0x67, b[p + 2] == 0x67, b[p + 3] == 0x53 else {
                // Resync on garbage.
                p += 1
                continue
            }
            let type = b[p + 5]
            var g: Int64 = 0
            for i in 0..<8 { g |= Int64(b[p + 6 + i]) << (8 * Int64(i)) }
            var serial: UInt32 = 0
            for i in 0..<4 { serial |= UInt32(b[p + 14 + i]) << (8 * UInt32(i)) }
            let nseg = Int(b[p + 26])
            guard p + 27 + nseg <= n else { break }
            var segs: [Int] = []
            segs.reserveCapacity(nseg)
            var total = 0
            for i in 0..<nseg { let s = Int(b[p + 27 + i]); segs.append(s); total += s }
            let body = p + 27 + nseg
            guard body + total <= n else { break }
            out.append(Page(headerType: type, granule: g, serial: serial, segments: segs, bodyStart: body))
            p = body + total
        }
        return out
    }

    /// Packets of the first logical stream, as byte ranges (a packet can
    /// span pages).
    static func packets(_ b: UnsafeRawBufferPointer) -> (packets: [[Range<Int>]], lastGranule: Int64) {
        let pages = pages(b)
        guard let serial = pages.first?.serial else { return ([], 0) }
        var packets: [[Range<Int>]] = []
        var current: [Range<Int>] = []
        var last: Int64 = 0
        for page in pages where page.serial == serial {
            if page.headerType & 1 == 0 && !current.isEmpty { current = [] }  // lost continuation
            var off = page.bodyStart
            for s in page.segments {
                if s > 0 { current.append(off..<(off + s)) }
                off += s
                if s < 255 {
                    packets.append(current)
                    current = []
                }
            }
            if page.granule >= 0 { last = page.granule }
        }
        return (packets, last)
    }

    static func firstPacketStarts(with magic: [UInt8], in data: Data) -> Bool {
        data.prefix(4096).withUnsafeBytes { b in
            guard let page = pages(b).first else { return false }
            let s = page.bodyStart
            guard s + magic.count <= b.count else { return false }
            for i in 0..<magic.count where b[s + i] != magic[i] { return false }
            return true
        }
    }
}

// MARK: - Opus

public final class OpusDecoder: AudioDecoder {
    private let data: Data
    private var packets: [(ranges: [Range<Int>], start: Int)] = []
    private let preSkip: Int
    private let gain: Float
    private var decoder: OpaquePointer?
    private let streams: Int32, coupled: Int32
    private var mapping: [UInt8]
    public let sampleRate: Double = 48000
    public let channels: Int
    public let lengthFrames: Int?

    private var nextPacket = 0
    /// Position (in granule samples, i.e. including pre-skip) of the next
    /// decoded sample.
    private var position = 0
    private var discardUntil = 0
    private var endGranule: Int
    private var pending: [Float] = []
    private var pendingOffset = 0
    private var scratch = [UInt8](repeating: 0, count: 8192)
    private var pcm: [Float]

    public init?(data: Data) {
        self.data = data
        let (raw, lastGranule) = data.withUnsafeBytes { OggReader.packets($0) }
        guard raw.count > 2 else { return nil }
        let head = data.withUnsafeBytes { b in Array(raw[0].flatMap { Array(b[$0]) }) }
        guard head.count >= 19, Array(head.prefix(8)) == Array("OpusHead".utf8) else { return nil }
        let ch = Int(head[9])
        guard ch >= 1 else { return nil }
        preSkip = Int(head[10]) | Int(head[11]) << 8
        let g = Int16(bitPattern: UInt16(head[16]) | UInt16(head[17]) << 8)
        gain = powf(10, Float(g) / (20 * 256))
        let family = head[18]
        if family == 0 {
            guard ch <= 2 else { return nil }
            streams = 1
            coupled = ch == 2 ? 1 : 0
            mapping = ch == 2 ? [0, 1] : [0]
        } else {
            guard head.count >= 21 + ch else { return nil }
            streams = Int32(head[19])
            coupled = Int32(head[20])
            mapping = Array(head[21..<(21 + ch)])
        }
        channels = ch
        pcm = [Float](repeating: 0, count: 5760 * ch)

        // Index audio packets with their start positions so seeking is exact.
        var pos = 0
        var tmp = [UInt8](repeating: 0, count: 8192)
        var index: [(ranges: [Range<Int>], start: Int)] = []
        data.withUnsafeBytes { b in
            for r in raw.dropFirst(2) {
                let len = r.reduce(0) { $0 + $1.count }
                guard len > 0 else { continue }
                if tmp.count < len { tmp = [UInt8](repeating: 0, count: len) }
                var o = 0
                for rr in r { for i in rr { tmp[o] = b[i]; o += 1 } }
                let n = Int(opus_packet_get_nb_samples(tmp, Int32(len), 48000))
                index.append((r, pos))
                if n > 0 { pos += n }
            }
        }
        packets = index
        endGranule = lastGranule > 0 ? min(Int(lastGranule), pos) : pos
        lengthFrames = max(0, endGranule - preSkip)
        seek(toFrame: 0)
    }

    deinit { if let d = decoder { opus_multistream_decoder_destroy(d) } }

    private func resetDecoder() {
        if let d = decoder { opus_multistream_decoder_destroy(d) }
        var err: Int32 = 0
        decoder = mapping.withUnsafeBufferPointer { m in
            opus_multistream_decoder_create(48000, Int32(channels), streams, coupled, m.baseAddress!, &err)
        }
    }

    public func seek(toFrame frame: Int) {
        resetDecoder()
        let target = max(0, frame) + preSkip
        // 80 ms of pre-roll lets the decoder converge.
        let preroll = max(0, target - 3840)
        var lo = 0, hi = packets.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if packets[mid].start <= preroll { lo = mid } else { hi = mid - 1 }
        }
        nextPacket = packets.isEmpty ? 0 : lo
        position = packets.isEmpty ? 0 : packets[lo].start
        discardUntil = target
        pending.removeAll(keepingCapacity: true)
        pendingOffset = 0
    }

    /// Decodes the next packet into `pending`. False at end of stream.
    private func decodeNext() -> Bool {
        guard let dec = decoder else { return false }
        while nextPacket < packets.count {
            let r = packets[nextPacket].ranges
            nextPacket += 1
            let len = r.reduce(0) { $0 + $1.count }
            if scratch.count < len { scratch = [UInt8](repeating: 0, count: len) }
            data.withUnsafeBytes { b in
                var o = 0
                for rr in r { for i in rr { scratch[o] = b[i]; o += 1 } }
            }
            let n = Int(opus_multistream_decode_float(dec, scratch, Int32(len), &pcm, 5760, 0))
            if n <= 0 { continue }
            let start = position
            position += n
            // Trim to [discardUntil, endGranule).
            let from = max(0, discardUntil - start)
            let to = min(n, endGranule - start)
            if to <= from { if start >= endGranule { return false }; continue }
            pending.removeAll(keepingCapacity: true)
            pending.append(contentsOf: pcm[(from * channels)..<(to * channels)])
            if gain != 1 { for i in pending.indices { pending[i] *= gain } }
            pendingOffset = 0
            return true
        }
        return false
    }

    public func read(_ out: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        var done = 0
        while done < frames {
            if pendingOffset >= pending.count {
                if !decodeNext() { break }
            }
            let avail = (pending.count - pendingOffset) / channels
            let n = min(avail, frames - done)
            pending.withUnsafeBufferPointer { p in
                (out + done * channels).update(from: p.baseAddress! + pendingOffset, count: n * channels)
            }
            pendingOffset += n * channels
            done += n
        }
        return done
    }
}

// MARK: - WAV

public final class WavDecoder: AudioDecoder {
    private let data: Data
    private let dataStart: Int
    private let dataLen: Int
    private let bits: Int
    private let isFloat: Bool
    private var pos = 0
    public let sampleRate: Double
    public let channels: Int
    public var lengthFrames: Int? { dataLen / (bits / 8 * channels) }

    public init?(data: Data) {
        let b = [UInt8](data)
        func u32(_ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16 | Int(b[p + 3]) << 24 }
        func u16(_ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 }
        guard b.count > 44, Array(b[8..<12]) == Array("WAVE".utf8) else { return nil }
        var p = 12
        var fmt: (Int, Int, Int, Int)? = nil  // format, channels, rate, bits
        var dStart = 0, dLen = 0
        while p + 8 <= b.count {
            let id = String(decoding: b[p..<(p + 4)], as: UTF8.self)
            let len = u32(p + 4)
            if id == "fmt ", p + 24 <= b.count {
                var format = u16(p + 8)
                if format == 0xFFFE, p + 34 <= b.count { format = u16(p + 32) }
                fmt = (format, u16(p + 10), u32(p + 12), u16(p + 22))
            } else if id == "data" {
                dStart = p + 8
                dLen = min(len, b.count - dStart)
                break
            }
            p += 8 + len + (len & 1)
        }
        guard let f = fmt, dLen > 0, f.1 > 0, [16, 24, 32].contains(f.3), f.0 == 1 || f.0 == 3 else { return nil }
        self.data = data
        dataStart = dStart
        dataLen = dLen
        channels = f.1
        sampleRate = Double(f.2)
        bits = f.3
        isFloat = f.0 == 3
    }

    public func read(_ out: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let bps = bits / 8
        let frameBytes = bps * channels
        let n = min(frames, (dataLen - pos) / frameBytes)
        guard n > 0 else { return 0 }
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: dataStart + pos)
            for i in 0..<(n * channels) {
                let s = base.advanced(by: i * bps)
                switch (bits, isFloat) {
                case (16, _): out[i] = Float(s.loadUnaligned(as: Int16.self)) / 32768
                case (24, _):
                    let b0 = Int32(s.load(as: UInt8.self)), b1 = Int32(s.advanced(by: 1).load(as: UInt8.self)), b2 = Int32(Int8(bitPattern: s.advanced(by: 2).load(as: UInt8.self)))
                    out[i] = Float(b0 | b1 << 8 | b2 << 16) / 8_388_608
                case (32, true): out[i] = s.loadUnaligned(as: Float.self)
                default: out[i] = Float(s.loadUnaligned(as: Int32.self)) / 2_147_483_648
                }
            }
        }
        pos += n * frameBytes
        return n
    }

    public func seek(toFrame frame: Int) {
        pos = min(dataLen, max(0, frame) * bits / 8 * channels)
    }
}
