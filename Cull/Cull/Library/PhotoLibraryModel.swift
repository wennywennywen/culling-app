import Photos
import Observation

/// Bridges `PHPhotoLibraryChangeObserver`, which is an Objective-C protocol
/// delivered on a background queue, to the main-actor model.
///
/// **`nonisolated` is load-bearing, not decoration.** This project builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without it `photoLibraryDidChange`
/// is inferred main-actor-isolated. PhotoKit calls it on its own `PHChange-queue`,
/// Swift 6's executor check fails, and the process dies with SIGTRAP.
///
/// That fires on *any* library change — so every delete and every album add
/// killed the app, moments after the write itself had actually succeeded.
nonisolated private final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}

/// Owns access state and the list of photos.
///
/// Deliberately read-only: nothing here deletes, files, or modifies anything.
/// Destructive work lives in its own type so it is greppable and reviewable in
/// one place.
@MainActor
@Observable
final class PhotoLibraryModel {

    private(set) var access: PhotoLibraryAccess = .undetermined
    private(set) var assets: [PHAsset] = []
    private(set) var isLoading = false

    @ObservationIgnored private var observer: LibraryChangeObserver?

    // MARK: - Access

    /// Reads the current status without prompting.
    ///
    /// Called on every foreground, because the user can revoke or upgrade access
    /// in Settings while the app is backgrounded and we would otherwise show a
    /// stale screen.
    func refreshAccessStatus() {
        let previous = access
        access = PhotoLibraryAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))

        guard access != previous else { return }
        if access.canCull {
            startObserving()
            loadAssets()
        } else {
            stopObserving()
            assets = []
        }
    }

    /// Prompts for access. Safe to call when already determined — the system
    /// simply returns the existing status without showing a dialog.
    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        access = PhotoLibraryAccess(status)

        if access.canCull {
            startObserving()
            loadAssets()
        }
    }

    // MARK: - Loading

    func loadAssets() {
        guard access.canCull else { return }
        isLoading = true
        defer { isLoading = false }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)

        var fetched: [PHAsset] = []
        fetched.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in fetched.append(asset) }
        assets = fetched
    }

    // MARK: - Change observation

    private func startObserving() {
        guard observer == nil else { return }

        // The callback arrives on a background queue, so it hops back to the
        // main actor. `weak self` because the library retains the observer for
        // as long as it is registered.
        let observer = LibraryChangeObserver { [weak self] in
            Task { @MainActor in self?.loadAssets() }
        }
        PHPhotoLibrary.shared().register(observer)
        self.observer = observer
    }

    private func stopObserving() {
        guard let observer else { return }
        PHPhotoLibrary.shared().unregisterChangeObserver(observer)
        self.observer = nil
    }
}
