import Foundation

/// Source id -> finished filename, plus short-lived in-flight claims.
/// Stored and evaluated by the Rust core (rust/core/src/downloads.rs).
@MainActor
final class DownloadLedgerStore {
    static let shared = DownloadLedgerStore()

    private init() {
        // One-time move of the UserDefaults-era blobs into the core store.
        let d = UserDefaults.standard
        downloadsImportLegacy(ledgerJson: d.data(forKey: "downloadLedger.v1"),
                              failuresJson: d.data(forKey: "downloadFailures.v1"))
    }

    func record(sourceTrackID: String, filename: String) {
        ledgerRecord(sourceTrackId: sourceTrackID, filename: filename)
    }

    func filename(for sourceTrackID: String) -> String? {
        ledgerFilename(sourceTrackId: sourceTrackID)
    }

    func isPresent(_ sourceTrackID: String, presentFilenames: Set<String>) -> Bool {
        ledgerIsPresent(sourceTrackId: sourceTrackID, presentFilenames: Array(presentFilenames))
    }

    func presentSourceIDs(presentFilenames: Set<String>) -> [String] {
        ledgerPresentIds(presentFilenames: Array(presentFilenames))
    }

    /// False when another download of this track was claimed < 5 min ago.
    func beginDownload(sourceTrackID: String) -> Bool {
        ledgerBegin(sourceTrackId: sourceTrackID)
    }

    func endDownload(sourceTrackID: String) {
        ledgerEnd(sourceTrackId: sourceTrackID)
    }
}
