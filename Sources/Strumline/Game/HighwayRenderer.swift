import SwiftUI
import UIKit
import StrumCore

enum Palette {
    static let green = Color(red: 0.16, green: 0.85, blue: 0.27)
    static let red = Color(red: 0.95, green: 0.18, blue: 0.2)
    static let yellow = Color(red: 1.0, green: 0.84, blue: 0.1)
    static let blue = Color(red: 0.18, green: 0.5, blue: 1.0)
    static let orange = Color(red: 1.0, green: 0.52, blue: 0.08)
    static let open = Color(red: 0.72, green: 0.32, blue: 1.0)
    static let sp = Color(red: 0.45, green: 0.95, blue: 1.0)
    static let white = Color(white: 0.95)
    static let black = Color(white: 0.12)

    static func fret(_ lane: Int) -> Color { [green, red, yellow, blue, orange][max(0, min(4, lane))] }
    static func drum(_ lane: Int, five: Bool) -> Color {
        if five { return [orange, red, yellow, blue, orange, green][max(0, min(5, lane))] }
        return [orange, red, yellow, blue, green, green][max(0, min(5, lane))]
    }
}

/// Screen-space geometry of the 3D highway.
struct HighwayGeometry {
    var size: CGSize
    var cx: CGFloat
    var halfWidth: CGFloat
    var strikeY: CGFloat
    var topY: CGFloat
    /// Perspective strength; longer highways recede more steeply so far
    /// notes still fit on screen.
    var k: CGFloat = 2.3
    var lefty: Bool
    /// Screen safe area (Dynamic Island / notch / home indicator); the game
    /// canvas ignores the safe area, so HUD layout offsets by these.
    var safe: UIEdgeInsets = .zero

    static var windowInsets: UIEdgeInsets {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.windows.first(where: \.isKeyWindow)?.safeAreaInsets ?? scene?.windows.first?.safeAreaInsets ?? .zero
    }

    enum TouchLayout { case none, lanes, fretStrum }

    /// Height of the Frets + Strum button row.
    static func fretStrumHeight(_ size: CGSize) -> CGFloat {
        size.width > size.height ? size.height * 0.46 : min(size.height * 0.34, 300)
    }

    static func make(size: CGSize, settings: GameSettings, touch: TouchLayout) -> HighwayGeometry {
        let landscape = size.width > size.height
        var width: CGFloat = landscape ? min(size.height * 0.95, size.width * 0.5) : min(size.width * 0.9, size.height * 0.55)
        var strike = size.height * 0.84
        switch touch {
        case .none: break
        case .lanes:
            // The lanes are the buttons: widen the bottom of the highway and
            // lift the strikeline so there's a tall tap area under it.
            width = landscape ? min(size.height * 1.3, size.width * 0.64) : min(size.width * 0.98, size.height * 0.6)
            strike = size.height * (landscape ? 0.74 : 0.79)
        case .fretStrum:
            strike = size.height - fretStrumHeight(size) - 22
        }
        width *= CGFloat(max(0.5, min(1.5, settings.highwayScale)))
        width = min(width, size.width * 0.99)
        let safe = windowInsets
        let len = CGFloat(max(0.5, min(10, settings.highwayLength)))
        // The far end of the highway starts below the Dynamic Island.
        let ceiling = safe.top + (landscape ? 8 : 70)
        let top = strike - (strike - ceiling) * min(1, 0.55 + 0.45 * len)
        var g = HighwayGeometry(size: size, cx: size.width / 2, halfWidth: width / 2, strikeY: strike, topY: top, lefty: settings.leftyFlip, safe: safe)
        if len > 1 { g.k = 2.3 * pow(len, 0.8) }
        return g
    }

    func scale(_ d: CGFloat) -> CGFloat { 1 / (1 + max(-0.3, d) * k) }

    func y(_ d: CGFloat) -> CGFloat {
        let far = scale(1)
        return strikeY - (strikeY - topY) * (1 - scale(d)) / (1 - far)
    }

    /// `pos` is -1 (left rail) … 1 (right rail).
    func point(_ pos: CGFloat, _ d: CGFloat) -> CGPoint {
        CGPoint(x: cx + (lefty ? -pos : pos) * halfWidth * scale(d), y: y(d))
    }

    func laneWidth(_ lanes: Int, _ d: CGFloat) -> CGFloat { 2 * halfWidth * scale(d) / CGFloat(lanes) }

    func lanePos(_ i: Int, of n: Int) -> CGFloat { -1 + (2 * CGFloat(i) + 1) / CGFloat(n) }
}

struct HighwayRenderer {
    let session: GameSession
    /// The player whose highway this draws.
    let run: PlayerRun
    let settings: GameSettings
    /// Tap Lanes: the strikeline targets are the buttons, so draw them big.
    private var bigTargets = false

    init(session: GameSession, run: PlayerRun) {
        self.session = session
        self.run = run
        self.settings = run.settings
    }

    private var mods: Modifiers { run.modifiers }
    private var isDrums: Bool { run.instrument.kind == .drums }
    private var six: Bool { run.instrument.kind == .sixFret }
    private var five: Bool { run.drumMode == .fiveLane }

    /// Visual lane count and the lane index → column mapping.
    private var laneCount: Int {
        if isDrums { return run.drumMode.laneCount }
        return six ? 3 : 5
    }
    private func column(_ lane: Int) -> Int {
        if isDrums { return lane - 1 }  // kick is drawn as a bar
        if six { return lane % 3 }
        return lane
    }

    private var visibleTime: Double { 1.25 * max(0.5, min(10, settings.highwayLength)) / max(0.25, min(10, settings.noteSpeed)) }

    mutating func draw(_ ctx: inout GraphicsContext, size: CGSize, time t: Double, touchControls: Bool) {
        let layout: HighwayGeometry.TouchLayout = !touchControls ? .none : (settings.touchMode == .fretStrum && !isDrums ? .fretStrum : .lanes)
        let g = HighwayGeometry.make(size: size, settings: settings, touch: layout)
        bigTargets = layout == .lanes
        let eng = run.engine
        let lightsOut = mods.lightsOut
        let mc = mods.modchart
        let showSurface = !lightsOut && mc == .off
        let showNotes = !lightsOut && (mc == .off || mc == .prep)
        let showStrike = !lightsOut && mc != .prep
        let showLanes = !lightsOut && mc == .off

        if showSurface { drawSurface(&ctx, g, t: t) }
        if showLanes { drawBeatLines(&ctx, g, t: t) }
        if showStrike { drawStrikeline(&ctx, g, t: t) }
        if showNotes { drawNotes(&ctx, g, t: t) }
        if showStrike { drawFlames(&ctx, g, t: t) }
        drawHUD(&ctx, g, t: t, compact: mc == .full || mc == .prep)
        _ = eng
    }

    // MARK: Surface

    private func drawSurface(_ ctx: inout GraphicsContext, _ g: HighwayGeometry, t: Double) {
        var p = Path()
        p.move(to: g.point(-1, -0.12))
        p.addLine(to: g.point(-1, 1))
        p.addLine(to: g.point(1, 1))
        p.addLine(to: g.point(1, -0.12))
        p.closeSubpath()
        let sp = run.engine.spActive
        let top = sp ? Color(red: 0.05, green: 0.12, blue: 0.3) : Color(white: 0.02)
        let bottom = sp ? Color(red: 0.1, green: 0.25, blue: 0.5) : Color(white: 0.1)
        if CustomAssets.highwayURL(settings.highwayImage) == nil {
            ctx.fill(p, with: .linearGradient(Gradient(colors: [top.opacity(0.35), bottom.opacity(0.92)]), startPoint: g.point(0, 1), endPoint: g.point(0, 0)))
        } else if sp {
            // Star power tint over a custom highway.
            ctx.fill(p, with: .color(Palette.sp.opacity(0.18)))
        }

        // Drum fills: tint the highway while an activation is available.
        if isDrums && run.engine.showFills {
            for c in run.track.chords where c.activation && c.time > t && c.time - t < visibleTime {
                if let f = run.track.fills.first(where: { abs($0.endTime - c.time) < 0.001 || ($0.startTime <= c.time && $0.endTime >= c.time) }) {
                    let d0 = CGFloat((max(t, f.startTime) - t) / visibleTime), d1 = CGFloat((c.time - t) / visibleTime)
                    var r = Path()
                    r.move(to: g.point(-1, d0)); r.addLine(to: g.point(-1, d1)); r.addLine(to: g.point(1, d1)); r.addLine(to: g.point(1, d0)); r.closeSubpath()
                    ctx.fill(r, with: .color(Palette.sp.opacity(0.18)))
                }
            }
        }

        // Rails
        let railColor = sp ? Palette.sp : Color(white: 0.55)
        for side in [-1.0, 1.0] {
            var r = Path()
            r.move(to: g.point(side, -0.12))
            r.addLine(to: g.point(side, 1))
            ctx.stroke(r, with: .color(railColor.opacity(0.9)), lineWidth: 3)
        }
        // Lane lines ("strings")
        for i in 1..<laneCount {
            let pos = -1 + 2 * CGFloat(i) / CGFloat(laneCount)
            var r = Path()
            r.move(to: g.point(pos, -0.12))
            r.addLine(to: g.point(pos, 1))
            ctx.stroke(r, with: .color(.white.opacity(0.12)), lineWidth: 1)
        }
    }

    private func drawBeatLines(_ ctx: inout GraphicsContext, _ g: HighwayGeometry, t: Double) {
        let lines = session.beatLines
        var lo = 0, hi = lines.count
        while lo < hi { let m = (lo + hi) / 2; if lines[m].time < t - 0.2 { lo = m + 1 } else { hi = m } }
        var i = lo
        while i < lines.count {
            let bl = lines[i]
            let d = CGFloat((bl.time - t) / visibleTime)
            if d > 1 { break }
            if d > -0.1 {
                var p = Path()
                p.move(to: g.point(-1, d))
                p.addLine(to: g.point(1, d))
                let (w, a): (CGFloat, Double) = bl.kind == .measure ? (3, 0.45) : bl.kind == .beat ? (1.5, 0.22) : (1, 0.08)
                ctx.stroke(p, with: .color(.white.opacity(a * Double(g.scale(d)))), lineWidth: w * g.scale(d))
            }
            i += 1
        }
    }

    // MARK: Strikeline

    private func drawStrikeline(_ ctx: inout GraphicsContext, _ g: HighwayGeometry, t: Double) {
        let eng = run.engine
        var bar = Path()
        bar.move(to: g.point(-1, 0))
        bar.addLine(to: g.point(1, 0))
        ctx.stroke(bar, with: .color(.white.opacity(0.35)), lineWidth: 2)

        let lw = g.laneWidth(laneCount, 0)
        let r = lw * (bigTargets ? 0.44 : 0.36)
        if isDrums {
            // Kick line under the pads.
            let kickHit = t - eng.lastHitTime[Lane.kick] < 0.12
            var k = Path()
            k.move(to: g.point(-0.98, 0.012))
            k.addLine(to: g.point(0.98, 0.012))
            ctx.stroke(k, with: .color((five ? Palette.orange : Palette.orange).opacity(kickHit ? 1 : 0.5)), lineWidth: kickHit ? 7 : 4)
            for col in 0..<laneCount {
                let lane = col + 1
                let c = g.point(g.lanePos(col, of: laneCount), 0)
                let hit = t - eng.lastHitTime[min(lane, 7)] < 0.12
                let color = Palette.drum(lane, five: five)
                let rect = CGRect(x: c.x - r, y: c.y - r * 0.5, width: r * 2, height: r)
                ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(hit ? 0.95 : 0.25)))
                ctx.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 3)
            }
            return
        }
        for col in 0..<laneCount {
            let c = g.point(g.lanePos(col, of: laneCount), 0)
            let color: Color = six ? Palette.white : Palette.fret(col)
            if six {
                // Black (top) and white (bottom) buttons per column.
                let held1 = eng.frets & (1 << UInt32(col)) != 0
                let held2 = eng.frets & (1 << UInt32(col + 3)) != 0
                let r1 = CGRect(x: c.x - r, y: c.y - r * 0.95, width: r * 2, height: r * 0.8)
                let r2 = CGRect(x: c.x - r, y: c.y + r * 0.1, width: r * 2, height: r * 0.8)
                ctx.fill(Path(roundedRect: r1, cornerRadius: 4), with: .color(held1 ? Color(white: 0.35) : Color(white: 0.12)))
                ctx.stroke(Path(roundedRect: r1, cornerRadius: 4), with: .color(.white.opacity(0.6)), lineWidth: 2)
                ctx.fill(Path(roundedRect: r2, cornerRadius: 4), with: .color(held2 ? Color.white : Color(white: 0.6).opacity(0.4)))
                ctx.stroke(Path(roundedRect: r2, cornerRadius: 4), with: .color(.white.opacity(0.8)), lineWidth: 2)
                continue
            }
            let held = eng.frets & (1 << UInt32(col)) != 0
            let rect = CGRect(x: c.x - r, y: c.y - r * 0.55, width: r * 2, height: r * 1.1)
            ctx.fill(Path(ellipseIn: rect), with: .color(Color.black.opacity(0.6)))
            ctx.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: held ? 6 : 3.5)
            if held {
                ctx.fill(Path(ellipseIn: rect.insetBy(dx: r * 0.3, dy: r * 0.17)), with: .color(color.opacity(0.9)))
            }
        }
    }

    // MARK: Notes

    private func brutalFade(_ d: CGFloat) -> Double {
        guard mods.brutal else { return 1 }
        let edge = max(0.22, 1 - CGFloat(run.engine.combo) / 180)
        return Double(max(0, min(1, (edge - d) / 0.08)))
    }

    private func drawNotes(_ ctx: inout GraphicsContext, _ g: HighwayGeometry, t: Double) {
        let chords = run.track.chords
        guard !chords.isEmpty else { return }
        let eng = run.engine
        // First chord still relevant (sustains may reach back further).
        var lo = 0, hi = chords.count
        while lo < hi { let m = (lo + hi) / 2; if chords[m].time < t - 0.25 { lo = m + 1 } else { hi = m } }
        var start = lo
        var j = lo - 1
        while j >= 0 && lo - j <= 64 {
            if chords[j].sustainEndTime > t { start = j }
            j -= 1
        }
        var end = lo
        while end < chords.count && chords[end].time - t < visibleTime * 1.02 { end += 1 }
        guard start < end else { return }

        // Sustains first (under gems).
        if !isDrums {
            for i in start..<end {
                let c = chords[i]
                for gem in c.gems where gem.endTime > c.time {
                    drawSustain(&ctx, g, t: t, chordIndex: i, chord: c, gem: gem)
                }
            }
        }
        // Gems far → near.
        for i in stride(from: end - 1, through: start, by: -1) {
            let c = chords[i]
            let d = CGFloat((c.time - t) / visibleTime)
            if d < -0.12 || d > 1.02 { continue }
            let state = eng.chordState[i]
            if !isDrums && state == .hit { continue }
            let fade = brutalFade(d)
            if fade <= 0 { continue }
            let missed = state == .missed
            let spNote = c.spPhrase >= 0 && !eng.spActive
            if isDrums {
                for (gi, gem) in c.gems.enumerated() where eng.gemHit[i] & (1 << UInt32(gi)) == 0 {
                    drawDrumGem(&ctx, g, d: d, gem: gem, sp: spNote, activation: c.activation && eng.showFills, missed: eng.gemMissed[i] & (1 << UInt32(gi)) != 0, fade: fade)
                }
            } else {
                for gem in c.gems {
                    drawFretGem(&ctx, g, d: d, lane: gem.lane, kind: c.kind, sp: spNote, missed: missed, fade: fade)
                }
            }
        }
    }

    private func gemColor(_ lane: Int) -> Color {
        if six { return lane >= 3 ? Palette.white : Palette.black }
        return Palette.fret(lane)
    }

    private func drawSustain(_ ctx: inout GraphicsContext, _ g: HighwayGeometry, t: Double, chordIndex: Int, chord c: Chord, gem: Gem) {
        let eng = run.engine
        let openLane = six ? Lane.open6 : Lane.open5
        let held = eng.sustains.contains { $0.chord == chordIndex && $0.lane == gem.lane }
        let hit = eng.chordState[chordIndex] == .hit
        if hit && !held { return }  // dropped
        let d0 = CGFloat((max(c.time, hit ? t : c.time) - t) / visibleTime)
        let d1 = CGFloat((gem.endTime - t) / visibleTime)
        if d1 < -0.05 || d0 > 1 { return }
        let a = max(-0.05, d0), b = min(1, d1)
        let isOpen = gem.lane == openLane
        let pos: CGFloat = isOpen ? 0 : g.lanePos(column(gem.lane), of: laneCount)
        let halfW: CGFloat = isOpen ? 0.9 : 0.16 / CGFloat(laneCount) * 5
        var color: Color = isOpen ? Palette.open : gemColor(gem.lane)
        if six && gem.lane < 3 { color = Color(white: 0.45) }
        if c.spPhrase >= 0 && !eng.spActive { color = Palette.sp }
        if eng.spActive { color = Palette.sp }
        if eng.chordState[chordIndex] == .missed { color = Color(white: 0.35) }
        let fade = brutalFade(a)
        let w = held ? 1.0 : 0.7
        let whammy = held && t - 0 >= 0 ? eng.whammy : 0
        let steps = 14
        var p = Path()
        var left: [CGPoint] = [], right: [CGPoint] = []
        for s in 0...steps {
            let d = a + (b - a) * CGFloat(s) / CGFloat(steps)
            let wob = held ? CGFloat(sin(Double(d) * 40 - t * 18) * (0.25 + abs(whammy)) * 0.04) : 0
            left.append(g.point(pos - halfW * CGFloat(w) / 5 * (isOpen ? 5 : 1) + wob, d))
            right.append(g.point(pos + halfW * CGFloat(w) / 5 * (isOpen ? 5 : 1) + wob, d))
        }
        p.move(to: left[0])
        for q in left.dropFirst() { p.addLine(to: q) }
        for q in right.reversed() { p.addLine(to: q) }
        p.closeSubpath()
        ctx.fill(p, with: .color(color.opacity((held ? 0.95 : 0.6) * fade)))
    }

    private func star(center: CGPoint, r: CGFloat, squash: CGFloat) -> Path {
        var p = Path()
        for i in 0..<10 {
            let ang = -Double.pi / 2 + Double(i) * Double.pi / 5
            let rr = i % 2 == 0 ? r : r * 0.45
            let pt = CGPoint(x: center.x + CGFloat(cos(ang)) * rr, y: center.y + CGFloat(sin(ang)) * rr * squash)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }

    private func drawFretGem(_ ctx: inout GraphicsContext, _ g: HighwayGeometry, d: CGFloat, lane: Int, kind: NoteKind, sp: Bool, missed: Bool, fade: Double) {
        let openLane = six ? Lane.open6 : Lane.open5
        let s = g.scale(d)
        let lw = g.laneWidth(laneCount, d)
        let alpha = (missed ? 0.4 : 1.0) * fade
        let spActive = run.engine.spActive
        if lane == openLane {
            let l = g.point(-0.92, d), r = g.point(0.92, d)
            let h = lw * 0.2
            let rect = CGRect(x: l.x, y: l.y - h / 2, width: r.x - l.x, height: h)
            let color = spActive || sp ? Palette.sp : Palette.open
            ctx.fill(Path(roundedRect: rect, cornerRadius: h / 2), with: .color(color.opacity(alpha)))
            if kind != .strum {
                ctx.stroke(Path(roundedRect: rect.insetBy(dx: 2, dy: 1), cornerRadius: h / 2), with: .color(.white.opacity(0.9 * alpha)), lineWidth: 2 * s)
            }
            return
        }
        let c = g.point(g.lanePos(column(lane), of: laneCount), d)
        var color = gemColor(lane)
        if spActive { color = Palette.sp }
        if missed { color = Color(white: 0.4) }
        let size = lw * (kind == .hopo ? 0.72 : 0.8)
        let rect = CGRect(x: c.x - size / 2, y: c.y - size * 0.24, width: size, height: size * 0.48)
        let yOff = six ? (lane < 3 ? -size * 0.14 : size * 0.14) : 0
        let r2 = rect.offsetBy(dx: 0, dy: yOff)
        if sp {
            let st = star(center: CGPoint(x: r2.midX, y: r2.midY), r: size * 0.52, squash: 0.55)
            ctx.fill(st, with: .color(color.opacity(alpha)))
            ctx.stroke(st, with: .color(Palette.sp.opacity(alpha)), lineWidth: 2.5 * s)
            if kind == .tap { ctx.fill(Path(ellipseIn: r2.insetBy(dx: size * 0.33, dy: size * 0.16)), with: .color(Color.black.opacity(alpha))) }
            return
        }
        // Body
        ctx.fill(Path(ellipseIn: r2.offsetBy(dx: 0, dy: size * 0.06)), with: .color(Color.black.opacity(0.55 * alpha)))
        ctx.fill(Path(ellipseIn: r2), with: .color(color.opacity(alpha)))
        switch kind {
        case .strum:
            ctx.fill(Path(ellipseIn: r2.insetBy(dx: size * 0.2, dy: size * 0.1)), with: .color(Color.black.opacity(0.35 * alpha)))
            ctx.fill(Path(ellipseIn: r2.insetBy(dx: size * 0.3, dy: size * 0.15)), with: .color(Color.white.opacity(0.85 * alpha)))
        case .hopo:
            ctx.fill(Path(ellipseIn: r2.insetBy(dx: size * 0.12, dy: size * 0.06)), with: .color(Color.white.opacity(0.95 * alpha)))
            ctx.fill(Path(ellipseIn: r2.insetBy(dx: size * 0.27, dy: size * 0.13)), with: .color(color.opacity(alpha)))
        case .tap:
            ctx.fill(Path(ellipseIn: r2.insetBy(dx: size * 0.16, dy: size * 0.08)), with: .color(Color.black.opacity(0.9 * alpha)))
            ctx.stroke(Path(ellipseIn: r2.insetBy(dx: size * 0.22, dy: size * 0.11)), with: .color(color.opacity(alpha)), lineWidth: 2 * s)
        }
        ctx.stroke(Path(ellipseIn: r2), with: .color(Color.white.opacity(0.5 * alpha)), lineWidth: 1.5 * s)
    }

    private func drawDrumGem(_ ctx: inout GraphicsContext, _ g: HighwayGeometry, d: CGFloat, gem: Gem, sp: Bool, activation: Bool, missed: Bool, fade: Double) {
        let s = g.scale(d)
        let lw = g.laneWidth(laneCount, d)
        let alpha = (missed ? 0.35 : gem.ghost ? 0.6 : 1.0) * fade
        let spActive = run.engine.spActive
        if gem.lane == Lane.kick {
            let l = g.point(-0.96, d), r = g.point(0.96, d)
            let h = lw * 0.13
            let rect = CGRect(x: l.x, y: l.y - h / 2, width: r.x - l.x, height: h)
            var color = gem.doubleKick ? Palette.open : Palette.orange
            if spActive || sp { color = Palette.sp }
            if missed { color = Color(white: 0.4) }
            ctx.fill(Path(roundedRect: rect, cornerRadius: h / 2), with: .color(color.opacity(alpha)))
            return
        }
        let col = gem.lane - 1
        let c = g.point(g.lanePos(col, of: laneCount), d)
        var color = Palette.drum(gem.lane, five: five)
        if spActive || sp { color = Palette.sp }
        if activation { color = Palette.green }
        if missed { color = Color(white: 0.4) }
        let size = lw * (gem.accent ? 0.9 : 0.8)
        if gem.cymbal && !(run.drumMode == .fourLane) {
            // Cymbal: flattened hexagon with a raised edge.
            var p = Path()
            for i in 0..<6 {
                let ang = Double(i) * Double.pi / 3
                let pt = CGPoint(x: c.x + CGFloat(cos(ang)) * size / 2, y: c.y - size * 0.05 + CGFloat(sin(ang)) * size * 0.22)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
            ctx.fill(p, with: .color(color.opacity(alpha)))
            ctx.stroke(p, with: .color(Color.white.opacity(0.8 * alpha)), lineWidth: 2 * s)
        } else {
            let rect = CGRect(x: c.x - size / 2, y: c.y - size * 0.24, width: size, height: size * 0.48)
            ctx.fill(Path(ellipseIn: rect.offsetBy(dx: 0, dy: size * 0.06)), with: .color(Color.black.opacity(0.5 * alpha)))
            ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(alpha)))
            ctx.fill(Path(ellipseIn: rect.insetBy(dx: size * 0.25, dy: size * 0.12)), with: .color(Color.white.opacity((gem.accent ? 0.95 : 0.55) * alpha)))
        }
        if sp && !spActive {
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - size * 0.55, y: c.y - size * 0.3, width: size * 1.1, height: size * 0.6)), with: .color(Palette.sp.opacity(alpha)), lineWidth: 2 * s)
        }
    }

    // MARK: Flames

    private func drawFlames(_ ctx: inout GraphicsContext, _ g: HighwayGeometry, t: Double) {
        let eng = run.engine
        let lw = g.laneWidth(laneCount, 0)
        for col in 0..<laneCount {
            let lanes: [Int] = isDrums ? [col + 1] : six ? [col, col + 3] : [col]
            var age = Double.infinity
            for l in lanes where l < eng.lastHitTime.count { age = min(age, t - eng.lastHitTime[l]) }
            let sustaining = !isDrums && eng.sustains.contains { lanes.contains($0.lane) }
            if age > 0.18 && !sustaining { continue }
            let c = g.point(g.lanePos(col, of: laneCount), 0)
            let k = sustaining ? 0.7 + 0.3 * sin(t * 30 + Double(col)) : 1 - age / 0.18
            let h = lw * CGFloat(0.9 * k + 0.2)
            let color: Color = eng.spActive ? Palette.sp : isDrums ? Palette.drum(col + 1, five: five) : six ? .white : Palette.fret(col)
            let rect = CGRect(x: c.x - lw * 0.4, y: c.y - h, width: lw * 0.8, height: h)
            ctx.fill(Path(ellipseIn: rect), with: .radialGradient(Gradient(colors: [Color.white.opacity(0.9 * k), color.opacity(0.7 * k), color.opacity(0)]), center: CGPoint(x: rect.midX, y: rect.maxY - h * 0.2), startRadius: 0, endRadius: h * 0.8))
        }
        // Kick flash
        if isDrums, t - eng.lastHitTime[Lane.kick] < 0.1 {
            var k = Path()
            k.move(to: g.point(-1, 0)); k.addLine(to: g.point(1, 0))
            ctx.stroke(k, with: .color(Palette.orange.opacity(0.6)), lineWidth: 12)
        }
        // Miss flash on the strikeline
        if t - run.lastMissTime < 0.15 {
            var m = Path()
            m.move(to: g.point(-1, 0)); m.addLine(to: g.point(1, 0))
            ctx.stroke(m, with: .color(Color.red.opacity(0.7 * (1 - (t - run.lastMissTime) / 0.15))), lineWidth: 6)
        }
    }

    // MARK: HUD

    /// Draws text wrapped to `maxWidth`, centred on `at`.
    private func drawCentered(_ ctx: inout GraphicsContext, _ text: Text, at p: CGPoint, maxWidth: CGFloat) {
        let r = ctx.resolve(text)
        let sz = r.measure(in: CGSize(width: maxWidth, height: 200))
        ctx.draw(r, in: CGRect(x: p.x - sz.width / 2, y: p.y - sz.height / 2, width: sz.width, height: sz.height))
    }

    private func drawHUD(_ ctx: inout GraphicsContext, _ g: HighwayGeometry, t: Double, compact: Bool) {
        let eng = run.engine
        let size = g.size
        let lightsOut = mods.lightsOut
        let prep = mods.modchart == .prep
        let bottomW = g.halfWidth
        let side = (size.width - bottomW * 2) / 2
        let roomy = side > 110

        // Multiplier + streak
        let mult = eng.multiplier
        let multColor: Color = eng.spActive ? Palette.sp : [Color.white, Palette.orange, Palette.green, Palette.open, Palette.blue, Palette.red][min(5, eng.multiplier / (eng.spActive ? 2 : 1) - 1)]
        let mc: CGPoint = roomy ? CGPoint(x: g.cx - bottomW - 60, y: g.strikeY - 40) : CGPoint(x: g.safe.left + 42, y: g.safe.top + 84)
        let ringR: CGFloat = 30
        ctx.fill(Path(ellipseIn: CGRect(x: mc.x - ringR, y: mc.y - ringR, width: ringR * 2, height: ringR * 2)), with: .color(Color.black.opacity(0.6)))
        var arc = Path()
        arc.addArc(center: mc, radius: ringR - 3, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * eng.multiplierProgress), clockwise: false)
        ctx.stroke(arc, with: .color(multColor), lineWidth: 5)
        ctx.draw(Text("×\(mult)").font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundColor(multColor), at: mc)
        if !prep {
            ctx.draw(Text("\(eng.combo)").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(.white.opacity(0.85)), at: CGPoint(x: mc.x, y: mc.y + ringR + 12))
        }

        // Star power meter
        let spRect: CGRect = roomy
            ? CGRect(x: g.cx + bottomW + 40, y: g.strikeY - 150, width: 16, height: 140)
            : CGRect(x: size.width - g.safe.right - 26, y: g.safe.top + 70, width: 12, height: 110)
        ctx.fill(Path(roundedRect: spRect, cornerRadius: 6), with: .color(Color.black.opacity(0.6)))
        let fillH = spRect.height * CGFloat(eng.spMeter)
        let fillRect = CGRect(x: spRect.minX, y: spRect.maxY - fillH, width: spRect.width, height: fillH)
        let ready = eng.spMeter >= 0.5
        ctx.fill(Path(roundedRect: fillRect, cornerRadius: 6), with: .color(ready ? Palette.sp : Palette.blue.opacity(0.8)))
        for q in 1..<4 {
            let y = spRect.maxY - spRect.height * CGFloat(q) / 4
            var p = Path(); p.move(to: CGPoint(x: spRect.minX, y: y)); p.addLine(to: CGPoint(x: spRect.maxX, y: y))
            ctx.stroke(p, with: .color(.white.opacity(0.4)), lineWidth: 1)
        }
        ctx.stroke(Path(roundedRect: spRect, cornerRadius: 6), with: .color(ready ? Palette.sp : Color.white.opacity(0.5)), lineWidth: ready ? 2.5 : 1.5)
        if compact || prep { return }

        // Score + stars
        let scorePt = roomy ? CGPoint(x: g.cx - bottomW - 60, y: g.strikeY - 150) : CGPoint(x: size.width / 2, y: g.safe.top + 22)
        ctx.draw(Text(session.practice != nil ? "PRACTICE" : "\(eng.score)").font(.system(size: 26, weight: .heavy, design: .rounded)).monospacedDigit().foregroundColor(.white), at: scorePt)
        if session.practice == nil {
            let stars = eng.stars(base: run.baseScore)
            let starStr = String(repeating: "★", count: min(5, stars)) + String(repeating: "☆", count: max(0, 5 - stars))
            ctx.draw(Text(starStr).font(.system(size: 15)).foregroundColor(stars >= 6 ? Palette.yellow : .white.opacity(0.9)), at: CGPoint(x: scorePt.x, y: scorePt.y + 22))
        }

        // Progress bar
        let pb = CGRect(x: 0, y: g.safe.top, width: size.width * CGFloat(session.songProgress), height: 3)
        ctx.fill(Path(pb), with: .color(Palette.sp.opacity(0.7)))

        // Pop-up text sits beside the highway when there's room, otherwise
        // above its far end — never across the lanes where notes are.
        let midD: CGFloat = 0.5
        let gap = size.width / 2 - g.halfWidth * g.scale(midD)
        let beside = gap > 84
        let textW = beside ? gap - 10 : min(size.width - 20, 260)
        func anchor(right: Bool) -> CGPoint {
            if beside { return CGPoint(x: right ? size.width - gap / 2 : gap / 2, y: g.y(midD)) }
            return CGPoint(x: g.cx, y: max(g.safe.top + 70, g.topY - 14))
        }

        // Solo box
        if let s = run.soloProgress, !lightsOut {
            let pct = s.total > 0 ? s.hit * 100 / s.total : 0
            let p = anchor(right: true)
            let txt = Text("SOLO\n\(s.hit)/\(s.total)  \(pct)%").font(.system(size: 13, weight: .black, design: .rounded)).foregroundColor(Palette.yellow)
            drawCentered(&ctx, txt, at: CGPoint(x: p.x, y: p.y - (beside ? 60 : 0)), maxWidth: textW)
        }

        // Banners
        for (i, b) in run.banners.enumerated() {
            let age = t - b.time
            guard age >= 0 else { continue }
            let a = max(0, min(1, (2.5 - age) / 0.6))
            let p = anchor(right: false)
            let y = p.y - CGFloat(age) * 8 + CGFloat(i) * (beside ? 34 : 0)
            let txt = Text(b.text).font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundColor(Color(b.color).opacity(a))
            drawCentered(&ctx, txt, at: CGPoint(x: p.x, y: y), maxWidth: textW)
            if !b.detail.isEmpty {
                ctx.draw(Text(b.detail).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(.white.opacity(a)), at: CGPoint(x: p.x, y: y + 22))
            }
        }

        // Hit timing
        if settings.showHitTiming {
            let w: CGFloat = 160
            let y = g.strikeY + 34
            var p = Path(); p.move(to: CGPoint(x: g.cx - w / 2, y: y)); p.addLine(to: CGPoint(x: g.cx + w / 2, y: y))
            ctx.stroke(p, with: .color(.white.opacity(0.3)), lineWidth: 2)
            let half = settings.hitWindowMs / 2000
            for h in run.hitOffsets {
                let age = t - h.time
                if age > 2 { continue }
                let x = g.cx + CGFloat(h.offset / half) * w / 2
                var m = Path(); m.move(to: CGPoint(x: x, y: y - 7)); m.addLine(to: CGPoint(x: x, y: y + 7))
                ctx.stroke(m, with: .color((abs(h.offset) < half * 0.4 ? Palette.green : Palette.orange).opacity(1 - age / 2)), lineWidth: 2)
            }
        }
        if session.runs.count > 1 {
            let c = PlayerProfile.colors[run.index % PlayerProfile.colors.count]
            ctx.draw(Text(run.name).font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundColor(c), at: CGPoint(x: size.width / 2, y: g.safe.top + 50))
        }
        if settings.showFPS && run.index == 0 {
            ctx.draw(Text("\(Int(session.fps)) fps").font(.system(size: 11, design: .monospaced)).foregroundColor(.white.opacity(0.6)), at: CGPoint(x: size.width - 36, y: size.height - 12))
        }
        // Lead-in countdown
        if let first = run.track.chords.first?.time, t < first, first - t < 3.2, first - t > 0.4, session.practice == nil || true {
            let n = Int(ceil(first - t - 0.4))
            if n <= 3 && t < first - 0.4 && t > session.startTime + 0.2 {
                ctx.draw(Text("\(n)").font(.system(size: 54, weight: .black, design: .rounded)).foregroundColor(.white.opacity(0.35)), at: CGPoint(x: g.cx, y: g.y(0.45)))
            }
        }
    }
}
