# Device tests

**Only a human with an iPhone can run these.** PhotoKit does not work in the
Simulator in any meaningful way, and no agent can drive a physical device. Nothing
here may be marked passed by an automated check.

★ = the ones that matter. The rest is plumbing.

> **Phase 1: verified on device** (iPhone 15, iOS 18.7.8) — access gate, full-access
> grant, and the photo grid all confirmed working against a real library.
> **Phase 2 is unverified.**

## Library

- [x] Full access granted → all photos appear
- [ ] Limited access ("Select Photos…") → clear explanation screen with a Settings
      link, **not** an empty grid
- [ ] Access revoked in Settings while the app is open → app recovers, no crash
- [x] Real library → grid scrolls smoothly
- [ ] Multi-select 40 photos → "Review these" opens with all 40

## Review and marking

- [ ] Swipe left/right pages between photos and marks **nothing**
- [ ] Tap ○ → fills to ●; tap again → clears
- [ ] Circle also works on grid thumbnails without opening the photo
- [ ] Page away and back → mark state preserved
- [ ] Review screen matches exactly what was marked
- [ ] ★ Mark photos in review, swipe back to the grid, open review again → the marks are still there
- [ ] Marks survive opening a *different* review that contains the same photos (photo tap, selection, Custom Review)
- [ ] Cancel out of the grid's trash preview → nothing is left marked in later reviews
- [ ] Background the app mid-review, return → marks still there (decision #5)
- [ ] Force-quit and cold launch → marks cleared (decision #5)
- [ ] ★ **ONE** confirmation dialog for the whole batch, not one per photo
- [ ] ★ Deleted photos gone from Photos, present in Recently Deleted
- [ ] Delete a photo in the Photos app mid-review → app doesn't crash, photo
      disappears from the session
- [ ] Delete completion handler never fires (iOS 26 bug) → timeout fires, app
      re-fetches and shows the true state rather than hanging

## Custom Review

- [ ] With nothing selected the bottom button reads **Custom Review** and opens Last week / Last month / Last 3 months
- [ ] Each choice opens review with only photos from that range, newest first
- [ ] A range with no photos shows "No photos in the …" instead of an empty review screen
- [ ] With photos selected the button is still "Review N" and reviews exactly those

## Library grid

**Unverified on device.** Seen in the Simulator with seeded photos.

- [ ] Tapping a photo opens it full-screen on that photo (like the Photos app), with the filmstrip under it
- [ ] Select → tapping picks photos; drag sideways sweeps a run; Cancel leaves selection mode
- [ ] With photos selected the bar shows Album (left), Review N, and a trash-can button (bottom right)
- [ ] ★ Review N, then back → the same photos are still selected
- [ ] ★ Trash → preview of exactly the selected photos with one Delete button; Cancel leaves everything as it was
- [ ] Trash → Delete → ONE iOS confirmation, then only those photos are gone; selection clears
- [ ] Delete in review, back to the grid → the selection no longer counts the deleted photos

## Filmstrip under the photo (review screen)

**Unverified on device.** Seen in the Simulator: the strip sits under the photo as soon
as review opens, marking from the strip works, drag-to-reorder works.

- [ ] Strip is there the moment review opens, right under the photo, thumbnails 56×72
- [ ] Photo sits a little above centre (Photos-app feel); a tall photo isn't pushed up under the bar
- [ ] Swipe the photo → strip follows; tap a thumbnail → photo jumps; **nothing** gets marked by either
- [ ] ★ The circle on a thumbnail marks/un-marks it, is easy to hit with a thumb, and doesn't jump the pager
- [ ] ★ Double-tap a thumbnail → marked; double-tap again → un-marked (and it doesn't also jump the pager)
- [ ] ★ Double-tap the **main photo** → marked; double-tap again → un-marked; the circle still works on a single tap
- [ ] ★ Hold a thumbnail and drag onto another → lands on the correct side, big photo follows
- [ ] Drag to the edge of the strip → it auto-scrolls (if not, note it)
- [ ] Marked photos show a red frame and ✕ in the strip; unmarked ones are **not** dimmed
- [ ] Bottom bar always shows "N photos marked", Clear and the trash can — including "0 photos marked" with Clear and trash dimmed
- [ ] Marking a photo lights up Clear and the trash; no word "Delete" on the bar
- [ ] Mark a photo, file it into an album → its mark clears (filing clears the mark)
- [ ] Reorder here, then trash → the preview shows only the marked photos
- [ ] VoiceOver: thumbnails offer "Move earlier" / "Move later" actions

## Delete preview sheet

**Unverified on device.** Seen in the Simulator: photo + filmstrip, un-marking keeps the
photo in place with a hollow circle.

- [ ] Trash → each photo being deleted is shown one at a time, with the filmstrip under it
- [ ] No Earlier/Later row and no Undo — just the preview, "Goes to Recently Deleted for 30 days.", and Delete
- [ ] ★ The circle on the photo, the circle on a thumbnail, and double-tap (photo or thumbnail) all un-mark / re-mark; the count and the Delete button follow
- [ ] An un-marked photo stays visible (hollow circle) instead of vanishing mid-swipe, and is **not** deleted
- [ ] Hold-and-drag on the strip reorders here too
- [ ] ★ Delete → exactly the photos still marked are deleted, no more, no fewer
- [ ] If iOS never confirms and a re-fetch shows the photos still there, they stay in the review to retry

## Filing

- [ ] Long-press on the current photo → compact album popup appears in the middle, photo still visible behind it
- [ ] Tap an album → filed instantly, **no system prompt**, popup closes; tapping outside or ✕ also closes it
- [ ] Photo actually appears in that album in the Photos app
- [ ] Albums the photo is already in show a checkmark
- [ ] Smart albums (Recents, Favourites, Screenshots) are **not** offered
- [ ] A shared album you don't own is **not** offered
- [ ] "New Album…" creates and files in one step
- [ ] Recently-used albums are pinned at the top, most recent first
- [ ] Multi-select in the grid → "Album" → same popup, all selected filed in one operation
- [ ] Popup shrinks to fit few albums and scrolls once there are many (about five rows)
- [ ] ★ Mark for deletion, then file → mark clears, photo **survives** the batch delete
- [ ] File the same photo into the same album twice → no duplicate entry
- [ ] Filing does **not** remove the photo from the main library (it's a reference)

## Camera

- [ ] Hold shutter → burst captures
- [ ] All shots from one hold land in a single session album
- [ ] Session opens directly into review mode

## Editing

- [ ] Caption renders correctly over the photo
- [ ] Saves as a **new** asset
- [ ] ★ Original is unmodified
