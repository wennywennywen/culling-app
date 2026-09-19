import XCTest
@testable import CullCore

private func photos(_ ids: String...) -> [PhotoID] { ids.map(PhotoID.init) }
private let outfits = AlbumID("album.outfits")
private let scenery = AlbumID("album.scenery")

final class CullSessionTests: XCTestCase {

    // MARK: - Creation

    func testInitDeduplicatesKeepingFirstOccurrenceOrder() {
        let session = CullSession(photos: photos("a", "b", "a", "c", "b"))
        XCTAssertEqual(session.photos, photos("a", "b", "c"))
    }

    func testEmptySessionHasNoCurrentPhoto() {
        let session = CullSession(photos: [])
        XCTAssertTrue(session.isEmpty)
        XCTAssertNil(session.currentPhoto)
        XCTAssertFalse(session.canGoNext)
        XCTAssertFalse(session.canGoPrevious)
    }

    func testSinglePhotoGroup() {
        var session = CullSession(photos: photos("a"))
        XCTAssertEqual(session.currentPhoto, PhotoID("a"))
        XCTAssertFalse(session.canGoNext)
        XCTAssertFalse(session.canGoPrevious)

        session.goToNext()
        session.goToPrevious()
        XCTAssertEqual(session.currentPhoto, PhotoID("a"))
    }

    // MARK: - Marking

    func testToggleMarkFlipsState() {
        var session = CullSession(photos: photos("a", "b"))
        XCTAssertFalse(session.isMarked(PhotoID("a")))

        session.toggleMark(PhotoID("a"))
        XCTAssertTrue(session.isMarked(PhotoID("a")))

        session.toggleMark(PhotoID("a"))
        XCTAssertFalse(session.isMarked(PhotoID("a")))
    }

    /// Invariant 1: the marked set never contains anything outside the session.
    func testMarkingPhotoOutsideSessionIsIgnored() {
        var session = CullSession(photos: photos("a", "b"))
        session.mark(PhotoID("zzz"))
        session.toggleMark(PhotoID("zzz"))

        XCTAssertTrue(session.markedForDeletion.isEmpty)
        XCTAssertTrue(session.markedForDeletion.isSubset(of: Set(session.photos)))
    }

    func testUnmarkingUnmarkedPhotoIsNoOp() {
        var session = CullSession(photos: photos("a", "b"))
        session.unmark(PhotoID("a"))
        XCTAssertEqual(session.markedCount, 0)
    }

    func testMarkAllThenUnmarkAll() {
        var session = CullSession(photos: photos("a", "b", "c"))

        session.markAll()
        XCTAssertEqual(session.markedCount, 3)
        XCTAssertEqual(session.deletionBatch, photos("a", "b", "c"))

        session.unmarkAll()
        XCTAssertEqual(session.markedCount, 0)
        XCTAssertTrue(session.deletionBatch.isEmpty)
    }

    func testMarkedSetIsNeverLargerThanTheGroup() {
        var session = CullSession(photos: photos("a", "b", "c"))
        session.markAll()
        session.mark(PhotoID("outsider"))

        XCTAssertLessThanOrEqual(session.markedCount, session.count)
    }

    func testDeletionBatchFollowsDisplayOrderNotMarkOrder() {
        var session = CullSession(photos: photos("a", "b", "c", "d"))
        session.mark(PhotoID("d"))
        session.mark(PhotoID("b"))

        XCTAssertEqual(session.deletionBatch, photos("b", "d"))
    }

    // MARK: - Filing

    /// Invariant 2, and the single most important test in this file.
    ///
    /// If this regresses, the app deletes a photo the user just deliberately
    /// saved — the only bug here that loses data permanently.
    func testFilingClearsTheDeletionMark() {
        var session = CullSession(photos: photos("a", "b"))
        session.mark(PhotoID("a"))
        XCTAssertTrue(session.isMarked(PhotoID("a")))

        let outcome = session.file(PhotoID("a"), into: outfits)

        XCTAssertEqual(outcome, .filed(clearedDeletionMark: true))
        XCTAssertFalse(session.isMarked(PhotoID("a")))
        XCTAssertFalse(session.deletionBatch.contains(PhotoID("a")))
    }

    func testFilingUnmarkedPhotoReportsNoClearedMark() {
        var session = CullSession(photos: photos("a"))
        XCTAssertEqual(session.file(PhotoID("a"), into: outfits), .filed(clearedDeletionMark: false))
    }

    func testFilingSamePhotoTwiceIntoSameAlbumIsDeduped() {
        var session = CullSession(photos: photos("a"))
        XCTAssertEqual(session.file(PhotoID("a"), into: outfits), .filed(clearedDeletionMark: false))
        XCTAssertEqual(session.file(PhotoID("a"), into: outfits), .alreadyFiled)

        XCTAssertEqual(session.albums(for: PhotoID("a")), [outfits])
    }

    func testPhotoCanBeFiledIntoSeveralAlbums() {
        var session = CullSession(photos: photos("a"))
        session.file(PhotoID("a"), into: outfits)
        session.file(PhotoID("a"), into: scenery)

        XCTAssertEqual(session.albums(for: PhotoID("a")), [outfits, scenery])
        XCTAssertEqual(session.filedCount, 1, "filedCount counts photos, not filings")
    }

    func testFilingPhotoOutsideSessionIsRejected() {
        var session = CullSession(photos: photos("a"))
        XCTAssertEqual(session.file(PhotoID("zzz"), into: outfits), .photoNotInSession)
        XCTAssertTrue(session.albums(for: PhotoID("zzz")).isEmpty)
    }

    func testBatchFilingClearsMarksAcrossTheWholeSelection() {
        var session = CullSession(photos: photos("a", "b", "c"))
        session.markAll()

        let outcomes = session.file(photos("a", "c"), into: outfits)

        XCTAssertEqual(outcomes[PhotoID("a")], .filed(clearedDeletionMark: true))
        XCTAssertEqual(outcomes[PhotoID("c")], .filed(clearedDeletionMark: true))
        XCTAssertEqual(session.deletionBatch, photos("b"), "only the unfiled photo should remain marked")
    }

    func testBatchFilingHandlesRepeatsWithinOneBatch() {
        var session = CullSession(photos: photos("a"))
        let outcomes = session.file(photos("a", "a"), into: outfits)

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(session.albums(for: PhotoID("a")), [outfits])
    }

    func testCountersMatchTheRunningLabel() {
        var session = CullSession(photos: photos("a", "b", "c", "d"))
        session.mark(PhotoID("a"))
        session.mark(PhotoID("b"))
        session.file(PhotoID("c"), into: outfits)
        session.file(PhotoID("d"), into: scenery)

        XCTAssertEqual(session.markedCount, 2)
        XCTAssertEqual(session.filedCount, 2)
    }

    // MARK: - Navigation

    /// Invariant 3: swiping pages between photos and must never mutate decisions.
    func testNavigationNeverMutatesMarksOrFilings() {
        var session = CullSession(photos: photos("a", "b", "c"))
        session.mark(PhotoID("a"))
        session.file(PhotoID("b"), into: outfits)

        let marksBefore = session.markedForDeletion
        let filingsBefore = session.filings

        session.goToNext()
        session.goToNext()
        session.goToPrevious()
        session.goTo(PhotoID("a"))
        session.goToNext()

        XCTAssertEqual(session.markedForDeletion, marksBefore)
        XCTAssertEqual(session.filings, filingsBefore)
    }

    func testNavigationClampsAtBothEnds() {
        var session = CullSession(photos: photos("a", "b"))

        session.goToPrevious()
        XCTAssertEqual(session.currentPhoto, PhotoID("a"))

        session.goToNext()
        session.goToNext()
        session.goToNext()
        XCTAssertEqual(session.currentPhoto, PhotoID("b"))
    }

    func testGoToUnknownPhotoLeavesPositionAlone() {
        var session = CullSession(photos: photos("a", "b"))
        session.goToNext()
        session.goTo(PhotoID("zzz"))

        XCTAssertEqual(session.currentPhoto, PhotoID("b"))
    }

    // MARK: - External changes

    func testExternallyDeletedPhotoIsRemovedEverywhere() {
        var session = CullSession(photos: photos("a", "b", "c"))
        session.mark(PhotoID("b"))
        session.file(PhotoID("b"), into: outfits)

        session.removeExternallyDeleted(PhotoID("b"))

        XCTAssertEqual(session.photos, photos("a", "c"))
        XCTAssertFalse(session.isMarked(PhotoID("b")))
        XCTAssertTrue(session.albums(for: PhotoID("b")).isEmpty)
    }

    /// Guards the crash the plan calls out: deleting in the Photos app while the
    /// pager sits on the last photo must not leave `currentIndex` past the end.
    func testRemovingLastPhotoWhileViewingItClampsTheIndex() {
        var session = CullSession(photos: photos("a", "b", "c"))
        session.goTo(PhotoID("c"))
        XCTAssertEqual(session.currentIndex, 2)

        session.removeExternallyDeleted(PhotoID("c"))

        XCTAssertEqual(session.currentIndex, 1)
        XCTAssertEqual(session.currentPhoto, PhotoID("b"))
    }

    func testRemovingEveryPhotoLeavesAValidEmptySession() {
        var session = CullSession(photos: photos("a", "b"))
        session.goToNext()

        session.removeExternallyDeleted(PhotoID("a"))
        session.removeExternallyDeleted(PhotoID("b"))

        XCTAssertTrue(session.isEmpty)
        XCTAssertEqual(session.currentIndex, 0)
        XCTAssertNil(session.currentPhoto)
    }

    func testRemoveDeletedClearsTheWholeBatchAfterDeletion() {
        var session = CullSession(photos: photos("a", "b", "c", "d"))
        session.mark(PhotoID("a"))
        session.mark(PhotoID("c"))

        let batch = session.deletionBatch
        session.removeDeleted(batch)

        XCTAssertEqual(session.photos, photos("b", "d"))
        XCTAssertTrue(session.markedForDeletion.isEmpty)
        XCTAssertTrue(session.deletionBatch.isEmpty)
    }

    func testEveryPhotoMarkedThenDeletedEmptiesTheSession() {
        var session = CullSession(photos: photos("a", "b", "c"))
        session.markAll()
        session.removeDeleted(session.deletionBatch)

        XCTAssertTrue(session.isEmpty)
        XCTAssertEqual(session.currentIndex, 0)
    }

    func testRemoveDeletedIgnoresUnknownIdentifiers() {
        var session = CullSession(photos: photos("a", "b"))
        session.removeDeleted(photos("zzz"))

        XCTAssertEqual(session.photos, photos("a", "b"))
    }

    // MARK: - Reordering

    func testMoveToIndexReordersAndReportsWhereItCameFrom() {
        var session = CullSession(photos: photos("a", "b", "c", "d"))
        let from = session.move(PhotoID("a"), toIndex: 2)

        XCTAssertEqual(from, 0)
        XCTAssertEqual(session.photos, photos("b", "c", "a", "d"))
    }

    func testMoveToIndexClampsPastEitherEnd() {
        var session = CullSession(photos: photos("a", "b", "c"))
        session.move(PhotoID("a"), toIndex: 99)
        XCTAssertEqual(session.photos, photos("b", "c", "a"))

        session.move(PhotoID("a"), toIndex: -5)
        XCTAssertEqual(session.photos, photos("a", "b", "c"))
    }

    func testMoveToItsOwnSlotIsANoOpAndReportsNothingMoved() {
        var session = CullSession(photos: photos("a", "b", "c"))
        XCTAssertNil(session.move(PhotoID("b"), toIndex: 1))
        XCTAssertNil(session.move(PhotoID("a"), toIndex: -3))
        XCTAssertEqual(session.photos, photos("a", "b", "c"))
    }

    func testMovingUnknownPhotoIsANoOp() {
        var session = CullSession(photos: photos("a", "b"))
        XCTAssertNil(session.move(PhotoID("zzz"), toIndex: 0))
        XCTAssertEqual(session.photos, photos("a", "b"))
    }

    /// Dropping on a thumbnail takes that thumbnail's slot, whichever way you came.
    func testMoveOntoTakesTheTargetsSlotInBothDirections() {
        var session = CullSession(photos: photos("a", "b", "c", "d"))

        session.move(PhotoID("a"), onto: PhotoID("c"))
        XCTAssertEqual(session.photos, photos("b", "c", "a", "d"))

        session.move(PhotoID("d"), onto: PhotoID("b"))
        XCTAssertEqual(session.photos, photos("d", "b", "c", "a"))
    }

    func testMoveOntoUnknownPhotoOrItselfIsANoOp() {
        var session = CullSession(photos: photos("a", "b", "c"))
        XCTAssertNil(session.move(PhotoID("a"), onto: PhotoID("zzz")))
        XCTAssertNil(session.move(PhotoID("zzz"), onto: PhotoID("a")))
        XCTAssertNil(session.move(PhotoID("a"), onto: PhotoID("a")))
        XCTAssertEqual(session.photos, photos("a", "b", "c"))
    }

    /// Reordering changes *where* photos sit, never *which* photos are in play,
    /// and never touches marks or filings (invariants 1 and 3).
    func testReorderingNeverChangesMembershipMarksOrFilings() {
        var session = CullSession(photos: photos("a", "b", "c", "d"))
        session.mark(PhotoID("a"))
        session.mark(PhotoID("c"))
        session.file(PhotoID("d"), into: outfits)
        let membership = Set(session.photos)
        let marks = session.markedForDeletion
        let filings = session.filings

        session.move(PhotoID("a"), onto: PhotoID("d"))
        session.move(PhotoID("c"), onto: PhotoID("a"))
        session.move(PhotoID("b"), toIndex: 0)

        XCTAssertEqual(Set(session.photos), membership)
        XCTAssertEqual(session.photos.count, 4)
        XCTAssertEqual(session.markedForDeletion, marks)
        XCTAssertEqual(session.filings, filings)
    }

    func testDeletionBatchFollowsTheNewOrder() {
        var session = CullSession(photos: photos("a", "b", "c", "d"))
        session.mark(PhotoID("a"))
        session.mark(PhotoID("c"))
        XCTAssertEqual(session.deletionBatch, photos("a", "c"))

        session.move(PhotoID("c"), toIndex: 0)
        XCTAssertEqual(session.deletionBatch, photos("c", "a"))
    }

    /// The photo on screen stays on screen — its index follows it.
    func testCurrentPhotoStaysCurrentWhenItIsMoved() {
        var session = CullSession(photos: photos("a", "b", "c", "d"))
        session.goTo(PhotoID("b"))

        session.move(PhotoID("b"), toIndex: 3)
        XCTAssertEqual(session.currentPhoto, PhotoID("b"))
        XCTAssertEqual(session.currentIndex, 3)
    }

    func testCurrentPhotoStaysCurrentWhenOthersMovePastIt() {
        var session = CullSession(photos: photos("a", "b", "c", "d"))
        session.goTo(PhotoID("c"))

        session.move(PhotoID("a"), toIndex: 3) // a jumps over c
        XCTAssertEqual(session.currentPhoto, PhotoID("c"))

        session.move(PhotoID("d"), toIndex: 0) // d jumps back over c
        XCTAssertEqual(session.currentPhoto, PhotoID("c"))
    }

    func testUndoingAMoveRestoresTheOriginalOrder() {
        var session = CullSession(photos: photos("a", "b", "c", "d"))
        let original = session.photos

        let from = session.move(PhotoID("a"), onto: PhotoID("d"))
        XCTAssertNotEqual(session.photos, original)

        session.move(PhotoID("a"), toIndex: from!)
        XCTAssertEqual(session.photos, original)
    }

    func testReorderingAnEmptyOrSingleSessionIsSafe() {
        var empty = CullSession(photos: [])
        XCTAssertNil(empty.move(PhotoID("a"), toIndex: 0))

        var single = CullSession(photos: photos("a"))
        XCTAssertNil(single.move(PhotoID("a"), onto: PhotoID("a")))
        XCTAssertEqual(single.photos, photos("a"))
    }

    // MARK: - Restoring marks

    /// Reopening a review restores what was marked before — but only for photos this
    /// session actually contains (invariant 1: marks are always a subset of `photos`).
    func testRestoreMarksAppliesOnlyToPhotosInTheSession() {
        var session = CullSession(photos: photos("a", "b", "c"))
        session.restoreMarks([PhotoID("a"), PhotoID("c"), PhotoID("elsewhere")])

        XCTAssertEqual(session.markedForDeletion, [PhotoID("a"), PhotoID("c")])
        XCTAssertTrue(session.markedForDeletion.isSubset(of: Set(session.photos)))
        XCTAssertEqual(session.deletionBatch, photos("a", "c"))
    }

    func testRestoreMarksLeavesFilingsAndPositionAlone() {
        var session = CullSession(photos: photos("a", "b", "c"))
        session.file(PhotoID("b"), into: outfits)
        session.goTo(PhotoID("c"))
        let filings = session.filings

        session.restoreMarks([PhotoID("a")])

        XCTAssertEqual(session.filings, filings)
        XCTAssertEqual(session.currentPhoto, PhotoID("c"))
    }

    func testRestoreMarksWithNothingToRestoreIsANoOp() {
        var session = CullSession(photos: photos("a", "b"))
        session.mark(PhotoID("a"))
        session.restoreMarks([])
        XCTAssertEqual(session.markedForDeletion, [PhotoID("a")])

        var empty = CullSession(photos: [])
        empty.restoreMarks([PhotoID("a")])
        XCTAssertTrue(empty.markedForDeletion.isEmpty)
    }
}
