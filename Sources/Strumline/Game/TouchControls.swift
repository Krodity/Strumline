import SwiftUI
import UIKit
import StrumCore

/// Multi-touch play surface. Uses raw UITouch timestamps (same clock as the
/// audio host time) so taps are judged exactly when the finger landed.
struct TouchControls: UIViewRepresentable {
    var kind: InstrumentKind
    var drumMode: DrumPlayMode
    var settings: GameSettings

    func makeUIView(context: Context) -> TouchControlsView {
        let v = TouchControlsView()
        v.backgroundColor = .clear
        v.isMultipleTouchEnabled = true
        v.contentMode = .redraw  // re-lay out the guides on rotation
        return v
    }

    func updateUIView(_ v: TouchControlsView, context: Context) {
        v.kind = kind
        v.drumMode = drumMode
        v.settings = settings
        v.setNeedsDisplay()
    }
}

final class TouchControlsView: UIView {
    enum Zone: Equatable {
        case fret(Int)
        case strum
        case pad(GameAction)
    }

    var kind: InstrumentKind = .fiveFret
    var drumMode: DrumPlayMode = .fourLanePro
    var settings = GameSettings()

    private var touchZones: [ObjectIdentifier: (zone: Zone, start: CGPoint)] = [:]
    private var lastAutoStrum: Double = 0
    private let input = InputManager.shared

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }

    private var geometry: HighwayGeometry {
        HighwayGeometry.make(size: bounds.size, settings: settings, touch: kind != .drums && settings.touchMode == .fretStrum ? .fretStrum : .lanes)
    }

    private var fretCount: Int { kind == .sixFret ? 6 : 5 }
    private var fretStrum: Bool { settings.touchMode == .fretStrum && kind != .drums }

    // MARK: Layout

    /// Fret+Strum mode: big buttons bottom-left, strum zone bottom-right.
    private var fretStrumRects: (frets: [CGRect], strum: CGRect) {
        let h = HighwayGeometry.fretStrumHeight(bounds.size)
        let top = bounds.height - h
        let fretsW = bounds.width * (bounds.width > bounds.height ? 0.7 : 0.68)
        var rects: [CGRect] = []
        if kind == .sixFret {
            let w = fretsW / 3
            for row in 0..<2 {
                for c in 0..<3 {
                    let col = settings.leftyFlip ? 2 - c : c
                    rects.append(CGRect(x: CGFloat(col) * w + 3, y: top + CGFloat(row) * h / 2 + 3, width: w - 6, height: h / 2 - 6))
                }
            }
        } else {
            let w = fretsW / 5
            for i in 0..<5 {
                let col = settings.leftyFlip ? 4 - i : i
                rects.append(CGRect(x: CGFloat(col) * w + 3, y: top + 3, width: w - 6, height: h - 6))
            }
        }
        return (rects, CGRect(x: fretsW + 6, y: top + 3, width: bounds.width - fretsW - 9, height: h - 6))
    }

    private func zone(at p: CGPoint) -> Zone? {
        if kind == .drums { return drumZone(at: p) }
        if fretStrum {
            let r = fretStrumRects
            if let i = r.frets.firstIndex(where: { $0.contains(p) }) { return .fret(i) }
            if r.strum.contains(p) { return .strum }
            return nil
        }
        // Tap lanes: the strikeline columns and everything below them.
        let g = geometry
        let lw = g.laneWidth(kind == .sixFret ? 3 : 5, 0)
        guard p.y > g.strikeY - lw * 1.9 else { return nil }
        let left = g.cx - g.halfWidth, right = g.cx + g.halfWidth
        if p.x < left || p.x > right { return .strum }  // sides: strum (open notes)
        var col = Int((p.x - left) / (right - left) * CGFloat(kind == .sixFret ? 3 : 5))
        col = max(0, min(kind == .sixFret ? 2 : 4, col))
        if settings.leftyFlip { col = (kind == .sixFret ? 2 : 4) - col }
        if kind == .sixFret {
            return .fret(p.y < g.strikeY + (bounds.height - g.strikeY) * 0.35 ? col : col + 3)
        }
        return .fret(col)
    }

    private func drumZone(at p: CGPoint) -> Zone? {
        let g = geometry
        let kickTop = bounds.height - min(110, bounds.height * 0.13)
        if p.y > kickTop { return .pad(.kick) }
        let lanes = drumMode.laneCount
        let lw = g.laneWidth(lanes, 0)
        guard p.y > g.strikeY - lw * 2.0 else { return nil }
        let left = g.cx - g.halfWidth * 1.1, right = g.cx + g.halfWidth * 1.1
        if p.x < left || p.x > right { return .pad(.kick) }
        var col = Int((p.x - left) / (right - left) * CGFloat(lanes))
        col = max(0, min(lanes - 1, col))
        if settings.leftyFlip { col = lanes - 1 - col }
        let upper = p.y < g.strikeY + (kickTop - g.strikeY) * 0.25
        if drumMode == .fiveLane {
            return .pad([GameAction.padRed, .padYellow, .padBlue, .padOrange, .padGreen][col])
        }
        let pro = drumMode == .fourLanePro
        switch col {
        case 0: return .pad(.padRed)
        case 1: return .pad(pro && upper ? .cymYellow : .padYellow)
        case 2: return .pad(pro && upper ? .cymBlue : .padBlue)
        default: return .pad(pro && upper ? .cymGreen : .padGreen)
        }
    }

    private func fretAction(_ i: Int) -> GameAction { [GameAction.fret1, .fret2, .fret3, .fret4, .fret5, .fret6][i] }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self)
            guard let z = zone(at: p) else { continue }
            touchZones[ObjectIdentifier(t)] = (z, p)
            press(z, time: t.timestamp)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let id = ObjectIdentifier(t)
            guard let cur = touchZones[id] else { continue }
            let p = t.location(in: self)
            if case .fret = cur.zone {
                // Whammy: wiggle a held fret vertically.
                let dy = Double((p.y - cur.start.y) / 40)
                input.inject(.whammy, down: true, value: max(-1, min(1, dy)), time: t.timestamp)
                // Sliding to another fret = hammer-on/pull-off (no strum).
                if let z = zone(at: p), z != cur.zone, case .fret = z {
                    release(cur.zone, time: t.timestamp)
                    touchZones[id] = (z, p)
                    if case .fret(let i) = z { input.inject(fretAction(i), down: true, time: t.timestamp) }
                }
            } else if case .strum = cur.zone, fretStrum {
                // Swiping the strum zone strums on each direction change.
                if abs(p.y - cur.start.y) > 28 {
                    input.inject(.strumDown, down: true, time: t.timestamp)
                    input.inject(.strumDown, down: false, time: t.timestamp)
                    touchZones[id] = (cur.zone, p)
                }
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let id = ObjectIdentifier(t)
            if let cur = touchZones.removeValue(forKey: id) { release(cur.zone, time: t.timestamp) }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    private func press(_ z: Zone, time: Double) {
        switch z {
        case .fret(let i):
            input.inject(fretAction(i), down: true, time: time)
            if !fretStrum {
                // Tap mode: one strum per group of simultaneous touches, so a
                // chord hit with two fingers isn't an overstrum.
                if time - lastAutoStrum > 0.035 {
                    lastAutoStrum = time
                    input.inject(.strumDown, down: true, time: time + 0.0005)
                    input.inject(.strumDown, down: false, time: time + 0.0006)
                }
            }
        case .strum:
            input.inject(.strumDown, down: true, time: time)
            input.inject(.strumDown, down: false, time: time)
        case .pad(let a):
            input.inject(a, down: true, time: time)
        }
    }

    private func release(_ z: Zone, time: Double) {
        switch z {
        case .fret(let i): input.inject(fretAction(i), down: false, time: time)
        case .strum: break
        case .pad(let a): input.inject(a, down: false, time: time)
        }
    }

    // MARK: Drawing (guides only; the highway draws the targets)

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let g = geometry
        if kind == .drums {
            let kickTop = bounds.height - min(110, bounds.height * 0.13)
            ctx.setFillColor(UIColor.orange.withAlphaComponent(0.18).cgColor)
            ctx.fill(CGRect(x: 0, y: kickTop, width: bounds.width, height: bounds.height - kickTop))
            let label = "KICK" as NSString
            label.draw(at: CGPoint(x: bounds.width / 2 - 18, y: kickTop + 8), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 14), .foregroundColor: UIColor.white.withAlphaComponent(0.5)])
            if drumMode == .fourLanePro {
                let y = g.strikeY + (kickTop - g.strikeY) * 0.25
                ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.25).cgColor)
                ctx.setLineDash(phase: 0, lengths: [6, 6])
                ctx.move(to: CGPoint(x: g.cx - g.halfWidth * 0.5, y: y))
                ctx.addLine(to: CGPoint(x: g.cx + g.halfWidth * 1.08, y: y))
                ctx.strokePath()
                ("cymbals ↑  toms ↓" as NSString).draw(at: CGPoint(x: g.cx + g.halfWidth * 0.2, y: y + 4), withAttributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.white.withAlphaComponent(0.4)])
            }
            return
        }
        if fretStrum {
            let r = fretStrumRects
            let colors: [UIColor] = kind == .sixFret
                ? [UIColor(white: 0.2, alpha: 1), UIColor(white: 0.2, alpha: 1), UIColor(white: 0.2, alpha: 1), .white, .white, .white]
                : [.systemGreen, .systemRed, .systemYellow, .systemBlue, .systemOrange]
            for (i, fr) in r.frets.enumerated() {
                let path = UIBezierPath(roundedRect: fr, cornerRadius: 14)
                colors[i].withAlphaComponent(0.35).setFill()
                path.fill()
                colors[i].withAlphaComponent(0.9).setStroke()
                path.lineWidth = 2
                path.stroke()
            }
            let sp = UIBezierPath(roundedRect: r.strum, cornerRadius: 18)
            UIColor.white.withAlphaComponent(0.1).setFill()
            sp.fill()
            ("STRUM" as NSString).draw(at: CGPoint(x: r.strum.midX - 26, y: r.strum.midY - 9), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 16), .foregroundColor: UIColor.white.withAlphaComponent(0.5)])
        } else {
            // Tap mode hint: side areas strum (open notes).
            let left = g.cx - g.halfWidth
            if left > 40 {
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 11), .foregroundColor: UIColor.white.withAlphaComponent(0.3)]
                ("open\nstrum" as NSString).draw(in: CGRect(x: left / 2 - 20, y: g.strikeY, width: 60, height: 40), withAttributes: attrs)
            }
        }
    }
}
