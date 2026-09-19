# Decisions

Append-only. Each entry records what was decided and *why*, so it isn't relitigated
every time someone new (human or agent) reads the code.

---

## 1. Grouping is manual, not automatic

**Decided:** the user chooses which photos belong together. No Vision, no feature
prints, no similarity clustering.

**Why:** automatic grouping hinges entirely on a similarity threshold, and that
threshold is the thing that makes or breaks this class of app — too low and
near-duplicates are missed, too high and unrelated photos clump together. It also
brings a feature-print cache, time-bucketing to avoid O(n²) comparison across the
library, and per-library tuning. Manual selection removes all of that, and the user
already knows which photos were one shoot.

**Consequence:** "a group" is just a set the user picked — via multi-select, a burst
session album, or an existing album.

---

## 2. Swiping navigates; a circle button marks

**Decided:** swipe gestures page between photos and never mutate state. Marking for
deletion is an explicit tap on a circle.

**Why:** partly the requested interaction, but it also buys a real safety property —
paging back and forth through a group is always free, and a stray swipe can never
cost a photo. Swipe-to-delete would make the most common gesture the destructive one.

**Enforcement:** banned-pattern grep for mark-set mutation inside a gesture handler.

---

## 3. Marking and deleting are separate steps

**Decided:** tapping the circle marks in local state only. Deletion happens once, at
the end, on the whole batch.

**Why:** forced by the platform. `PHAssetChangeRequest.deleteAssets` always presents
a system confirmation that cannot be suppressed — but it batches. Delete-on-tap would
mean one system alert per photo, which is unusable. Cull-then-delete means one alert
for the whole session.

---

## 4. Filing clears the deletion mark

**Decided:** filing a photo into an album automatically clears any pending delete mark.

**Why:** filing something you are about to delete is always a mistake. Honouring both
would delete a photo the user just deliberately saved. This is the only bug in the app
that loses data permanently, so it is an invariant rather than a nicety.

**Enforcement:** `testFilingClearsTheDeletionMark` in `CullCore`.

---

## 5. Marks persist for the session, clear on cold launch

**Decided:** if the app is backgrounded mid-review, pending marks survive. On a cold
launch they are discarded.

**Why:** losing 40 marks to an incoming phone call would be infuriating. But
resurrecting a half-finished cull from three days ago is confusing and slightly
dangerous — the user no longer remembers what they marked or why, and the next thing
they see is a delete button with a number on it.

**Status:** partly implemented — see #13. Marks survive leaving review and backgrounding
(in-memory `MarkStore`); a cold launch starts clean because nothing is written to disk.

---

## 6. `CullCore` imports no Apple UI or media frameworks

**Decided:** all decision logic lives in a SwiftPM package that imports nothing beyond
Foundation.

**Why:** Xcode is not installed on the development machine, so `xcodebuild` and XCTest
are unavailable. A framework-free package builds and runs its tests with the Command
Line Tools alone. That keeps the highest-risk logic — the part that can lose photos —
continuously verifiable, instead of untestable until Xcode arrives.

**Consequence:** the iOS app wraps `CullCore` and never reimplements its rules.

---

## 7. Test assertions are written against the XCTest API even though XCTest is absent

**Decided:** `XCTestShim.swift` reimplements the handful of `XCTAssert*` functions the
suite uses; tests are otherwise written exactly as they would be for XCTest.

**Why:** the alternative was inventing a bespoke assertion API that would have to be
rewritten later. With the shim, installing Xcode is a delete-one-file migration and
the test bodies never change.

**Consequence:** tests were registered by hand in `main.swift`, since there is no
reflection-based discovery. The registered count was asserted so a written-but-
unregistered test failed the run rather than silently never executing.

**Resolved.** Xcode 26.6 is now installed. Migration was: delete `XCTestShim.swift`
and `main.swift`, restore `import XCTest`, convert the target back to `.testTarget`.
All 38 tests passed immediately with **no change to any test body** — which is the
outcome the shim was chosen for. Decision #6 (keeping `CullCore` framework-free) still
stands on its own merits: it means the logic that can lose photos is verified by
`swift test` with no simulator or device in the loop.

---

## 8. The delete-confirm screen is a compare-and-reorder pager, with one shared order

**Decided:** the confirm-delete sheet shows the batch as a full-screen horizontal
pager over a filmstrip. Swiping the pager or tapping a thumbnail navigates; holding a
thumbnail and dropping it on another reorders; "Earlier / Later" buttons and an undo
toast give an exact, no-drag alternative. Reordering moves the photo in the session's
single `photos` order — there is no separate "compare order".

**Why:** comparing near-duplicates is the point of a cull, and a grid makes you tap in
and out of each photo. The filmstrip is a small target, so accuracy is designed in: a
deliberate long-press pickup (a plain swipe just scrolls the strip), the big pager
switches to the lifted photo so you can see what you're holding, a live insertion
marker shows where it lands, and the buttons/undo cover fine moves. One shared order
keeps `deletionBatch` — "in display order" — true everywhere instead of maintaining two
orders that can drift; the cost is that a reorder here also shows in the main pager.

**Consequences:**
- "Earlier / Later" move onto the neighbouring photo *in the batch*, not one slot in the
  whole session, which could swap with an unmarked photo that isn't on screen.
- A photo un-marked while comparing stays visible as "kept" (snapshot of the batch taken
  when the sheet opens). Delete sends only what is marked at the moment of the tap.
- Swiping still never marks; reordering cannot change what is in the batch.
- The drag uses SwiftUI's system drag-and-drop (`onDrag` / `onDrop`), with the dragged
  id held in view state rather than the payload. If it feels fiddly on device, swap in a
  custom long-press drag inside the filmstrip only.

---

## 9. Custom Review picks a time range; there is no "Review All"

**Decided:** with nothing selected, the library's primary button is **Custom Review**, a
menu of Last week / Last month / Last 3 months. The whole-library review is gone.

**Why:** reviewing an entire library is an unbounded, unfocused session — nobody culls
ten thousand photos in one sitting, and it made the review screen carry a huge list. A
time range is how people actually think about a cull ("this month's burst shots").

**Consequences:**
- Rolling ranges counted back from now (7 days / 1 month / 3 months), newest first. The
  rule lives in `CullCore.ReviewPeriod`, under test.
- An empty range shows a notice instead of an empty review screen.
- This is a scope the user chooses, not an inferred grouping, so decision #1 (no
  clustering, no similarity) is untouched.

---

## 10. The filmstrip lives under the photo from the start of review

**Decided:** the review screen shows the filmstrip directly under the photo the moment
review opens — every photo in the group, hold-and-drag to reorder — instead of only in
the confirm-delete sheet. The sheet keeps its own strip as the final compare step.
The photo sits a little above centre (at most 20pt, and only from spare room). The
filing popup is a compact centred card so the photo stays visible while filing.

**Why:** reordering to compare is something you do *while* culling, not after you have
already tapped Delete. This supersedes the part of decision #8 that made the confirm
sheet the only place to reorder; the reorder rules themselves (`CullSession.move`,
shared order, undo) are unchanged.

**Consequences:**
- One shared `Filmstrip` view and `FilmstripState`, used by both screens.
- On the review screen most photos are unmarked, so unmarked thumbnails are **not**
  dimmed there; only the confirm sheet dims photos you've un-marked ("kept").
- The Earlier / Later row stays in the confirm sheet only; the review screen has no
  room for it, and each thumbnail still has VoiceOver "move earlier/later" actions.

---

## 11. Browse like Photos; one delete preview; no undo; no instruction text

**Decided:**
- The library grid opens a photo on tap, like the Photos app. **Select** turns tapping
  into picking. Opening a photo pages the whole library, newest first, from that photo.
- The selection is kept when you go into Review and come back.
- With photos selected, the bar offers Album, Review N, and a trash-can button. The
  trash button and the review screen's trash button both open the same **delete
  preview** — the photos that will go and one Delete button — and nothing else.
- Each filmstrip thumbnail has its own mark circle (within thumb's reach), and
  double-tapping a thumbnail toggles its mark.
- The Undo toast and the Earlier/Later row are removed; the confirm sheet is a plain
  preview again. Instruction text ("Tap ✕ to mark…", "Swipe to compare…", "Tap photos,
  or drag…") is removed.

**Why:** reordering now happens while culling (decision #10), so a second compare step
at the confirm stage was redundant, and Undo added UI for something a drag can simply be
repeated to fix. Hints that restate the controls were noise.

**Kept on purpose:** two short notes that are platform facts, not instructions — "Goes to
Recently Deleted for 30 days" (what makes aggressive culling feel safe) and "Albums point
at your photos, they don't copy them" (people expect filing to free space).

**Supersedes:** the confirm-sheet parts of #8 (pager, Earlier/Later, undo) and the undo
part of #10. `CullSession.move`'s "came from" return value is unused for now but tested.

**Deliberate exception to #2's enforcement grep:** double-tapping a filmstrip thumbnail
marks it, so a tap gesture now mutates the mark set. The invariant that matters — *swiping
never marks, files, or deletes* — is intact: a double-tap is an explicit, deliberate
gesture (a swipe or a single tap can't trigger it), and it only marks; deleting still
takes the preview's Delete button plus iOS's own confirmation. The "no mark mutation in a
gesture handler" grep should therefore be read as "no mark mutation in a *swipe/drag*
handler".

---

## 12. The delete preview is the photo and filmstrip again; double-tap works on the photo too

**Decided:** the delete preview (shared by the review screen's and the grid's trash
buttons) shows each photo being deleted one at a time with the filmstrip under it, not a
grid. It has the same controls as review — the circle on the photo and on each thumbnail,
double-tap on the photo or a thumbnail, hold-and-drag to reorder. Still no Earlier/Later
row and no Undo. In review, double-tapping the main photo marks or un-marks it, like the
circle.

**Why:** a grid of thumbnails is too small to judge a photo you are about to lose, and it
had none of the controls people were already using. Reusing the review pieces means one
behaviour to learn and one implementation to keep correct. The circle on the big photo
sits high on a large phone, so double-tap is the reachable alternative.

**Supersedes:** the "plain grid preview" part of #11. The Recently Deleted note stays.

**Same exception as #11:** double-tap marks, but swiping still never does, and deleting
still needs the preview's Delete button plus iOS's own confirmation.

---

## 13. Marks survive leaving review; "0 photos marked" always shows; no "albums are references" note

**Decided:**
- Delete marks now survive leaving a review screen — including by an accidental swipe
  back to the grid — and are found again when review is reopened, from any entry point
  (a photo, a selection, or a Custom Review range). They live in memory for the life of
  the app (`MarkStore`), so backgrounding keeps them and a cold launch starts clean.
  This implements the "persist for the session" half of decision #5.
- The review screen's bottom bar always shows "N photos marked", Clear and the trash can
  (including "0 photos marked"); Clear and trash are disabled at zero.
- The album popup no longer carries the "Albums point at your photos, they don't copy
  them. Only deleting frees space." note.

**Why:** losing a hard-won set of marks to one slipped swipe is exactly the failure
decision #5 was written to prevent. An always-present bar means controls never appear
and disappear under your thumb. The album note was judged unnecessary by the owner.

**Consequences:**
- The grid's trash preview uses a model with **no** shared store, so cancelling it never
  leaves marks behind in later reviews.
- Filing still clears the mark, and the store is updated with it, so a filed photo can
  never come back marked. Deleted photos are forgotten by the store.
- `CullSession.restoreMarks` re-applies stored marks, ignoring any photo not in the
  session, so marks stay a subset of `photos` (invariant 1). Tested.
- **Departs from `CLAUDE.md`,** which said to explain in the UI that albums are
  references, not copies. The platform fact is unchanged — filing does not move or copy
  a photo and does not free space — only the on-screen reminder is gone, by the owner's
  choice.

