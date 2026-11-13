import SwiftUI

enum SeekerStyle: String, CaseIterable, Identifiable {
    case waveform
    case classic
    case ring
    case bars
    case digital
    case pill
    case neonLine
    case dotTrack
    case segmented
    case minimal
    case ruler
    /// Fully parametric — see `CustomScrubberView`/`CustomSeekerSettings`.
    /// Every other case here is a fixed, hand-designed look; this is the one
    /// a user actually tunes (track height/shape/color/thumb/glow) instead
    /// of picking the closest preset.
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .waveform:  return "Mirror Wave"
        case .classic:   return "Glide"
        case .ring:      return "Orbit Dial"
        case .bars:      return "Skyline"
        case .digital:   return "Flip Clock"
        case .pill:      return "Capsule Meter"
        case .neonLine:  return "Neon Tube"
        case .dotTrack:  return "Beads"
        case .segmented: return "Chapters"
        case .minimal:   return "Hairline"
        case .ruler:     return "Tape Measure"
        case .custom:    return "Custom"
        }
    }

    var iconName: String {
        switch self {
        case .waveform:  return "waveform"
        case .classic:   return "slider.horizontal.below.rectangle"
        case .ring:      return "circle.circle"
        case .bars:      return "chart.bar.xaxis"
        case .digital:   return "timer"
        case .pill:      return "rectangle.fill"
        case .neonLine:  return "bolt.horizontal"
        case .dotTrack:  return "circle.grid.3x3.fill"
        case .segmented: return "square.grid.3x1.fill"
        case .minimal:   return "minus"
        case .ruler:     return "ruler"
        case .custom:    return "slider.horizontal.3"
        }
    }
}
