import XCTest
@testable import CullCore

private func album(
    _ id: String,
    _ title: String,
    smart: Bool = false,
    canAdd: Bool = true
) -> AlbumCandidate {
    AlbumCandidate(id: AlbumID(id), title: title, isSmartAlbum: smart, canAddContent: canAdd)
}

final class AlbumPickerTests: XCTestCase {

    // MARK: - Filtering

    func testSmartAlbumsAreNeverOffered() {
        let candidates = [
            album("recents", "Recents", smart: true),
            album("favourites", "Favourites", smart: true),
            album("outfits", "Outfits"),
        ]

        XCTAssertEqual(AlbumPicker.selectable(from: candidates).map(\.id), [AlbumID("outfits")])
    }

    /// A shared album you do not own looks like a normal album but rejects writes.
    /// Offering it would make the tap appear to work while the photo never arrives.
    func testAlbumsThatRefuseAdditionsAreNotOffered() {
        let candidates = [
            album("shared", "Someone Else's Album", canAdd: false),
            album("outfits", "Outfits"),
        ]

        XCTAssertEqual(AlbumPicker.selectable(from: candidates).map(\.id), [AlbumID("outfits")])
    }

    func testNoSelectableAlbumsYieldsEmptyList() {
        let candidates = [album("recents", "Recents", smart: true)]
        XCTAssertTrue(AlbumPicker.ordered(from: candidates, recentlyUsed: []).isEmpty)
    }

    // MARK: - Ordering

    func testRecentlyUsedAlbumsArePinnedInRecencyOrder() {
        let candidates = [
            album("a", "Apples"),
            album("b", "Bananas"),
            album("c", "Cherries"),
        ]

        let ordered = AlbumPicker.ordered(
            from: candidates,
            recentlyUsed: [AlbumID("c"), AlbumID("a")]
        )

        XCTAssertEqual(ordered.map(\.id), [AlbumID("c"), AlbumID("a"), AlbumID("b")])
    }

    func testUnpinnedAlbumsSortAlphabeticallyIgnoringCase() {
        let candidates = [
            album("z", "zebra"),
            album("a", "Apple"),
            album("m", "mango"),
        ]

        let ordered = AlbumPicker.ordered(from: candidates, recentlyUsed: [])

        XCTAssertEqual(ordered.map(\.title), ["Apple", "mango", "zebra"])
    }

    /// A recently-used album can be deleted, or become unwritable, between sessions.
    func testStaleRecentIdentifiersAreSkipped() {
        let candidates = [album("a", "Apples")]

        let ordered = AlbumPicker.ordered(
            from: candidates,
            recentlyUsed: [AlbumID("deleted-album"), AlbumID("a")]
        )

        XCTAssertEqual(ordered.map(\.id), [AlbumID("a")])
    }

    func testASmartAlbumInRecentsIsStillNotOffered() {
        let candidates = [
            album("recents", "Recents", smart: true),
            album("a", "Apples"),
        ]

        let ordered = AlbumPicker.ordered(
            from: candidates,
            recentlyUsed: [AlbumID("recents")]
        )

        XCTAssertEqual(ordered.map(\.id), [AlbumID("a")])
    }

    func testDuplicateRecentIdentifiersDoNotDuplicateRows() {
        let candidates = [album("a", "Apples"), album("b", "Bananas")]

        let ordered = AlbumPicker.ordered(
            from: candidates,
            recentlyUsed: [AlbumID("a"), AlbumID("a")]
        )

        XCTAssertEqual(ordered.map(\.id), [AlbumID("a"), AlbumID("b")])
    }

    // MARK: - Recording use

    func testRecordUseMovesAlbumToTheFront() {
        let recents = [AlbumID("a"), AlbumID("b"), AlbumID("c")]
        let updated = AlbumPicker.recordUse(of: AlbumID("c"), in: recents)

        XCTAssertEqual(updated, [AlbumID("c"), AlbumID("a"), AlbumID("b")])
    }

    func testRecordUseDoesNotDuplicate() {
        let updated = AlbumPicker.recordUse(of: AlbumID("a"), in: [AlbumID("a")])
        XCTAssertEqual(updated, [AlbumID("a")])
    }

    func testRecordUseRespectsTheLimit() {
        let recents = [AlbumID("a"), AlbumID("b"), AlbumID("c"), AlbumID("d")]
        let updated = AlbumPicker.recordUse(of: AlbumID("e"), in: recents, limit: 4)

        XCTAssertEqual(updated, [AlbumID("e"), AlbumID("a"), AlbumID("b"), AlbumID("c")])
    }

    func testRecordUseOnEmptyHistory() {
        XCTAssertEqual(AlbumPicker.recordUse(of: AlbumID("a"), in: []), [AlbumID("a")])
    }
}
