import Foundation

// MARK: - SpectralEQMatcher
//
// Picks an EQ preset by measuring the track, instead of guessing from its tags.
//
// Auto EQ chose from the genre STRING, falling back to a tempo band. Both are
// metadata and neither describes how a track sounds. A genre tag is frequently
// missing or wrong on a downloaded track, two songs sharing one are routinely
// mastered nothing alike, and tempo says even less — it is a rate, not a tonal
// balance. So the chosen curve bore no relationship to whether a track was
// already bass-heavy (where a bass boost only makes it muddy) or genuinely thin.
//
// The server now measures each track's average energy in the same ten bands the
// equaliser has, relative to that track's own overall level — a tonal
// fingerprint. Selection becomes a question with a real answer: which preset,
// applied to THIS track, brings it closest to the target?
//
// The target is the median shape of the user's own library, supplied by the
// server. That makes Auto EQ a consistency control — "make this track sit like
// the typical track you own" — rather than an outside opinion imposed on a
// collection that is mostly game and anime scores. It is also self-calibrating:
// a library of loud remixes and one of quiet piano end up with different
// targets without anyone having to choose one.
//
// Measured on a real cloud library: 11 tracks in 28 are already close enough to
// the target that the honest answer is no EQ at all, and the remainder reduce
// their deviation from it by 11% to 77%.
enum SpectralEQMatcher {

    /// Per-band weighting for the match.
    ///
    /// The extremes are deliberately discounted. 32Hz and 16kHz carry the least
    /// perceptual information, vary enormously between masters, and are where
    /// the measurement is least reliable — weighting them equally lets a
    /// rolled-off top end, which is often just the source encoding, drive a
    /// choice that changes the whole midrange.
    private static let weights: [Double] = [0.4, 0.7, 1.0, 1.0, 1.0, 1.0, 1.0, 0.9, 0.7, 0.4]

    /// How much better than flat a preset must be before it is worth applying.
    ///
    /// Without this, Auto EQ would always pick *something*, because some preset
    /// is always fractionally closer than none. A track already sitting where it
    /// should be must be left alone — applying a curve for a 3% gain is
    /// inaudible at best and is a change the listener did not ask for.
    private static let minimumImprovement = 0.10

    /// The best preset for a track, or `.flat` when it does not need one.
    ///
    /// - Parameters:
    ///   - spectrum: the track's ten-band fingerprint.
    ///   - target: the library's median shape.
    static func preset(for spectrum: [Double], target: [Double]) -> EQPreset {
        guard spectrum.count == 10, target.count == 10 else { return .flat }

        let flatScore = deviation(spectrum: spectrum, gains: EQPreset.flat.bands, target: target)
        guard flatScore > 0 else { return .flat }

        var best = EQPreset.flat
        var bestScore = flatScore
        for candidate in EQPreset.allCases {
            // `.custom` is whatever the user set by hand; Auto EQ must never
            // silently adopt it as if it were a suggestion.
            guard candidate != .custom else { continue }
            // Device presets (Phone Speaker, Earbud Lift, Car Cabin) describe
            // the listener's gear, not the track; Utility ones (Night Shift,
            // Spoken Word) a situation. Auto EQ chooses between sound presets.
            guard candidate.category == "Signature" || candidate.category == "Genre" else { continue }
            let score = deviation(spectrum: spectrum, gains: candidate.bands, target: target)
            if score < bestScore {
                bestScore = score
                best = candidate
            }
        }

        let improvement = (flatScore - bestScore) / flatScore
        return improvement >= minimumImprovement ? best : .flat
    }

    /// Weighted squared distance from the target after `gains` are applied.
    private static func deviation(spectrum: [Double], gains: [Float], target: [Double]) -> Double {
        var total = 0.0
        for i in 0..<10 {
            let corrected = spectrum[i] + Double(gains[i])
            let error = corrected - target[i]
            total += weights[i] * error * error
        }
        return total
    }

    /// How much a preset would improve a track, 0...1. For logging — a curve
    /// that sounds wrong is otherwise very hard to reason about afterwards.
    static func improvement(for spectrum: [Double], preset: EQPreset, target: [Double]) -> Double {
        guard spectrum.count == 10, target.count == 10 else { return 0 }
        let flatScore = deviation(spectrum: spectrum, gains: EQPreset.flat.bands, target: target)
        guard flatScore > 0 else { return 0 }
        let score = deviation(spectrum: spectrum, gains: preset.bands, target: target)
        return max(0, (flatScore - score) / flatScore)
    }
}
