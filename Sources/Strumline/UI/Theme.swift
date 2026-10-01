import SwiftUI
import GameController

/// One place for the menu look: surfaces, radii, type, and the small set of
/// components every screen builds from. Gameplay colours live in `Palette`.
enum Theme {
    static let accent = Palette.orange

    /// White overlays on the dark background, lightest to strongest.
    enum Surface {
        static let row = Color.white.opacity(0.04)
        static let card = Color.white.opacity(0.07)
        static let control = Color.white.opacity(0.10)
        static let stroke = Color.white.opacity(0.14)
        static let selected = Theme.accent.opacity(0.28)
    }

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let sheet: CGFloat = 24
    }

    enum Fonts {
        static let display = Font.system(size: 34, weight: .black, design: .rounded)
        static let title = Font.system(size: 24, weight: .black, design: .rounded)
        static let heading = Font.system(size: 17, weight: .bold, design: .rounded)
        static let button = Font.system(size: 18, weight: .bold, design: .rounded)
        static let label = Font.caption.weight(.bold)
        static let number = Font.system(size: 20, weight: .bold, design: .rounded).monospacedDigit()
    }

    static let focusWidth: CGFloat = 2.5
}

// MARK: - Components

/// A grouped block of content on a soft surface.
struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.Surface.card))
    }
}

/// Small all-caps-feeling label above a group ("Instrument", "Difficulty").
struct SectionLabel: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Theme.Fonts.label).foregroundStyle(.secondary)
    }
}

/// A pill: active modifiers, tags. `warn` uses yellow instead of the accent.
struct Chip: View {
    var text: String
    var symbol: String? = nil
    var selected = true
    var warn = false
    var body: some View {
        let tint = warn ? Palette.yellow : Theme.accent
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
            Text(text).font(.caption.bold()).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(selected ? tint.opacity(0.35) : Theme.Surface.control))
        .overlay(Capsule().stroke(selected ? tint : Theme.Surface.stroke, lineWidth: 1.5))
    }
}

/// Background + outline for a choosable tile (instrument, difficulty…).
struct TileBackground: ViewModifier {
    var selected: Bool
    var radius: CGFloat = Theme.Radius.medium
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius).fill(selected ? Theme.Surface.selected : Theme.Surface.control))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(selected ? Theme.accent : .clear, lineWidth: 2))
    }
}

/// Controller/keyboard highlight around the focused element.
struct FocusRing: ViewModifier {
    var on: Bool
    var radius: CGFloat = Theme.Radius.large
    var inset: CGFloat = 0
    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: radius)
                .stroke(Theme.accent, lineWidth: on ? Theme.focusWidth : 0)
                .padding(inset)
        )
    }
}

extension View {
    func tile(selected: Bool, radius: CGFloat = Theme.Radius.medium) -> some View { modifier(TileBackground(selected: selected, radius: radius)) }
    func focusRing(_ on: Bool, radius: CGFloat = Theme.Radius.large, inset: CGFloat = 0) -> some View { modifier(FocusRing(on: on, radius: radius, inset: inset)) }
}

/// The back control every full screen uses: chevron + where it goes.
struct BackButton: View {
    var title = "Menu"
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.body.weight(.semibold))
                Text(title)
            }
        }
    }
}

/// Header for screens outside a NavigationStack (song list): back, title,
/// then any trailing controls.
struct ScreenHeader<Trailing: View>: View {
    var title: String
    var onBack: () -> Void
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 12) {
            BackButton(action: onBack)
            Text(title).font(Theme.Fonts.title).lineLimit(1)
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension View {
    /// Title + the standard back button for screens inside a NavigationStack.
    func screenChrome(_ title: String, onBack: @escaping () -> Void) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden()
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { BackButton(action: onBack) } }
    }

    /// Title + a single Done button for sheets.
    func sheetChrome(_ title: String, done: @escaping () -> Void) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: done).bold() } }
    }
}

// MARK: - Button legend

/// What the buttons do on this screen, shown only when a controller,
/// keyboard or kit is connected (touch users don't need it). Replaces long
/// instruction sentences. Green/red match guitar frets and A/B on pads.
struct ControlLegend: View {
    enum Item: Hashable {
        case move, change, page, select, back
        var symbol: String {
            switch self {
            case .move: return "arrow.up.arrow.down"
            case .change: return "arrow.left.arrow.right"
            case .page: return "arrow.left.arrow.right"
            case .select: return "circle.fill"
            case .back: return "circle.fill"
            }
        }
        var title: String {
            switch self {
            case .move: return "Move"
            case .change: return "Change"
            case .page: return "Page"
            case .select: return "Select"
            case .back: return "Back"
            }
        }
        var tint: Color {
            switch self {
            case .select: return Palette.green
            case .back: return Palette.red
            default: return .secondary
            }
        }
    }

    var items: [Item]
    @ObservedObject private var input = InputManager.shared

    init(_ items: [Item]) { self.items = items }

    var body: some View {
        if input.hasPhysicalInput {
            HStack(spacing: 16) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 5) {
                        Image(systemName: item.symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(item.tint)
                        Text(item.title)
                    }
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(.ultraThinMaterial))
            .frame(maxWidth: .infinity)
            .padding(.bottom, 4)
            .allowsHitTesting(false)
        }
    }
}
