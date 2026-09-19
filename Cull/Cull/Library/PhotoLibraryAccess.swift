import Photos

/// What the photo library will let us do.
///
/// `PHAuthorizationStatus` has five cases and two of them (`.restricted`,
/// `.denied`) mean the same thing to this app, while `.limited` — which reads
/// like a mild version of `.authorized` — actually breaks the app's whole
/// purpose. Collapsing the status into these four cases forces every call site
/// to confront `.limited` rather than lumping it in with "authorized".
enum PhotoLibraryAccess: Equatable {
    /// Never asked.
    case undetermined

    /// Refused, or blocked by device policy. Only Settings can change this.
    case denied

    /// The user granted access to a hand-picked set of photos.
    ///
    /// Fatal for a cleanup app: we would only ever see the photos the user
    /// already chose, so there is nothing to clean up. This must be explained,
    /// never rendered as an empty grid.
    case limited

    /// Full library access. The only state in which culling works.
    case full

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .undetermined
        case .restricted, .denied: self = .denied
        case .limited: self = .limited
        case .authorized: self = .full
        @unknown default: self = .denied
        }
    }

    /// Whether the app can actually do its job.
    var canCull: Bool { self == .full }
}
