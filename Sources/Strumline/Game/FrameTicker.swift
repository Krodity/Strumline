import SwiftUI
import QuartzCore

/// Drives the highway from a CADisplayLink that asks for the display's
/// maximum refresh rate (120 Hz on ProMotion) instead of SwiftUI's default
/// animation cadence.
final class FrameTicker: ObservableObject {
    @Published private(set) var tick: UInt64 = 0
    private var link: CADisplayLink?

    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(step))
        let maxFPS = Float(UIScreen.main.maximumFramesPerSecond)
        l.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maxFPS), maximum: maxFPS, preferred: maxFPS)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step() { tick &+= 1 }
}

/// Only this view re-renders every frame.
struct HighwayCanvas: View {
    let session: GameSession
    let touchOn: Bool
    @StateObject private var ticker = FrameTicker()

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            _ = ticker.tick
            let t = session.frame(host: CACurrentMediaTime())
            // One column per player, side by side.
            let n = session.runs.count
            let colW = size.width / CGFloat(n)
            for run in session.runs {
                var c = ctx
                c.translateBy(x: colW * CGFloat(run.index), y: 0)
                if n > 1 { c.clip(to: Path(CGRect(x: 0, y: 0, width: colW, height: size.height))) }
                var r = HighwayRenderer(session: session, run: run)
                r.draw(&c, size: CGSize(width: colW, height: size.height), time: t, touchControls: GameView.touchEnabled(session, run, touchOn))
            }
        }
        .onAppear { ticker.start() }
        .onDisappear { ticker.stop() }
    }
}
