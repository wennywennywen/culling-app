import Photos
import Observation
import CullCore

/// Fetches albums and files photos into them.
///
/// Filing is the mirror image of deletion: `addAssets` shows **no** system
/// prompt, so it can happen inline, mid-review, in about a second. That
/// asymmetry is deliberate — do not wrap this in a confirmation to "match" the
/// delete flow.
@MainActor
@Observable
final class AlbumStore {

    private(set) var albums: [AlbumCandidate] = []

    /// Album ids, most recently filed-into first. A few albums absorb almost
    /// everything in practice, so pinning these is the difference between one
    /// tap and a scroll on every photo.
    private(set) var recentlyUsed: [AlbumID] = []

    /// Ordering and filtering rules live in `CullCore` where they are unit
    /// tested; this type only supplies the data and performs the writes.
    var orderedAlbums: [AlbumCandidate] {
        AlbumPicker.ordered(from: albums, recentlyUsed: recentlyUsed)
    }

    private var collectionsByID: [AlbumID: PHAssetCollection] = [:]
    private static let recentsKey = "recentlyUsedAlbumIDs"

    init() {
        recentlyUsed = (UserDefaults.standard.array(forKey: Self.recentsKey) as? [String] ?? [])
            .map(AlbumID.init)
    }

    // MARK: - Loading

    /// Loads the user's own albums.
    ///
    /// Fetches `.album` only — smart albums (Recents, Favourites, Screenshots)
    /// are system-generated and reject additions, so they are never offered.
    func load() {
        let fetched = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: nil
        )

        var candidates: [AlbumCandidate] = []
        var byID: [AlbumID: PHAssetCollection] = [:]

        fetched.enumerateObjects { collection, _, _ in
            let id = AlbumID(collection.localIdentifier)
            byID[id] = collection
            candidates.append(
                AlbumCandidate(
                    id: id,
                    title: collection.localizedTitle ?? "Untitled",
                    isSmartAlbum: collection.assetCollectionType == .smartAlbum,
                    // A shared album you don't own looks ordinary but refuses
                    // writes. Offering it would make the tap appear to succeed
                    // while the photo silently never arrives.
                    canAddContent: collection.canPerform(.addContent)
                )
            )
        }

        albums = candidates
        collectionsByID = byID
    }

    // MARK: - Membership

    /// Which of the user's albums already contain this photo.
    ///
    /// Drives the checkmarks in the picker, and is what makes filing idempotent —
    /// PhotoKit will happily add a duplicate entry if you don't check first.
    func albums(containing asset: PHAsset) -> Set<AlbumID> {
        let containing = PHAssetCollection.fetchAssetCollectionsContaining(
            asset,
            with: .album,
            options: nil
        )

        var ids = Set<AlbumID>()
        containing.enumerateObjects { collection, _, _ in
            ids.insert(AlbumID(collection.localIdentifier))
        }
        return ids
    }

    // MARK: - Filing

    enum FilingError: LocalizedError {
        case unknownAlbum
        case notWritable
        case library(String)

        var errorDescription: String? {
            switch self {
            case .unknownAlbum: "That album no longer exists."
            case .notWritable: "That album can't accept photos."
            case .library(let message): message
            }
        }
    }

    /// Files photos into an album, skipping any already in it.
    @discardableResult
    func file(_ assets: [PHAsset], into albumID: AlbumID) async throws -> Int {
        guard let collection = collectionsByID[albumID] else { throw FilingError.unknownAlbum }
        guard collection.canPerform(.addContent) else { throw FilingError.notWritable }

        let existing = identifiersAlreadyIn(collection)
        let toAdd = assets.map(\.localIdentifier).filter { !existing.contains($0) }
        guard !toAdd.isEmpty else {
            noteUse(of: albumID)
            return 0
        }

        try await Self.performAdd(identifiers: toAdd, toAlbum: albumID.rawValue)
        noteUse(of: albumID)
        return toAdd.count
    }

    /// Creates an album and returns its id.
    func createAlbum(named title: String) async throws -> AlbumID {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FilingError.library("Give the album a name.") }

        let identifier = try await Self.performCreateAlbum(named: trimmed)
        load() // pick the new album up so it can be filed into immediately
        return AlbumID(identifier)
    }

    // MARK: - PhotoKit writes

    // These are `nonisolated`, and that is load-bearing.
    //
    // PhotoKit runs its change block on a background queue. This project builds
    // with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so a closure written
    // inside a `@MainActor` type is inferred main-actor-isolated — and the
    // instant PhotoKit calls it off the main thread, Swift 6's runtime actor
    // check traps and kills the process (SIGTRAP). It compiles cleanly and dies
    // every time at runtime.
    //
    // Only `String` identifiers cross the boundary, because `PHAsset` and
    // `PHAssetCollection` are not `Sendable`. Re-fetching inside the block is
    // what PhotoKit wants anyway — it hands you current objects.

    nonisolated private static func performAdd(
        identifiers: [String],
        toAlbum albumIdentifier: String
    ) async throws {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let collections = PHAssetCollection.fetchAssetCollections(
                    withLocalIdentifiers: [albumIdentifier],
                    options: nil
                )
                guard let collection = collections.firstObject,
                      let request = PHAssetCollectionChangeRequest(for: collection)
                else { return }

                let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
                request.addAssets(assets)
            }
        } catch {
            throw FilingError.library(error.localizedDescription)
        }
    }

    nonisolated private static func performCreateAlbum(named title: String) async throws -> String {
        // The change block runs to completion before `performChanges` returns,
        // so there is no real race here — but the compiler cannot know that, and
        // a plain `var` captured in a sendable closure will not compile.
        let box = IdentifierBox()

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCollectionChangeRequest
                    .creationRequestForAssetCollection(withTitle: title)
                box.identifier = request.placeholderForCreatedAssetCollection.localIdentifier
            }
        } catch {
            throw FilingError.library(error.localizedDescription)
        }

        guard let identifier = box.identifier else {
            throw FilingError.library("The album couldn't be created.")
        }
        return identifier
    }

    /// `nonisolated` for the same reason as the functions above: without it this
    /// class is inferred main-actor-isolated, and the background change block
    /// cannot touch it.
    nonisolated private final class IdentifierBox: @unchecked Sendable {
        var identifier: String?
    }

    // MARK: - Private

    private func identifiersAlreadyIn(_ collection: PHAssetCollection) -> Set<String> {
        let assets = PHAsset.fetchAssets(in: collection, options: nil)
        var identifiers = Set<String>()
        assets.enumerateObjects { asset, _, _ in identifiers.insert(asset.localIdentifier) }
        return identifiers
    }

    private func noteUse(of albumID: AlbumID) {
        recentlyUsed = AlbumPicker.recordUse(of: albumID, in: recentlyUsed)
        UserDefaults.standard.set(recentlyUsed.map(\.rawValue), forKey: Self.recentsKey)
    }
}
