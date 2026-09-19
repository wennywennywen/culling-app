# Cull

Personal iOS photo cleanup app. Burst-shoot, then cull fast: pick a set of photos,
page through them full-screen, tap a circle on the rejects, file the keepers into
albums, delete the rejects in one batch.

Never shipped, never sold. Target: iOS 17+.

## Non-negotiable invariants

- **NEVER call `deleteAssets` outside the single batch-delete path.** Marking is
  local state only. If a change deletes on tap, reject it.
- **Swiping NAVIGATES between photos.** It never marks, files, or deletes.
- **Filing into an album MUST clear any delete mark on that photo.** Filing implies
  keeping. Honouring both would delete a photo the user just deliberately saved —
  the only bug here that loses data permanently.
- **NEVER modify an original asset in place.** Edits create new assets.
- **Grouping is MANUAL.** Do not add Vision, clustering, similarity thresholds, or
  feature prints. The user chooses what belongs together. This was a deliberate
  scope decision, not an omission — see `docs/DECISIONS.md`.

## Platform facts — don't re-derive these

- `deleteAssets` **always** shows a system confirmation. It cannot be suppressed.
  It batches, so mark many then delete once. One dialog covers any number of photos.
- `addAssets` does **not** prompt. Filing is instant and inline. Do not batch it
  behind a confirm — that asymmetry with deletion is deliberate and load-bearing.
- Albums are **references, not copies**. Filing does not shrink the library; only
  deleting does. (The UI used to say so; the owner asked for that note to be removed —
  see `docs/DECISIONS.md` #13. Don't add it back.)
- Smart albums (Recents, Favourites, Screenshots) are **read-only**. Fetch
  `.album`/`.albumRegular` and check `canPerform(.addContent)` before offering one.
- PhotoKit does **not** dedupe album membership. Check before adding.
- Deleted photos land in **Recently Deleted for 30 days**. Say so in the UI — it is
  what makes aggressive culling feel safe.
- iOS 26 has reports of the delete completion handler never firing. Add a timeout
  and re-fetch to verify rather than trusting it.
- `PHAuthorizationStatus.limited` breaks this app's purpose. Detect it and explain,
  with a deep link to Settings. Never render an empty grid — that reads as broken.
- Use `PHCachingImageManager` for grid thumbnails. Never request full-res for a grid.
- **Every PhotoKit callback MUST be `nonisolated`.** This is the single biggest
  trap in this codebase — it cost two separate crashes, one hiding behind the other.

  This project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so closures,
  methods, *and plain classes* written inside a `@MainActor` type are inferred
  main-actor-isolated. PhotoKit calls back on its own queues. When it does,
  Swift 6's executor check fails and the process dies with **SIGTRAP** —
  compiling cleanly and crashing 100% of the time at runtime.

  Confirmed sites, both fixed:
  - `PHPhotoLibrary.performChanges` change block → `com.apple.PHPhotoLibrary.changes`
  - `PHPhotoLibraryChangeObserver.photoLibraryDidChange` → `PHChange-queue`

  The observer one is nastiest: it fires on *any* library change, so every delete
  and every album add killed the app **after the write had already succeeded**.

  Only `Sendable` values may cross the boundary. Pass `[String]` local identifiers
  and re-fetch inside the block — which is what PhotoKit wants anyway.

  **Diagnosing this class of bug:** the console only says "signal 5". Get the real
  answer from the device:
  ```
  xcrun devicectl device info files --device <id> --domain-type systemCrashLogs
  xcrun devicectl device copy from --device <id> --domain-type systemCrashLogs \
      --source <Name>.ips --destination ./crash.ips
  ```
  The `.ips` is JSON-lines; the faulting thread's `queue` field names the culprit.

## Build and test reality

Xcode 26.6 with the iOS 26.5 SDK. The pure logic lives in `CullCore/`, a SwiftPM
package importing no Apple UI or media frameworks:

```
cd CullCore && swift build   # compile
cd CullCore && swift test    # 38 tests
```

Keeping `CullCore` framework-free means every rule that can lose a photo is verified
by `swift test` alone — no simulator, no device, no app target in the loop. Run it
before handing work to the tester.

**Simulator: useful for UI, useless for photo access.** Verified the hard way —

- `xcrun simctl privacy <dev> grant photos <bundleid>` **does not work.** It writes
  `kTCCServicePhotos … 2` into the simulator's `TCC.db`, and you can confirm the row
  is there, but `PHPhotoLibrary.authorizationStatus(for: .readWrite)` still returns
  `.notDetermined`. PhotoKit stores the full-vs-limited *level* separately from the
  TCC row, and simctl does not set it. Rebooting the simulator does not help.
- So the only way past the access gate in the Simulator is tapping through the real
  system dialog by hand.
- `xcrun simctl addmedia <dev> *.jpg` **does** work for seeding photos.

Practical consequence: the Simulator verifies layout, copy, and navigation. **Anything
behind the access gate — the grid, filing, deletion — is device-only.** Do not report
those as verified from a Simulator run. See `docs/DEVICE-TESTS.md`.

Running the app manually:
```
xcodebuild -scheme Cull -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcrun simctl install "iPhone 17 Pro" <path-to-Cull.app>
xcrun simctl launch "iPhone 17 Pro" com.uyen.Cull
xcrun simctl io "iPhone 17 Pro" screenshot shot.png
```

## Where logic belongs

- `CullCore/Sources/CullCore/` — pure decision logic. No PhotoKit, no SwiftUI.
  Every rule that can live here **must** live here, because this is the only part
  that can be verified without a device.
- The iOS app (`Cull/Cull.xcodeproj`) wraps `CullCore`. It never reimplements its rules.

## Testing reality

- Selection, marking, filing, and album-ordering logic is **pure and must be unit
  tested**. Add the test in the same change as the behaviour, not after.
- Anything touching `PHPhotoLibrary` needs a real device and a real library.
- **NEVER report a delete or filing flow as verified without device testing.**
  Automated checks cannot exercise PhotoKit. Flag it for `docs/DEVICE-TESTS.md`.
