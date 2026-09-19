import CullCore

/// Delete marks that outlive any single review screen.
///
/// A `ReviewModel` is thrown away when you leave review — including by an
/// accidental swipe back to the grid — and would take its marks with it. This holds
/// them for the life of the app instead, so reopening review finds them again.
///
/// **In memory only, on purpose** (decision #5): backgrounding the app keeps marks,
/// but a cold launch starts clean, so a half-finished cull from days ago never
/// resurfaces as a delete button with a number on it.
///
/// It only mirrors what `CullSession` decides; it makes no decisions of its own.
@MainActor
final class MarkStore {

    private(set) var marked: Set<PhotoID> = []

    /// Replaces the marks for the photos of one session, leaving marks on any other
    /// photo (from a different review) untouched.
    func replace(among photos: [PhotoID], with newMarks: Set<PhotoID>) {
        marked.subtract(photos)
        marked.formUnion(newMarks)
    }

    /// Forgets photos that no longer exist — deleted here, or removed elsewhere.
    func forget(_ ids: [PhotoID]) {
        marked.subtract(ids)
    }

    /// Drops marks for anything not in `live`.
    func keepOnly(_ live: Set<PhotoID>) {
        marked.formIntersection(live)
    }
}
