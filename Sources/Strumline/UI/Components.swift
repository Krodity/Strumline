import SwiftUI
import StrumCore

struct MenuButton: View {
    var title: String
    var systemImage: String
    var role: ButtonRole? = nil
    var action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).frame(width: 24)
                Text(title).font(.system(size: 18, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.6)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).fill(role == .destructive ? Color.red.opacity(0.25) : Color.white.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.15)))
        }
        .foregroundStyle(role == .destructive ? .red : .white)
    }
}

struct SliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

struct StarsView: View {
    var stars: Int
    var size: CGFloat = 14
    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { i in
                Image(systemName: i < stars ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundStyle(stars >= 6 ? Palette.yellow : (i < stars ? Color.white : Color.white.opacity(0.3)))
            }
        }
    }
}

/// song.ini intensity 0-6 as dots (Clone Hero shows the same scale).
struct IntensityDots: View {
    var value: Int
    var body: some View {
        HStack(spacing: 2) {
            if value < 0 {
                Text("—").font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(0..<6, id: \.self) { i in
                    Circle()
                        .fill(i < value ? (value >= 6 ? Color.red : Palette.orange) : Color.white.opacity(0.2))
                        .frame(width: 6, height: 6)
                }
            }
        }
    }
}

extension Instrument {
    var symbol: String {
        switch kind {
        case .drums: return "circle.grid.2x2.fill"
        case .sixFret: return "guitars"
        case .fiveFret: return self == .keys ? "pianokeys" : self == .bass ? "guitars.fill" : "guitars"
        }
    }
}

/// Loads album art off the main thread and caches it.
@MainActor
final class ArtCache {
    static let shared = ArtCache()
    private var cache: [String: UIImage] = [:]
    private var order: [String] = []

    func image(for song: SongEntry) async -> UIImage? {
        guard let name = song.albumArt else { return nil }
        if let i = cache[song.path] { return i }
        let img: UIImage? = await Task.detached(priority: .utility) {
            // Thumbnails are kept on disk so linked songs don't need to be
            // re-read (or re-downloaded from iCloud) to show their art.
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Art", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(song.chartHash + ".jpg")
            if let d = try? Data(contentsOf: file), let i = UIImage(data: d) { return i }
            guard let pkg = try? SongLoader.package(for: song), let d = try? pkg.data(named: name), let i = UIImage(data: d) else { return nil }
            let side: CGFloat = 256
            let r = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
            let thumb = r.image { _ in i.draw(in: CGRect(x: 0, y: 0, width: side, height: side)) }
            try? thumb.jpegData(compressionQuality: 0.85)?.write(to: file)
            return thumb
        }.value
        if let img {
            cache[song.path] = img
            order.append(song.path)
            if order.count > 300 { cache[order.removeFirst()] = nil }
        }
        return img
    }
}

struct AlbumArt: View {
    var song: SongEntry
    var size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(hue: Double(abs(song.name.hashValue % 360)) / 360, saturation: 0.5, brightness: 0.35), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.1))
        .task(id: song.path) { image = await ArtCache.shared.image(for: song) }
    }
}

struct StrumlineBackground: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        if let n = app.settings.menuWallpaper, CustomAssets.backgroundFiles.contains(n) {
            ZStack {
                MediaBackground(url: CustomAssets.backgrounds.appendingPathComponent(n))
                Color.black.opacity(0.35).ignoresSafeArea()
            }
        } else {
            defaultBackground
        }
    }

    private var defaultBackground: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.1, green: 0.04, blue: 0.2), Color(red: 0.02, green: 0.02, blue: 0.06)], startPoint: .top, endPoint: .bottom)
            // A faint receding highway, like the title screen of a rhythm game.
            Canvas { ctx, size in
                let cx = size.width / 2, base = size.height, top = size.height * 0.35
                let colors: [Color] = [Palette.green, Palette.red, Palette.yellow, Palette.blue, Palette.orange]
                for i in 0...5 {
                    let x0 = cx + (CGFloat(i) - 2.5) * size.width * 0.16
                    let x1 = cx + (CGFloat(i) - 2.5) * size.width * 0.03
                    var p = Path(); p.move(to: CGPoint(x: x0, y: base)); p.addLine(to: CGPoint(x: x1, y: top))
                    ctx.stroke(p, with: .color(.white.opacity(0.06)), lineWidth: 2)
                    if i < 5 {
                        let cxl = cx + (CGFloat(i) - 2) * size.width * 0.16
                        ctx.fill(Path(ellipseIn: CGRect(x: cxl - 18, y: base - 30, width: 36, height: 16)), with: .color(colors[i].opacity(0.25)))
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

struct Wordmark: View {
    var size: CGFloat = 52
    var body: some View {
        Text("STRUMLINE")
            .font(.system(size: size, weight: .black, design: .rounded))
            .kerning(size * 0.06)
            .foregroundStyle(LinearGradient(colors: [Palette.green, Palette.yellow, Palette.orange, Palette.red], startPoint: .leading, endPoint: .trailing))
            .shadow(color: Palette.orange.opacity(0.5), radius: 12)
            .minimumScaleFactor(0.5)
            .lineLimit(1)
    }
}

func formatLength(_ ms: Int) -> String {
    let s = max(0, ms / 1000)
    return String(format: "%d:%02d", s / 60, s % 60)
}
