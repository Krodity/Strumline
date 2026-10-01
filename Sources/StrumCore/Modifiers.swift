import Foundation

/// Clone Hero's song modifiers (wiki.clonehero.net → Song Modifiers), plus
/// the speed settings chosen on the same screen.
public struct Modifiers: Codable, Sendable, Equatable {
    public enum NoteMod: String, Codable, Sendable, CaseIterable {
        case none, allStrums, allHopos, allTaps, allOpens
        public var displayName: String {
            switch self {
            case .none: return "None"
            case .allStrums: return "All Strums"
            case .allHopos: return "All HOPOs"
            case .allTaps: return "All Taps"
            case .allOpens: return "All Opens"
            }
        }
    }
    public enum Modchart: String, Codable, Sendable, CaseIterable {
        case off, full, lite, prep
        public var displayName: String {
            switch self {
            case .off: return "Off"
            case .full: return "Modchart Full"
            case .lite: return "Modchart Lite"
            case .prep: return "Modchart Prep"
            }
        }
    }
    // Shared
    public var precision = false
    public var brutal = false
    public var mirror = false
    public var shuffle = false
    public var lightsOut = false
    public var modchart: Modchart = .off
    // Guitar
    public var notes: NoteMod = .none
    public var hoposToTaps = false
    public var deadlyGhosting = false
    public var drunk = false
    public var droplessSustains = false
    public var strumlessHopos = false
    public var doubleNotes = false
    public var noGhosting = false
    public var autoStrum = false
    // Drums
    public var deadlyDynamics = false
    public var twoXKick = true
    public var noKick = false
    public var onlyKicks = false
    // Speeds
    /// Song playback speed, 0.25 … 3.0 (1 = normal).
    public var songSpeed: Double = 1
    public init() {}

    /// Drunk Mode doesn't save scores. (Clone Hero also blocks Auto Strum;
    /// here Auto Strum scores are saved, by request.)
    public var disablesScoreSaving: Bool { drunk }

    public var activeNames: [String] {
        var n: [String] = []
        if notes != .none { n.append(notes.displayName) }
        if hoposToTaps { n.append("HOPOs to Taps") }
        if precision { n.append("Precision") }
        if brutal { n.append("Brutal") }
        if deadlyGhosting { n.append("Deadly Ghosting") }
        if drunk { n.append("Drunk") }
        if droplessSustains { n.append("Dropless Sustains") }
        if strumlessHopos { n.append("Strumless HOPOs") }
        if doubleNotes { n.append("Double Notes") }
        if noGhosting { n.append("No Ghosting") }
        if autoStrum { n.append("Auto Strum") }
        if deadlyDynamics { n.append("Deadly Dynamics") }
        if noKick { n.append("No Kick") }
        if onlyKicks { n.append("Only Kicks") }
        if mirror { n.append("Mirror") }
        if shuffle { n.append("Shuffle") }
        if lightsOut { n.append("Lights Out") }
        if modchart != .off { n.append(modchart.displayName) }
        if songSpeed != 1 { n.append("\(Int((songSpeed * 100).rounded()))% speed") }
        return n
    }
}

/// Deterministic PRNG so shuffled charts are the same every time.
struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
}

public enum DrumPlayMode: String, Codable, Sendable, CaseIterable {
    case fourLane, fourLanePro, fiveLane
    public var displayName: String {
        switch self {
        case .fourLane: return "4-Lane"
        case .fourLanePro: return "4-Lane Pro"
        case .fiveLane: return "5-Lane"
        }
    }
    public var laneCount: Int { self == .fiveLane ? 5 : 4 }
}
