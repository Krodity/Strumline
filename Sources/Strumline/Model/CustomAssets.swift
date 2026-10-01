import SwiftUI
import PhotosUI
import _PhotosUI_SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
import AVFoundation
import UIKit
import StrumCore

/// User content like Clone Hero's Custom folder: highway images and
/// background images/videos in On My iPhone › Strumline › Custom.
enum CustomAssets {
    static let shuffle = "__shuffle__"

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Custom", isDirectory: true)
    }
    static var highways: URL { dir("Highways") }
    static var backgrounds: URL { dir("Backgrounds") }

    private static func dir(_ name: String) -> URL {
        let d = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static let imageExts = ["png", "jpg", "jpeg", "heic", "webp"]
    static let videoExts = ["mp4", "mov", "m4v"]

    static func isVideo(_ name: String) -> Bool { videoExts.contains((name as NSString).pathExtension.lowercased()) }

    static func list(_ dir: URL, videos: Bool) -> [String] {
        let exts = imageExts + (videos ? videoExts : [])
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { exts.contains(($0 as NSString).pathExtension.lowercased()) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static var highwayFiles: [String] { list(highways, videos: false) }
    static var backgroundFiles: [String] { list(backgrounds, videos: true) }

    /// Copies picked files into a Custom folder (they're small, and the
    /// game needs them available instantly).
    static func importFiles(_ urls: [URL], into dir: URL) {
        for u in urls {
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            let dest = dir.appendingPathComponent(u.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: u, to: dest)
        }
    }

    /// Saves items picked in the Photos picker into a Custom folder.
    /// Returns how many were saved.
    static func importPhotos(_ items: [PhotosPickerItem], into dir: URL) async -> Int {
        var saved = 0
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        for (i, item) in items.enumerated() {
            let base = "Photo-\(stamp.string(from: Date()))" + (items.count > 1 ? "-\(i + 1)" : "")
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }),
               let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                let ext = movie.url.pathExtension.isEmpty ? "mov" : movie.url.pathExtension
                let dest = dir.appendingPathComponent(base + "." + ext)
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.moveItem(at: movie.url, to: dest)) != nil { saved += 1 }
            } else if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data),
                      let jpg = img.jpegData(compressionQuality: 0.9) {
                // HEIC/PNG/etc. normalised to JPEG so every loader can read it.
                if (try? jpg.write(to: dir.appendingPathComponent(base + ".jpg"))) != nil { saved += 1 }
            }
        }
        return saved
    }

    private static var cache: [String: UIImage] = [:]

    static func image(_ url: URL) -> UIImage? {
        if let i = cache[url.path] { return i }
        guard let i = UIImage(contentsOfFile: url.path) else { return nil }
        cache[url.path] = i
        return i
    }

    /// Resolves a background choice (a file name or shuffle) to a file.
    static func resolveBackground(_ choice: String?) -> URL? {
        guard let c = choice else { return nil }
        let files = backgroundFiles
        if c == shuffle { return files.randomElement().map { backgrounds.appendingPathComponent($0) } }
        return files.contains(c) ? backgrounds.appendingPathComponent(c) : nil
    }

    static func highwayURL(_ name: String?) -> URL? {
        guard let n = name, highwayFiles.contains(n) else { return nil }
        return highways.appendingPathComponent(n)
    }
}

enum GameBackgroundSource: String, Codable, CaseIterable {
    /// The song's own background/video; the custom one if it has none.
    case song
    /// Always the custom background.
    case custom
    case none
    var displayName: String {
        switch self {
        case .song: return "Song's background (else custom)"
        case .custom: return "Custom background"
        case .none: return "None"
        }
    }
}

// MARK: - Views

/// Full-screen image or muted looping video.
struct MediaBackground: View {
    let url: URL
    var body: some View {
        GeometryReader { geo in
            Group {
                if CustomAssets.isVideo(url.lastPathComponent) {
                    LoopingVideo(url: url)
                } else if let img = CustomAssets.image(url) {
                    Image(uiImage: img).resizable().scaledToFill()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct LoopingVideo: UIViewRepresentable {
    let url: URL
    var rate: Float = 1

    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.load(url, rate: rate)
        return v
    }
    func updateUIView(_ v: PlayerView, context: Context) {
        if v.url != url { v.load(url, rate: rate) }
    }
    static func dismantleUIView(_ v: PlayerView, coordinator: ()) { v.player.pause() }

    final class PlayerView: UIView {
        let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private(set) var url: URL?
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        func load(_ u: URL, rate: Float) {
            url = u
            let item = AVPlayerItem(url: u)
            looper = AVPlayerLooper(player: player, templateItem: item)
            player.isMuted = true
            let l = layer as! AVPlayerLayer
            l.player = player
            l.videoGravity = .resizeAspectFill
            player.playImmediately(atRate: rate)
        }
    }
}

/// Maps an image onto the highway with a true perspective warp (a
/// homography from the image rect to the highway's four corners) and
/// scrolls it with the notes, like Clone Hero's custom highways.
struct HighwayTexture: UIViewRepresentable {
    let session: GameSession
    let run: PlayerRun
    let image: UIImage
    let touchControls: Bool

    func makeUIView(context: Context) -> TextureView {
        let v = TextureView()
        v.isUserInteractionEnabled = false
        v.configure(session: session, run: run, image: image, touch: touchControls)
        return v
    }
    func updateUIView(_ v: TextureView, context: Context) {
        v.configure(session: session, run: run, image: image, touch: touchControls)
    }
    static func dismantleUIView(_ v: TextureView, coordinator: ()) { v.stop() }

    final class TextureView: UIView {
        private let tex = CALayer()
        private var link: CADisplayLink?
        private weak var session: GameSession?
        private weak var run: PlayerRun?
        private var touch = false
        private var imageID: ObjectIdentifier?

        func configure(session: GameSession, run: PlayerRun, image: UIImage, touch: Bool) {
            self.session = session
            self.run = run
            self.touch = touch
            if imageID != ObjectIdentifier(image) {
                imageID = ObjectIdentifier(image)
                // Two copies stacked so the scroll wraps seamlessly.
                let size = CGSize(width: image.size.width, height: image.size.height * 2)
                let tiled = UIGraphicsImageRenderer(size: size).image { _ in
                    image.draw(in: CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height))
                    image.draw(in: CGRect(x: 0, y: image.size.height, width: image.size.width, height: image.size.height))
                }
                tex.contents = tiled.cgImage
                tex.contentsGravity = .resize
                tex.anchorPoint = .zero
                tex.position = .zero
                tex.bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
                tex.opacity = 0.9
                tex.actions = ["transform": NSNull(), "contentsRect": NSNull(), "position": NSNull(), "bounds": NSNull()]
                if tex.superlayer == nil { layer.addSublayer(tex) }
            }
            if link == nil {
                let l = CADisplayLink(target: self, selector: #selector(step))
                let maxFPS = Float(UIScreen.main.maximumFramesPerSecond)
                l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: maxFPS, preferred: maxFPS)
                l.add(to: .main, forMode: .common)
                link = l
            }
        }

        func stop() { link?.invalidate(); link = nil }

        @objc private func step() {
            guard let session, let run, bounds.width > 0 else { return }
            let layout: HighwayGeometry.TouchLayout = !touch ? .none : (run.settings.touchMode == .fretStrum && run.instrument.kind != .drums ? .fretStrum : .lanes)
            let g = HighwayGeometry.make(size: bounds.size, settings: run.settings, touch: layout)
            let tl = g.point(-1, 1), tr = g.point(1, 1), br = g.point(1, -0.12), bl = g.point(-1, -0.12)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            tex.transform = TextureView.homography(w: 100, h: 100, tl: tl, tr: tr, br: br, bl: bl)
            // One image length per visible highway; scrolls toward the player.
            let visible = 1.25 * max(0.5, min(10, run.settings.highwayLength)) / max(0.25, min(10, run.settings.noteSpeed))
            let travel = (session.now / visible).truncatingRemainder(dividingBy: 1)
            let off = travel < 0 ? travel + 1 : travel
            tex.contentsRect = CGRect(x: 0, y: 0.5 * (1 - off), width: 1, height: 0.5)
            CATransaction.commit()
        }

        /// Projective transform taking the layer rect (0,0,w,h) onto the quad.
        static func homography(w: CGFloat, h: CGFloat, tl: CGPoint, tr: CGPoint, br: CGPoint, bl: CGPoint) -> CATransform3D {
            let (x0, y0, x1, y1, x2, y2, x3, y3) = (tl.x, tl.y, tr.x, tr.y, br.x, br.y, bl.x, bl.y)
            let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
            let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
            let den = dx1 * dy2 - dx2 * dy1
            let g = den == 0 ? 0 : (dx3 * dy2 - dx2 * dy3) / den
            let hh = den == 0 ? 0 : (dx1 * dy3 - dx3 * dy1) / den
            let a = x1 - x0 + g * x1, b = x3 - x0 + hh * x3, c = x0
            let d = y1 - y0 + g * y1, e = y3 - y0 + hh * y3, f = y0
            var t = CATransform3DIdentity
            t.m11 = a / w; t.m12 = d / w; t.m13 = 0; t.m14 = g / w
            t.m21 = b / h; t.m22 = e / h; t.m23 = 0; t.m24 = hh / h
            t.m31 = 0; t.m32 = 0; t.m33 = 1; t.m34 = 0
            t.m41 = c; t.m42 = f; t.m43 = 0; t.m44 = 1
            return t
        }
    }
}

/// A video from the Photos picker, copied to a temp file we own.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { m in
            SentTransferredFile(m.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}
