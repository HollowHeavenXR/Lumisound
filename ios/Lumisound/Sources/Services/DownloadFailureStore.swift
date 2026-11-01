import Foundation

/// Tracks that permanently failed to download back off for 1 day, 3 days,
/// a week, then a month per strike. Rules + storage live in the Rust core.
@MainActor
final class DownloadFailureStore {
    static let shared = DownloadFailureStore()

    private init() { _ = DownloadLedgerStore.shared }  // runs the legacy import

    func shouldSkip(sourceTrackID: String) -> Bool {
        !sourceTrackID.isEmpty && failureShouldSkip(sourceTrackId: sourceTrackID)
    }

    func recordPermanentFailure(sourceTrackID: String) {
        failureRecord(sourceTrackId: sourceTrackID)
    }

    func clear(sourceTrackID: String) {
        failureClear(sourceTrackId: sourceTrackID)
    }

    func suppressedCount<S: Sequence>(among sourceTrackIDs: S) -> Int where S.Element == String {
        Int(failureSuppressedCount(sourceTrackIds: Array(sourceTrackIDs)))
    }

    func clearAll() {
        failureClearAll()
    }

    var suppressedTotal: Int { Int(failureSuppressedTotal()) }
}
