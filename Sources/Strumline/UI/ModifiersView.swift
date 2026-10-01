import SwiftUI
import StrumCore

/// Clone Hero's modifier list (song speed is on the setup panel).
struct ModifiersView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    var kind: InstrumentKind
    /// Whose settings to edit (default: player 1's).
    var mods: Binding<Modifiers>? = nil

    private var m: Binding<Modifiers> { mods ?? $app.settings.modifiers }

    private var rows: [NavRow] {
        func t(_ id: String, _ sec: String, _ title: String, _ detail: String, _ b: Binding<Bool>) -> NavRow {
            NavRow(id: id, section: sec, title: title, detail: detail, kind: .toggle(b))
        }
        // Song speed lives on the setup panel (one song, one speed), not here.
        var r: [NavRow] = []
        if kind != .drums {
            r += [
                t("auto", "Guitar", "Auto Strum", "Strums for you — just fret. Scores are still saved.", m.autoStrum),
                .pick("notes", "Guitar", "Note type", detail: "All Taps is recommended for keyboard and touch players.", options: Modifiers.NoteMod.allCases, label: { $0.displayName }, selection: m.notes),
                t("h2t", "Guitar", "HOPOs to Taps", "Turns all HOPO notes into tap notes.", m.hoposToTaps),
                t("prec", "Guitar", "Precision Mode", "Smaller hit window that shrinks as the notes get faster; stricter HOPOs and taps.", m.precision),
                t("drunk", "Guitar", "Drunk Mode", "Easier HOPOs and taps, anchoring in both directions. Disables score saving.", m.drunk),
                t("brutal", "Guitar", "Brutal Mode", "Notes fade out past a point that gets closer the better you're doing.", m.brutal),
                t("dropless", "Guitar", "Dropless Sustains", "Let go of a sustain early and you lose your combo.", m.droplessSustains),
                t("strumless", "Guitar", "Strumless HOPOs", "Strumming a HOPO or tap is an overstrum.", m.strumlessHopos),
                t("double", "Guitar", "Double Notes", "Adds a note to each note or chord, up to 3.", m.doubleNotes),
                t("noghost", "Guitar", "No Ghosting", "Blocks ghosting frets between HOPOs, to a degree.", m.noGhosting),
                t("deadghost", "Guitar", "Deadly Ghosting", "Ghosting too much breaks your combo.", m.deadlyGhosting),
            ]
        } else {
            r += [
                t("prec", "Drums", "Precision Mode", "Smaller hit window that shrinks further than normal.", m.precision),
                t("brutal", "Drums", "Brutal Mode", "Notes fade out past a point that gets closer the better you're doing.", m.brutal),
                t("dyn", "Drums", "Deadly Dynamics", "Accents must be hit hard and ghost notes soft (velocity-sensitive kits).", m.deadlyDynamics),
                t("2x", "Drums", "2x Kick", "Include Expert+ double-kick notes.", m.twoXKick),
                t("nokick", "Drums", "No Kick", "Removes kick notes.", m.noKick),
                t("onlykick", "Drums", "Only Kicks", "Turns every note into a kick.", m.onlyKicks),
            ]
        }
        r += [
            t("mirror", "Chart", "Mirror Mode", "Mirrors the chart without mirroring the strikeline.", m.mirror),
            t("shuffle", "Chart", "Note Shuffle", "Randomizes note placement — the same way every time.", m.shuffle),
            t("lights", "Display", "Lights Out", "Hides the highway, including the notes.", m.lightsOut),
            .pick("modchart", "Display", "Modchart", options: Modifiers.Modchart.allCases, label: { $0.displayName }, selection: m.modchart),
            NavRow(id: "reset", section: "Reset", title: "Reset all modifiers", detail: "Song speed is kept", kind: .button(destructive: true) {
                let speed = m.wrappedValue.songSpeed
                m.wrappedValue = Modifiers()
                m.wrappedValue.songSpeed = speed
            }),
        ]
        return r
    }

    var body: some View {
        NavigationStack {
            NavForm(rows: rows, onBack: { dismiss() })
                .sheetChrome("Modifiers") { dismiss() }
        }
    }
}
