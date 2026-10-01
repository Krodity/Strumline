import SwiftUI

/// One row of a controller-navigable settings screen.
struct NavRow: Identifiable {
    enum Kind {
        case toggle(Binding<Bool>)
        case slider(Binding<Double>, ClosedRange<Double>, step: Double, format: (Double) -> String)
        /// Options plus the selected index.
        case choice([String], Binding<Int>)
        case button(destructive: Bool, action: () -> Void)
        /// A text field (touch only; skipped by the controller).
        case text(Binding<String>)
        /// Static text.
        case info
        /// Custom content; `action` runs on confirm, `left`/`right` on arrows.
        case custom(AnyView, action: (() -> Void)?, left: (() -> Void)?, right: (() -> Void)?)
    }
    var id: String
    var section: String
    var title: String
    var detail: String? = nil
    var kind: Kind

    var focusable: Bool {
        switch kind {
        case .info, .text: return false
        default: return true
        }
    }
}

/// A settings list that works with touch *and* with arrows/D-pad: up/down
/// moves the highlight, left/right changes the value, green (confirm)
/// selects, red (back) leaves.
struct NavForm: View {
    var rows: [NavRow]
    var onBack: () -> Void
    @State private var focus: String?
    @State private var scroller: ScrollViewProxy?

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(sections, id: \.self) { sec in
                    Section(sec) {
                        ForEach(rows.filter { $0.section == sec }) { row in
                            rowView(row)
                                .id(row.id)
                                .listRowBackground(focus == row.id ? Palette.orange.opacity(0.22) : Color.white.opacity(0.05))
                                .overlay(alignment: .leading) {
                                    if focus == row.id {
                                        Rectangle().fill(Palette.orange).frame(width: 3).padding(.leading, -20)
                                    }
                                }
                        }
                    }
                }
            }
            .onAppear { scroller = proxy }
        }
        .menuNavigation { nav in navigate(nav) }
    }

    private var sections: [String] {
        var out: [String] = []
        for r in rows where !out.contains(r.section) { out.append(r.section) }
        return out
    }

    @ViewBuilder private func rowView(_ row: NavRow) -> some View {
        switch row.kind {
        case .toggle(let b):
            Toggle(isOn: b) { label(row) }
        case .slider(let b, let range, let step, let format):
            SliderRow(title: row.title, value: b, range: range, step: step, format: format)
        case .choice(let options, let sel):
            Picker(selection: sel) {
                ForEach(options.indices, id: \.self) { Text(options[$0]).tag($0) }
            } label: { label(row) }
        case .button(let destructive, let action):
            Button(role: destructive ? .destructive : nil, action: action) { label(row) }
        case .text(let b):
            TextField(row.title, text: b)
        case .info:
            label(row)
        case .custom(let view, _, _, _):
            view
        }
    }

    private func label(_ row: NavRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.title)
            if let d = row.detail { Text(d).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func navigate(_ nav: MenuNav) {
        let navRows = rows.filter(\.focusable)
        guard !navRows.isEmpty else { if nav == .back { onBack() }; return }
        let idx = focus.flatMap { f in navRows.firstIndex { $0.id == f } }
        func move(_ d: Int) {
            let i = idx.map { max(0, min(navRows.count - 1, $0 + d)) } ?? 0
            focus = navRows[i].id
            withAnimation(.easeOut(duration: 0.15)) { scroller?.scrollTo(navRows[i].id, anchor: .center) }
        }
        switch nav {
        case .up: move(-1)
        case .down: move(1)
        case .pageUp: move(-6)
        case .pageDown: move(6)
        case .back: onBack()
        case .left, .right, .confirm:
            guard let i = idx else { move(0); return }
            adjust(navRows[i], nav)
        }
    }

    private func adjust(_ row: NavRow, _ nav: MenuNav) {
        switch row.kind {
        case .toggle(let b):
            b.wrappedValue.toggle()
        case .slider(let b, let range, let step, _):
            if nav == .confirm { return }
            // Bigger steps on wide ranges so 0.25-10× doesn't take 200 presses.
            let s = (range.upperBound - range.lowerBound) > 20 ? max(step, 5) : (range.upperBound - range.lowerBound) > 4 ? max(step, 0.25) : step
            let v = b.wrappedValue + (nav == .right ? s : -s)
            b.wrappedValue = min(range.upperBound, max(range.lowerBound, (v / step).rounded() * step))
        case .choice(let options, let sel):
            guard !options.isEmpty else { return }
            let d = nav == .left ? -1 : 1
            sel.wrappedValue = (sel.wrappedValue + d + options.count) % options.count
        case .button(_, let action):
            if nav == .confirm { action() }
        case .custom(_, let action, let left, let right):
            switch nav {
            case .confirm: action?()
            case .left: left?()
            case .right: right?()
            default: break
            }
        case .text, .info:
            break
        }
    }
}

extension NavRow {
    /// Choice row over any Hashable options.
    static func pick<T: Hashable>(_ id: String, _ section: String, _ title: String, detail: String? = nil, options: [T], label: @escaping (T) -> String, selection: Binding<T>) -> NavRow {
        let idx = Binding<Int>(
            get: { options.firstIndex(of: selection.wrappedValue) ?? 0 },
            set: { if options.indices.contains($0) { selection.wrappedValue = options[$0] } })
        return NavRow(id: id, section: section, title: title, detail: detail, kind: .choice(options.map(label), idx))
    }
}
