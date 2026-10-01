import SwiftUI

/// Who receives menu input (arrows, D-pad, guitar frets, drum pads) outside
/// gameplay. Screens and sheets register with `.menuNavigation { }`: the most
/// recently shown enabled one gets the input, and when it goes away the one
/// underneath takes over again — no screen has to reinstall anything.
@MainActor
final class MenuFocus {
    static let shared = MenuFocus()

    private struct Entry {
        let id: UUID
        var enabled: Bool
        var handler: (MenuNav) -> Void
    }
    private var stack: [Entry] = []

    func push(_ id: UUID, enabled: Bool, handler: @escaping (MenuNav) -> Void) {
        stack.removeAll { $0.id == id }
        stack.append(Entry(id: id, enabled: enabled, handler: handler))
    }

    /// Keeps a registered handler current (closures capture view values).
    /// Does nothing for a screen that isn't on screen.
    func refresh(_ id: UUID, enabled: Bool, handler: @escaping (MenuNav) -> Void) {
        guard let i = stack.firstIndex(where: { $0.id == id }) else { return }
        stack[i].enabled = enabled
        stack[i].handler = handler
    }

    func remove(_ id: UUID) { stack.removeAll { $0.id == id } }

    func dispatch(_ actions: Set<GameAction>) {
        guard let nav = MenuNav(actions) else { return }
        stack.last(where: \.enabled)?.handler(nav)
    }
}

private struct MenuNavigationModifier: ViewModifier {
    var enabled: Bool
    var handler: (MenuNav) -> Void
    @State private var id = UUID()

    func body(content: Content) -> some View {
        // Re-run with every render of the owning view, so the handler always
        // sees that view's latest values (a plain side effect; nothing published).
        let _ = MenuFocus.shared.refresh(id, enabled: enabled, handler: handler)
        content
            .onAppear { MenuFocus.shared.push(id, enabled: enabled, handler: handler) }
            .onDisappear { MenuFocus.shared.remove(id) }
    }
}

extension View {
    /// Handles menu input while this view is on screen and `enabled`.
    func menuNavigation(enabled: Bool = true, _ handler: @escaping (MenuNav) -> Void) -> some View {
        modifier(MenuNavigationModifier(enabled: enabled, handler: handler))
    }
}
