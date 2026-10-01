import SwiftUI
import StrumCore

struct ControlsView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject private var input = InputManager.shared

    private func capture(_ a: GameAction) {
        input.beginCapture(a) { b in
            var m = input.bindings
            var list = m.map[a] ?? []
            if !list.contains(b) { list.append(b) }
            m.map[a] = list
            input.bindings = m
        }
    }

    private func removeLast(_ a: GameAction) {
        var m = input.bindings
        if m.map[a]?.isEmpty == false { m.map[a]?.removeLast() }
        input.bindings = m
    }

    private func bindingRows(_ section: String, _ actions: [GameAction]) -> [NavRow] {
        actions.map { a in
            let view = AnyView(
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(a.displayName).font(.subheadline.bold())
                        Spacer()
                        Button { capture(a) } label: { Image(systemName: "plus.circle.fill") }.buttonStyle(.borderless)
                    }
                    let list = input.bindings.map[a] ?? []
                    if list.isEmpty {
                        Text("Unbound").font(.caption).foregroundStyle(.tertiary)
                    } else {
                        FlowChips(items: list.map(\.label)) { i in
                            var m = input.bindings
                            m.map[a]?.remove(at: i)
                            input.bindings = m
                        }
                    }
                }
                .padding(.vertical, 2))
            return NavRow(id: "b-" + a.rawValue, section: section, title: a.displayName, kind: .custom(view, action: { capture(a) }, left: { removeLast(a) }, right: { capture(a) }))
        }
    }

    private var rows: [NavRow] {
        var r: [NavRow] = [
            NavRow(id: "help", section: "Connected", title: "Confirm / → adds an input to the highlighted action; ← removes its last one.", detail: "Guitars and kits work when iOS sees them as a game controller (Xbox/PlayStation/Switch/MFi modes). Drum kits also work over USB or Bluetooth MIDI.", kind: .info),
        ]
        for d in input.devices {
            r.append(NavRow(id: "dev-" + d.id, section: "Connected", title: d.name, kind: .info))
        }
        r += bindingRows("Guitar", GameAction.guitar)
        r += bindingRows("Drums", GameAction.drums)
        r += bindingRows("Menus", GameAction.menu)
        r.append(NavRow(id: "reset", section: "Reset", title: "Reset to defaults", kind: .button(destructive: true) { input.bindings = .defaults }))
        return r
    }

    var body: some View {
        NavForm(rows: rows, onBack: { input.cancelCapture(); app.screen = .menu })
            .navigationTitle("Controls")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { input.cancelCapture(); app.screen = .menu } label: { Label("Menu", systemImage: "chevron.left") }
                }
            }
            .overlay {
                if let a = input.capturing {
                    VStack(spacing: 14) {
                        Text("Press an input for").foregroundStyle(.secondary)
                        Text(a.displayName).font(.title2.bold())
                        Text(a == .whammy ? "Move the whammy bar or stick" : "Button, key, stick direction or drum pad").font(.caption).foregroundStyle(.secondary)
                        Button("Cancel") { input.cancelCapture() }
                    }
                    .padding(30)
                    .background(RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial))
                }
            }
    }

    private func icon(_ k: InputDevice.Kind) -> String {
        switch k {
        case .controller: return "gamecontroller.fill"
        case .keyboard: return "keyboard"
        case .midi: return "pianokeys"
        case .touch: return "hand.tap"
        }
    }

}

/// Removable chips that wrap onto new lines.
struct FlowChips: View {
    var items: [String]
    var onRemove: (Int) -> Void

    var body: some View {
        ChipLayout(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, s in
                HStack(spacing: 4) {
                    Text(s).font(.caption).lineLimit(1)
                    Button { onRemove(i) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.1)))
            }
        }
    }
}

struct ChipLayout: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
