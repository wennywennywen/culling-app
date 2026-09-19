import Photos

/// The **only** place in this app that deletes photos.
///
/// Everything else marks. Keeping deletion to one file means the rule "nothing
/// deletes except the batch path" is checkable with a single grep, and any new
/// call site shows up immediately in review.
@MainActor
enum BatchDelete {

    enum Outcome: Equatable {
        /// The user confirmed and the library reported success.
        case deleted(count: Int)
        /// The user tapped "Don't Allow" on the system dialog. Not an error.
        case cancelled
        /// The completion handler never fired; `count` is what a re-fetch proved
        /// actually went away.
        case unconfirmed(count: Int)
        case failed(message: String)
    }

    /// Deletes `assets` in one batch.
    ///
    /// iOS always shows its own confirmation here and it cannot be suppressed —
    /// which is exactly why marking and deleting are separate steps. One dialog
    /// covers the whole batch, however large.
    static func delete(_ assets: [PHAsset]) async -> Outcome {
        let identifiers = assets.map(\.localIdentifier)
        guard !identifiers.isEmpty else { return .deleted(count: 0) }

        let report = await withTaskGroup(of: Report?.self) { group in
            group.addTask { await performDelete(identifiers: identifiers) }
            group.addTask {
                // There are reports of the completion handler never firing on
                // iOS 26. Hanging forever would trap the user in a spinner;
                // assuming failure would be worse, because the photos may well
                // be gone. So: wait a bounded time, then go and look.
                try? await Task.sleep(for: .seconds(30))
                return nil
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let report else {
            let surviving = survivingCount(of: identifiers)
            return .unconfirmed(count: identifiers.count - surviving)
        }

        if report.success { return .deleted(count: identifiers.count) }
        if report.wasCancelled { return .cancelled }
        return .failed(message: report.message ?? "Unknown error")
    }

    // MARK: - Private

    private struct Report: Sendable {
        let success: Bool
        let wasCancelled: Bool
        let message: String?
    }

    /// `nonisolated`, and this is load-bearing.
    ///
    /// PhotoKit runs the change block on its own background queue. This project
    /// builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so a closure
    /// written inside a `@MainActor` type is inferred main-actor-isolated — and
    /// the instant PhotoKit calls it off the main thread, Swift 6's runtime
    /// actor check traps and kills the process (SIGTRAP). It compiles perfectly
    /// cleanly and dies every single time at runtime.
    ///
    /// Only `[String]` crosses the isolation boundary — `PHAsset` is not
    /// `Sendable`, so the assets are re-fetched inside the block, which is the
    /// pattern PhotoKit wants anyway.
    nonisolated private static func performDelete(identifiers: [String]) async -> Report {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
                PHAssetChangeRequest.deleteAssets(assets)
            } completionHandler: { success, error in
                let nsError = error as NSError?
                // Tapping "Don't Allow" surfaces as an error, but it is a normal
                // answer and must not be reported as a failure.
                let cancelled = nsError?.domain == PHPhotosErrorDomain
                    && nsError?.code == PHPhotosError.userCancelled.rawValue

                continuation.resume(returning: Report(
                    success: success,
                    wasCancelled: cancelled,
                    message: error?.localizedDescription
                ))
            }
        }
    }

    /// How many of these photos are still in the library.
    private static func survivingCount(of identifiers: [String]) -> Int {
        PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil).count
    }
}

extension BatchDelete.Outcome {

    /// Whether any photo actually left the library.
    var removedAny: Bool {
        switch self {
        case .deleted(let count), .unconfirmed(let count): count > 0
        case .cancelled, .failed: false
        }
    }

    /// What to tell the user, or `nil` when there is nothing to say.
    var userMessage: String? {
        switch self {
        case .deleted(let count):
            guard count > 0 else { return nil }
            return "\(count) \(count == 1 ? "photo" : "photos") moved to Recently Deleted. They'll stay there for 30 days."
        case .cancelled:
            return nil // the user said no; nothing to report
        case .unconfirmed(let count):
            // The completion handler never came back, so we re-fetched to find
            // out what actually happened rather than guessing.
            return count > 0
                ? "\(count) \(count == 1 ? "photo was" : "photos were") deleted, but iOS didn't confirm. Check Recently Deleted."
                : "iOS didn't confirm the delete and your photos are still here. Try again."
        case .failed(let message):
            return message
        }
    }
}

