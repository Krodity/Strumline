import SwiftUI
import StrumCore

struct ControlsView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject private var input = InputManager.shared
    /// Leaves the screen (Controls lives inside Settings).
    var onBack: () -> Void = {}
    /// Which group of bindings is shown.
    @State private var group = BindingGroup.guitar

    enum BindingGroup: String, CaseIterable {
        case guitar, drums, menus
        var title: String { rawValue.capitalized }
        var actions: [GameAction] {
            switch self {
            case .guitar: return GameAction.guitar
            case .drums: return GameAction.drums
            case .menus: return GameAction.menu
            }
        }
    }
    /// Reset takes two presses: the first arms it.
    @State private var resetArmed = false

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
                        FlowChips(items: list.map { ($0.symbol, $0.label) }) { i in
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
            NavRow(id: "help", section: "Connected", title: "Select or → adds an input · ← removes the last", detail: "Guitars and kits work in Xbox / PlayStation / Switch controller modes; drum kits also over USB or Bluetooth MIDI.", kind: .info),
        ]
        for d in input.devices {
            r.append(NavRow(id: "dev-" + d.id, section: "Connected", title: d.name, symbol: icon(d.kind), kind: .info))
        }
        r.append(.pick("group", "Bindings", "Show", options: BindingGroup.allCases, label: { $0.title }, selection: $group))
        r += bindingRows(group.title, group.actions)
        r.append(NavRow(id: "reset", section: "Reset", title: resetArmed ? "Press again to replace every binding" : "Reset to defaults", kind: .button(destructive: true) {
            guard resetArmed else { resetArmed = true; return }
            resetArmed = false
            input.bindings = .defaults
        }))
        return r
    }

    var body: some View {
        NavForm(rows: rows, onBack: { input.cancelCapture(); onBack() })
            .screenChrome("Controls", back: "Settings") { input.cancelCapture(); onBack() }
            .overlay {
                if let a = input.capturing {
                    VStack(spacing: 14) {
                        Text("Press an input for").foregroundStyle(.secondary)
                        Text(a.displayName).font(.title2.bold())
                        Text(a == .whammy ? "Move the whammy bar or stick" : "Button, key, stick direction or drum pad").font(.caption).foregroundStyle(.secondary)
                        Button("Cancel") { input.cancelCapture() }
                    }
                    .padding(30)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.sheet).fill(.ultraThinMaterial))
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
    /// (SF Symbol, text) per chip.
    var items: [(String, String)]
    var onRemove: (Int) -> Void

    var body: some View {
        ChipLayout(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(spacing: 4) {
                    Image(systemName: item.0).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(item.1).font(.caption).lineLimit(1)
                    Button { onRemove(i) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Theme.Surface.control))
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
