import Photos
import Observation
import CullCore

/// Holds one culling session and the assets it refers to.
///
/// `CullSession` is a pure value type in `CullCore` that knows nothing about
/// PhotoKit — it deals in `PhotoID`. This class is the only place those ids get
/// paired back up with real `PHAsset`s, which keeps all the decision rules
/// testable without a photo library.
///
/// Every mutation here is a one-line delegation to `CullSession` on purpose.
/// The moment marking logic starts living in this file instead, it stops being
/// covered by the test suite.
@MainActor
@Observable
final class ReviewModel {

    private(set) var session: CullSession

    /// The group in display order.
    ///
    /// Stored rather than derived from `session.photos` on every read. A whole-
    /// library review can hold thousands of photos, and SwiftUI reads this on
    /// every body evaluation — recomputing an O(n) map each time was fine for a
    /// 40-photo shoot and would not be for 5,000.
    private(set) var assets: [PHAsset]

    /// Assets keyed by id, so the pager can resolve what to draw.
    private var assetsByID: [PhotoID: PHAsset]

    /// Where marks are kept between reviews, if this review should share them.
    /// `nil` for a throwaway model (the grid's trash preview), whose marks must not
    /// leak into later reviews.
    private let marks: MarkStore?

    init(assets: [PHAsset], marks: MarkStore? = nil) {
        let ids = assets.map { PhotoID($0.localIdentifier) }
        var session = CullSession(photos: ids)
        // Pick up anything marked in an earlier review of these photos.
        if let marks { session.restoreMarks(marks.marked) }
        self.marks = marks

        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: the latter traps
        // on a duplicate key, and two entries for one localIdentifier is exactly
        // the kind of thing a photo library will hand you eventually.
        let byID = Dictionary(
            zip(ids, assets),
            uniquingKeysWith: { first, _ in first }
        )

        self.session = session
        self.assetsByID = byID
        // CullSession deduplicates on init, so rebuild from it rather than
        // trusting the incoming array to match.
        self.assets = session.photos.compactMap { byID[$0] }
    }

    /// Re-derives `assets` after the session's membership changes.
    private func refreshAssets() {
        assets = session.photos.compactMap { assetsByID[$0] }
    }

    // MARK: - Reading

    func asset(for id: PhotoID) -> PHAsset? { assetsByID[id] }

    func isMarked(_ id: PhotoID) -> Bool { session.isMarked(id) }

    var markedCount: Int { session.markedCount }

    var currentPhoto: PhotoID? { session.currentPhoto }

    /// Assets marked for deletion, in display order — what the Phase 3 review
    /// screen and batch delete will consume.
    var markedAssets: [PHAsset] { session.deletionBatch.compactMap { assetsByID[$0] } }

    var isEmpty: Bool { session.isEmpty }

    // MARK: - Marking

    func toggleMark(_ id: PhotoID) {
        session.toggleMark(id)
        syncMarks()
    }

    func unmarkAll() {
        session.unmarkAll()
        syncMarks()
    }

    func markAll() {
        session.markAll()
        syncMarks()
    }

    /// Mirrors this session's marks into the shared store, so leaving review — or an
    /// accidental swipe back to the grid — doesn't lose them.
    private func syncMarks() {
        marks?.replace(among: session.photos, with: session.markedForDeletion)
    }

    // MARK: - Filing

    /// Records that a photo was filed into an album.
    ///
    /// `CullSession.file` clears any deletion mark as a side effect, which is the
    /// invariant this whole app hinges on: **filing implies keeping.** Honouring
    /// both would delete a photo the user just deliberately saved.
    ///
    /// Call this *after* the PhotoKit write succeeds — marking it filed when the
    /// write failed would leave the user thinking a photo was saved when it
    /// wasn't, and then not deleting it either.
    func recordFiled(_ id: PhotoID, into album: AlbumID) {
        session.file(id, into: album)
        syncMarks() // filing clears the mark, and the store must agree
    }

    func recordFiled(_ ids: [PhotoID], into album: AlbumID) {
        session.file(ids, into: album)
        syncMarks()
    }

    func albums(for id: PhotoID) -> Set<AlbumID> { session.albums(for: id) }

    var filedCount: Int { session.filedCount }

    // MARK: - Navigation

    /// Called when the pager swipes. Navigation only — it must never mark.
    func goTo(_ id: PhotoID) { session.goTo(id) }

    // MARK: - Reordering

    /// Moves a photo into another's slot. Returns where it came from, or `nil` if
    /// nothing moved. Order only — marks and filings are untouched.
    @discardableResult
    func move(_ id: PhotoID, onto target: PhotoID) -> Int? {
        let from = session.move(id, onto: target)
        if from != nil { refreshAssets() }
        return from
    }

    // MARK: - External changes

    /// A photo vanished from the library while we were reviewing it — deleted in
    /// the Photos app, or removed by an iCloud sync.
    func dropExternallyDeleted(_ id: PhotoID) {
        session.removeExternallyDeleted(id)
        assetsByID[id] = nil
        marks?.forget([id])
        refreshAssets()
    }

    /// Clears out photos this app just deleted, after the batch succeeded.
    func removeDeleted(_ ids: [PhotoID]) {
        session.removeDeleted(ids)
        for id in ids { assetsByID[id] = nil }
        marks?.forget(ids)
        refreshAssets()
    }

    /// Reconciles against the library's current contents.
    ///
    /// Called when PhotoKit reports a change, so the pager cannot end up showing
    /// a photo that no longer exists.
    func reconcile(against liveIdentifiers: Set<String>) {
        let vanished = session.photos.filter { !liveIdentifiers.contains($0.rawValue) }
        guard !vanished.isEmpty else { return }
        for id in vanished {
            session.removeExternallyDeleted(id)
            assetsByID[id] = nil
        }
        marks?.forget(vanished)
        refreshAssets()
    }
}

// `navigationDestination(item:)` needs Hashable. Identity is the right notion
// here — two reviews of the same photos are still two separate sessions with
// their own marks.
extension ReviewModel: Hashable {
    nonisolated static func == (lhs: ReviewModel, rhs: ReviewModel) -> Bool {
        lhs === rhs
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
