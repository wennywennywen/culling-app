import Photos
import UIKit

/// Supplies grid thumbnails through a `PHCachingImageManager`.
///
/// The caching manager is the whole point: it decodes ahead of the scroll and
/// reuses results, which is the difference between a grid that glides and one
/// that stutters on a 20,000-photo library.
///
/// Never ask this for a full-resolution image. Requesting `PHImageManagerMaximumSize`
/// for a grid cell is the single most effective way to make this app feel broken.
@MainActor
final class ThumbnailProvider {

    static let shared = ThumbnailProvider()

    /// Roughly three columns on a modern iPhone at 2x, with headroom so
    /// thumbnails do not look soft. Points, not pixels — PhotoKit scales.
    static let thumbnailSize = CGSize(width: 300, height: 300)

    private let manager = PHCachingImageManager()

    private init() {
        manager.allowsCachingHighQualityImages = false
    }

    private var requestOptions: PHImageRequestOptions {
        let options = PHImageRequestOptions()
        // .highQualityFormat, not .opportunistic — opportunistic calls back more
        // than once (a degraded image, then the real one), and it is not
        // guaranteed to ever deliver the final one if the request is cancelled.
        // Bridged to a continuation that would hang forever. One callback,
        // one resume.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true // iCloud-only photos still need to render
        return options
    }

    /// Warms the cache for photos about to scroll into view.
    func startCaching(_ assets: [PHAsset]) {
        manager.startCachingImages(
            for: assets,
            targetSize: Self.thumbnailSize,
            contentMode: .aspectFill,
            options: requestOptions
        )
    }

    /// Releases photos that scrolled well out of view.
    func stopCaching(_ assets: [PHAsset]) {
        manager.stopCachingImages(
            for: assets,
            targetSize: Self.thumbnailSize,
            contentMode: .aspectFill,
            options: requestOptions
        )
    }

    func resetCache() {
        manager.stopCachingImagesForAllAssets()
    }

    /// One thumbnail. Returns `nil` if the photo could not be loaded.
    func thumbnail(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            manager.requestImage(
                for: asset,
                targetSize: Self.thumbnailSize,
                contentMode: .aspectFill,
                options: requestOptions
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    // MARK: - Full-screen pager images

    /// A second caching manager, kept separate from the grid's.
    ///
    /// Screen-sized images are orders of magnitude larger than thumbnails. Sharing
    /// one manager would let a handful of pages evict the entire warm thumbnail
    /// cache, making the grid stutter every time you came back from reviewing.
    private let pageManager = PHCachingImageManager()

    /// Warms the pages either side of the one on screen.
    ///
    /// Without this every swipe starts a decode from cold, which is what makes
    /// fast paging feel like it is catching. Keep the window small — these are
    /// full-screen bitmaps, not thumbnails.
    func startCachingPages(_ assets: [PHAsset], size: CGSize) {
        pageManager.startCachingImages(
            for: assets,
            targetSize: size,
            contentMode: .aspectFit,
            options: requestOptions
        )
    }

    func stopCachingPages() {
        pageManager.stopCachingImagesForAllAssets()
    }

    /// A screen-sized image for the review pager.
    ///
    /// Not full resolution: a 48-megapixel original decoded to fill a phone screen
    /// is wasted work, and `aspectFit` at screen scale is what the eye gets either
    /// way.
    func displayImage(for asset: PHAsset, size: CGSize) async -> UIImage? {
        await withCheckedContinuation { continuation in
            pageManager.requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFit,
                options: requestOptions
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
