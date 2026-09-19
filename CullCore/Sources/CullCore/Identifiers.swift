/// Identifies one photo. Wraps `PHAsset.localIdentifier` in the iOS app.
///
/// Kept as a distinct type rather than a bare `String` so a photo id can never
/// be passed where an album id is expected — the two are both opaque strings at
/// the PhotoKit layer and are easy to transpose.
public struct PhotoID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Identifies one album. Wraps `PHAssetCollection.localIdentifier` in the iOS app.
public struct AlbumID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

extension PhotoID: CustomStringConvertible {
    public var description: String { rawValue }
}

extension AlbumID: CustomStringConvertible {
    public var description: String { rawValue }
}
