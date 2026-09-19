# Architecture

## Shape

One iOS app target wrapping one pure Swift package. No extensions, no App Group, no
backend, no machine learning.

```
cull/
├── CLAUDE.md                      rules every agent inherits
├── .claude/agents/                architect, coder, designer, tester, manager
├── docs/
│   ├── ARCHITECTURE.md            this file
│   ├── DECISIONS.md               append-only, with reasoning
│   └── DEVICE-TESTS.md            the manual checklist only a human can run
├── CullCore/                      ← pure logic, builds without Xcode
│   ├── Package.swift
│   └── Sources/
│       ├── CullCore/
│       │   ├── Identifiers.swift  PhotoID, AlbumID
│       │   ├── CullSession.swift  marking, filing, navigation
│       │   ├── AlbumPicker.swift  album filtering and ordering
│       │   └── ReviewPeriod.swift Custom Review date ranges
│       └── CullTests/             executable harness (see below)
└── Cull/                          ← the iOS app (Cull.xcodeproj)
```

## The boundary that matters

**`CullCore` imports nothing beyond Foundation.** No Photos, no SwiftUI, no UIKit.

This is load-bearing rather than stylistic. A framework-free package builds and tests on
the Mac with `swift test` alone — no simulator, no device — so the logic that can lose a
photo is the part that is continuously verified.

The practical rule: **every rule that can live in `CullCore` must.** Logic pushed into
`CullCore` is continuously verified; logic left in a view or a PhotoKit wrapper is not
verified until someone picks up a phone.

The iOS app wraps `CullCore` and never reimplements its rules.

## CullCore

### `CullSession`

The whole decision model. Holds the photos under review, the marked-for-deletion set,
per-photo album filings, and the current index. Nothing in this type can touch the
photo library — the only destructive operation in the app reads `deletionBatch` once,
at the end.

Four invariants, each with a test:

1. `markedForDeletion` only ever contains photos in `photos`.
2. Filing a photo clears any deletion mark on it.
3. Navigation never mutates marks or filings.
4. Reordering (`move(_:toIndex:)`, `move(_:onto:)`) changes only the order of `photos`
   — never membership, marks, or filings — and the photo on screen stays on screen.
   Each move returns the index the photo came from (or `nil` if nothing moved) so the
   caller can offer an exact undo.

It also handles external change: `removeExternallyDeleted(_:)` for a photo deleted in
the Photos app mid-review, and `removeDeleted(_:)` after a successful batch delete.
Both clamp `currentIndex` so the pager cannot fall off the end of the array.

### `AlbumPicker`

Which albums the picker offers and in what order. Filters out smart albums and albums
that fail `canPerform(.addContent)` — offering an album that will reject the write is
worse than hiding it, because the tap appears to succeed and the photo silently never
arrives. Pins recently-used albums, then sorts the rest by title.

### `ReviewPeriod`

The date ranges behind **Custom Review** (last week, last month, last 3 months): the
cutoff for each, counted back from now, and whether a photo with a given creation date
falls inside. Rolling rather than calendar-aligned; month arithmetic is `Calendar`'s, so
31 March minus a month is 28 February. A photo with no date is left out, and one dated
slightly in the future (a wrong camera clock) is kept. The range is the user's choice —
not an inferred grouping — so it does not conflict with decision #1.

### Tests

Standard XCTest `.testTarget`:

```
cd CullCore && swift test
```

58 tests. These run on macOS with no simulator and no device — that is
the point of keeping `CullCore` framework-free.

*Historical note:* this suite was originally written against a hand-rolled
`XCTestShim.swift` because Xcode was not yet installed and neither XCTest nor
swift-testing resolved with the Command Line Tools alone. Because the shim mirrored
the real `XCTAssert*` API, migrating was deleting two files and restoring one import —
no test body changed. See decision #7.

## The iOS app

Layering:

| Layer | Responsibility |
|---|---|
| `Library/` | PhotoKit wrapper — fetch, thumbnails via `PHCachingImageManager`, album membership, the single `BatchDelete` path |
| `Views/` | SwiftUI: grid, review pager, circle affordance, album picker, camera |
| `Camera/` | `AVFoundation` burst capture, one session album per hold |

`BatchDelete.swift` is the **only** file permitted to call `deleteAssets`. The tester
greps for violations.

## The iOS app

`Cull/Cull.xcodeproj`, bundle id `com.uyen.Cull`, deployment target iOS 17.0,
Swift 6 language mode. `CullCore` is linked as a local Swift package
(`XCLocalSwiftPackageReference` → `../CullCore`).

Uses Xcode 16+ file-system-synchronized groups, so files added under `Cull/Cull/`
are picked up automatically — no `.pbxproj` edit needed to add a source file.

```
Cull/Cull/
├── CullApp.swift              @main → RootView
├── Library/
│   ├── PhotoLibraryAccess.swift   collapses PHAuthorizationStatus into 4 cases
│   ├── PhotoLibraryModel.swift    @Observable; access state + asset list
│   └── ThumbnailProvider.swift    PHCachingImageManager wrapper
└── Views/
    ├── RootView.swift             routes on access; re-checks on foreground
    ├── AccessGateViews.swift      request / denied / limited screens
    └── PhotoGridView.swift        LazyVGrid + async thumbnails

Later additions under `Views/`:

- `Filmstrip.swift` — the strip of small photos under the review pager: tap to jump,
  hold and drag to reorder, a mark circle and double-tap to mark. `FilmstripState` holds
  the drag bookkeeping.
- `AlbumPopup.swift` — the compact centred filing card, used from both the review screen
  and the library grid.
- `ConfirmDeleteSheet` (in `ReviewView.swift`) — the delete preview (photo + filmstrip +
  Delete button), shared by the review screen's trash button and the grid's trash button.
```

Nothing in `Library/` deletes, files, or modifies anything yet — it is read-only by
design, so the destructive path can arrive later in one greppable place
(`BatchDelete.swift`, Phase 3).

## Current state

- `CullCore`: implemented, 61 tests passing under XCTest (`swift test`).
- iOS app: the library grid, review screen (pager, filmstrip, marking, filing, reordering),
  Custom Review, the delete preview and the batch-delete path are written and build.
- Verified in the Simulator with seeded photos: layout, navigation, marking, filmstrip
  reordering, the album popup and the delete preview. **Not** verified there — because
  `simctl` cannot grant PhotoKit access (see `CLAUDE.md`) and the Simulator is no
  substitute for a real library — are actual filing, actual deletion, the drag feel and
  the delete timeout path. Those live in `docs/DEVICE-TESTS.md`, unticked until run.
- Decision #5 (marks persist for the session, clear on cold launch) is implemented with
  an in-memory `MarkStore`; nothing is written to disk.
- Camera burst capture and editing are not built.
