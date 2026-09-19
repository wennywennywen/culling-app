// swift-tools-version: 6.0
import PackageDescription

// CullCore holds the pure selection/filing logic for the Cull app.
//
// It imports no Apple UI or media frameworks — no Photos, no SwiftUI, no UIKit.
// That keeps every rule that can lose a photo verifiable by `swift test` alone,
// with no simulator, no device, and no app target in the loop.
//
// The iOS app wraps this package; it never reimplements its rules.
let package = Package(
    name: "CullCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CullCore", targets: ["CullCore"])
    ],
    targets: [
        .target(name: "CullCore"),
        .testTarget(name: "CullCoreTests", dependencies: ["CullCore"]),
    ]
)
