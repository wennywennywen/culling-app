/// The result of trying to file a photo into an album.
public enum FilingOutcome: Equatable, Sendable {
    /// Filed. If the photo had been marked for deletion, that mark is now cleared.
    case filed(clearedDeletionMark: Bool)
    /// The photo was already in that album. Nothing changed — PhotoKit does not
    /// dedupe album membership, so we must.
    case alreadyFiled
    /// The photo is not part of this session. Ignored.
    case photoNotInSession
}

/// One culling session over a user-chosen set of photos.
///
/// This is the whole decision model for the app, and it is deliberately pure:
/// marking, unmarking, filing, and navigation all happen here in memory, and
/// nothing in this type can touch the photo library. The only destructive
/// operation in the app reads `deletionBatch` once, at the end.
///
/// Four invariants hold at all times, and each has a test:
///  1. `markedForDeletion` only ever contains photos in `photos`.
///  2. Filing a photo clears any deletion mark on it — filing implies keeping.
///  3. Navigation never mutates marks or filings.
///  4. Reordering changes only the order of `photos` — never membership, marks,
///     or filings.
public struct CullSession: Equatable, Sendable {

    /// The photos under review, in display order, deduplicated.
    public private(set) var photos: [PhotoID]

    /// Photos the user has marked to delete. Always a subset of `photos`.
    public private(set) var markedForDeletion: Set<PhotoID>

    /// Album membership added during this session, per photo.
    public private(set) var filings: [PhotoID: Set<AlbumID>]

    /// Index into `photos` of the photo currently on screen.
    public private(set) var currentIndex: Int

    // MARK: - Creation

    /// Creates a session over `photos`.
    ///
    /// Duplicates are removed, keeping the first occurrence, so a group built by
    /// multi-selecting the same photo twice behaves as if it were selected once.
    public init(photos: [PhotoID]) {
        var seen = Set<PhotoID>()
        self.photos = photos.filter { seen.insert($0).inserted }
        self.markedForDeletion = []
        self.filings = [:]
        self.currentIndex = 0
    }

    // MARK: - Reading

    public var isEmpty: Bool { photos.isEmpty }

    public var count: Int { photos.count }

    /// The photo currently on screen, or `nil` if the session is empty.
    public var currentPhoto: PhotoID? {
        photos.indices.contains(currentIndex) ? photos[currentIndex] : nil
    }

    public func isMarked(_ photo: PhotoID) -> Bool {
        markedForDeletion.contains(photo)
    }

    /// Albums this photo was filed into during this session.
    public func albums(for photo: PhotoID) -> Set<AlbumID> {
        filings[photo] ?? []
    }

    /// Count for the "28 marked" half of the running counter.
    public var markedCount: Int { markedForDeletion.count }

    /// Count for the "· 6 filed" half — distinct photos filed at least once.
    public var filedCount: Int {
        filings.values.count { !$0.isEmpty }
    }

    /// The photos to delete, in display order.
    ///
    /// Ordered rather than a raw `Set` so the review screen and the delete call
    /// are deterministic — the same session always produces the same batch.
    public var deletionBatch: [PhotoID] {
        photos.filter(markedForDeletion.contains)
    }

    // MARK: - Marking

    /// Marks a photo for deletion. No-op if the photo is not in this session.
    public mutating func mark(_ photo: PhotoID) {
        guard photos.contains(photo) else { return }
        markedForDeletion.insert(photo)
    }

    /// Clears a deletion mark. No-op if the photo was not marked.
    public mutating func unmark(_ photo: PhotoID) {
        markedForDeletion.remove(photo)
    }

    /// Flips the mark on a photo — what the circle button calls.
    public mutating func toggleMark(_ photo: PhotoID) {
        guard photos.contains(photo) else { return }
        if markedForDeletion.contains(photo) {
            markedForDeletion.remove(photo)
        } else {
            markedForDeletion.insert(photo)
        }
    }

    /// Re-applies marks from an earlier review of these photos, so leaving a review
    /// (say, by an accidental swipe back) doesn't lose them.
    ///
    /// Only photos in this session are taken — a mark for anything else is ignored,
    /// which keeps `markedForDeletion` a subset of `photos`.
    public mutating func restoreMarks(_ marked: Set<PhotoID>) {
        markedForDeletion.formUnion(marked.intersection(photos))
    }

    public mutating func markAll() {
        markedForDeletion = Set(photos)
    }

    public mutating func unmarkAll() {
        markedForDeletion.removeAll()
    }

    // MARK: - Filing

    /// Files a photo into an album.
    ///
    /// Filing implies keeping: if the photo was marked for deletion, that mark
    /// is cleared here. Honouring both would delete a photo the user just
    /// deliberately saved, which is the one bug in this app that loses data.
    @discardableResult
    public mutating func file(_ photo: PhotoID, into album: AlbumID) -> FilingOutcome {
        guard photos.contains(photo) else { return .photoNotInSession }

        var albumsForPhoto = filings[photo] ?? []
        guard albumsForPhoto.insert(album).inserted else { return .alreadyFiled }
        filings[photo] = albumsForPhoto

        let clearedMark = markedForDeletion.remove(photo) != nil
        return .filed(clearedDeletionMark: clearedMark)
    }

    /// Files several photos into one album — the multi-select "Add to Album" path.
    @discardableResult
    public mutating func file(_ batch: [PhotoID], into album: AlbumID) -> [PhotoID: FilingOutcome] {
        var outcomes: [PhotoID: FilingOutcome] = [:]
        for photo in batch where outcomes[photo] == nil {
            outcomes[photo] = file(photo, into: album)
        }
        return outcomes
    }

    // MARK: - Navigation

    // Navigation is separated from marking on purpose: swiping pages between
    // photos and must never mark, file, or delete. That way paging back and
    // forth is always free, and a stray swipe can never cost a photo.

    public var canGoNext: Bool { currentIndex + 1 < photos.count }

    public var canGoPrevious: Bool { currentIndex > 0 }

    public mutating func goToNext() {
        guard canGoNext else { return }
        currentIndex += 1
    }

    public mutating func goToPrevious() {
        guard canGoPrevious else { return }
        currentIndex -= 1
    }

    /// Jumps to a specific photo — used when tapping a thumbnail in the grid.
    public mutating func goTo(_ photo: PhotoID) {
        guard let index = photos.firstIndex(of: photo) else { return }
        currentIndex = index
    }

    // MARK: - Reordering

    // Reordering changes where photos sit, never which photos are in play, so it
    // cannot touch marks or filings. The photo on screen stays on screen: after a
    // move `currentIndex` is re-derived from the photo, not left pointing at a slot.
    //
    // Each move returns the index the photo came from, or `nil` if nothing moved,
    // so a caller can offer an exact undo with `move(_:toIndex:)`.

    /// Moves a photo to `destination`, clamped to the ends of the session.
    @discardableResult
    public mutating func move(_ photo: PhotoID, toIndex destination: Int) -> Int? {
        guard let source = photos.firstIndex(of: photo) else { return nil }
        let target = min(max(destination, 0), photos.count - 1)
        guard target != source else { return nil }

        let onScreen = currentPhoto
        photos.remove(at: source)
        photos.insert(photo, at: target)
        if let onScreen, let index = photos.firstIndex(of: onScreen) {
            currentIndex = index
        }
        return source
    }

    /// Moves a photo into another photo's slot — what dropping one thumbnail
    /// onto another does. Dragging right lands it after the target, left before.
    @discardableResult
    public mutating func move(_ photo: PhotoID, onto target: PhotoID) -> Int? {
        guard let destination = photos.firstIndex(of: target) else { return nil }
        return move(photo, toIndex: destination)
    }

    // MARK: - External changes

    /// Drops a photo that disappeared from the library while this session was open
    /// — deleted in the Photos app, or removed by an iCloud sync.
    ///
    /// Clears it from `photos`, from the marked set, and from filings, then keeps
    /// `currentIndex` pointing at a valid photo so the pager does not fall off the
    /// end of the array.
    public mutating func removeExternallyDeleted(_ photo: PhotoID) {
        guard let index = photos.firstIndex(of: photo) else { return }
        photos.remove(at: index)
        markedForDeletion.remove(photo)
        filings[photo] = nil
        clampCurrentIndex()
    }

    /// Drops the photos that were just deleted, after the batch delete succeeds.
    public mutating func removeDeleted(_ batch: [PhotoID]) {
        let removed = Set(batch)
        guard !removed.isEmpty else { return }
        photos.removeAll(where: removed.contains)
        markedForDeletion.subtract(removed)
        for photo in removed { filings[photo] = nil }
        clampCurrentIndex()
    }

    private mutating func clampCurrentIndex() {
        if photos.isEmpty {
            currentIndex = 0
        } else {
            currentIndex = min(currentIndex, photos.count - 1)
        }
    }
}
