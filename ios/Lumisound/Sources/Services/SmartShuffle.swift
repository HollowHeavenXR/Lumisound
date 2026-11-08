import Foundation

/// Shuffle orders from the Rust core (rust/core/src/shuffle.rs). Smart
/// shuffle spreads artists/albums out, plays recently heard and often-skipped
/// songs later, and smooths tempo jumps; turned off, it is a plain shuffle.
enum SmartShuffle {
    static let settingKey = "smartShuffleEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
    }

    /// `songs` in shuffled order. `bpm` supplies tempos not stored on the
    /// song (the player's analysis cache).
    static func order(_ songs: [Song], anchorBPM: Double? = nil, previousArtist: String? = nil,
                      bpm: ((Song) -> Double?)? = nil) -> [Song] {
        guard songs.count > 1 else { return songs }
        let items = songs.map { song in
            ShuffleItem(id: song.id, artist: song.artist, album: song.album, bpm: song.bpm ?? bpm?(song))
        }
        let options = ShuffleOptions(smart: isEnabled, anchorBpm: anchorBPM, previousArtist: previousArtist, seed: nil)
        let order = shuffleOrder(items: items, options: options)
        // The core always returns a permutation; fall back defensively anyway.
        guard order.count == songs.count else { return songs.shuffled() }
        return order.map { songs[Int($0)] }
    }
}

extension Array where Element == Song {
    /// Shuffled with Smart Shuffle (or plainly, when it's off in Settings).
    func smartShuffled() -> [Song] { SmartShuffle.order(self) }
}
