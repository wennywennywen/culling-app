import SwiftUI
import Photos
import CullCore

/// Drag bookkeeping for the filmstrip.
///
/// The order itself lives in `CullSession`; this only remembers what is being
/// dragged and where it would land.
@MainActor
@Observable
final class FilmstripState {

    var draggingID: String?
    var dropTargetID: String?

    /// Moves a photo into another's slot. `false` if nothing moved.
    @discardableResult
    func reorder(_ id: PhotoID, onto target: PhotoID, in model: ReviewModel) -> Bool {
        model.move(id, onto: target) != nil
    }

    /// Moves a photo one place along `assets`, onto its neighbour *in that list*.
    /// The VoiceOver way to reorder, since dragging is not an option there.
    @discardableResult
    func nudge(_ direction: Int, key: String, in assets: [PHAsset], model: ReviewModel) -> Bool {
        guard let index = assets.firstIndex(where: { $0.localIdentifier == key }),
              assets.indices.contains(index + direction)
        else { return false }
        return reorder(
            PhotoID(key),
            onto: PhotoID(assets[index + direction].localIdentifier),
            in: model
        )
    }
}

/// A horizontal strip of small photos under the pager.
///
/// - **Tap** a thumbnail to jump to it. Swiping the strip only scrolls it.
/// - **Hold and drag** onto another thumbnail to reorder.
/// - **The circle** in a thumbnail's corner marks or un-marks it — the same as the
///   circle on the big photo, but within thumb's reach.
/// - **Double-tap** a thumbnail to mark it; double-tap again to un-mark.
///
/// Reordering changes where a photo sits, never whether it survives
/// (`CullSession.move`, under test). Marking goes through `model.toggleMark`, the
/// same path as every other mark.
struct Filmstrip: View {
    let model: ReviewModel
    let assets: [PHAsset]
    @Binding var focusedID: String?
    let state: FilmstripState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(assets, id: \.localIdentifier) { asset in
                        let key = asset.localIdentifier
                        FilmstripThumb(
                            asset: asset,
                            isMarked: model.isMarked(PhotoID(key)),
                            isFocused: focusedID == key,
                            insertionEdge: insertionEdge(for: key),
                            onSelect: { withAnimation(.snappy) { focusedID = key } },
                            onToggleMark: { model.toggleMark(PhotoID(key)) }
                        )
                        .id(key)
                        // Lifting a thumbnail also brings it up in the big pager, so
                        // you can see exactly which photo you are holding.
                        .onDrag {
                            state.draggingID = key
                            focusedID = key
                            return NSItemProvider(object: key as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: FilmstripDrop(targetID: key, state: state) { dragged, target in
                                if state.reorder(PhotoID(dragged), onto: PhotoID(target), in: model) {
                                    focusedID = dragged
                                }
                            }
                        )
                        .accessibilityAction(named: "Move earlier") {
                            if state.nudge(-1, key: key, in: assets, model: model) { focusedID = key }
                        }
                        .accessibilityAction(named: "Move later") {
                            if state.nudge(1, key: key, in: assets, model: model) { focusedID = key }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                if let focusedID { proxy.scrollTo(focusedID, anchor: .center) }
            }
            .onChange(of: focusedID) { _, new in
                guard let new else { return }
                withAnimation(.snappy) { proxy.scrollTo(new, anchor: .center) }
            }
        }
        .frame(height: 92)
    }

    /// Which side of a thumbnail the dragged photo will land on. Dropping takes
    /// the target's slot, so dragging right lands after it and left lands before.
    private func insertionEdge(for key: String) -> Alignment? {
        guard state.dropTargetID == key,
              let dragging = state.draggingID,
              let from = assets.firstIndex(where: { $0.localIdentifier == dragging }),
              let to = assets.firstIndex(where: { $0.localIdentifier == key })
        else { return nil }
        return from < to ? .trailing : .leading
    }
}

/// Receives drops on one thumbnail and tracks where the dragged photo would land.
///
/// The dragged photo's id lives in `state.draggingID` rather than in the drag
/// payload, so the drop never depends on what another app might hand us.
private struct FilmstripDrop: DropDelegate {
    let targetID: String
    let state: FilmstripState
    let onMove: (_ dragged: String, _ target: String) -> Void

    func validateDrop(info: DropInfo) -> Bool { state.draggingID != nil }

    func dropEntered(info: DropInfo) {
        if state.draggingID != targetID { state.dropTargetID = targetID }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if state.dropTargetID == targetID { state.dropTargetID = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            state.draggingID = nil
            state.dropTargetID = nil
        }
        guard let dragged = state.draggingID, dragged != targetID else { return false }
        onMove(dragged, targetID)
        return true
    }
}

/// One small photo in the filmstrip.
///
/// 56×72pt with the whole cell as the hit area — big enough to grab accurately,
/// small enough that about six fit on screen.
///
/// The mark circle is a *sibling* of the photo, not a child: the photo carries tap
/// gestures, and a gesture on a parent would swallow taps meant for the circle.
private struct FilmstripThumb: View {
    let asset: PHAsset
    let isMarked: Bool
    let isFocused: Bool
    let insertionEdge: Alignment?
    let onSelect: () -> Void
    let onToggleMark: () -> Void

    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            photo
                // Double-tap gets first refusal, so a double-tap never also fires
                // as a single tap that jumps the pager.
                .gesture(
                    TapGesture(count: 2).onEnded(onToggleMark)
                        .exclusively(before: TapGesture().onEnded(onSelect))
                )

            // The negative padding pulls `MarkCircle`'s generous hit area back
            // inside the thumbnail, so it doesn't steal taps from its neighbours.
            MarkCircle(isMarked: isMarked, size: 18, action: onToggleMark)
                .padding(-6)
        }
    }

    private var photo: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.quaternary)
            .frame(width: 56, height: 72)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipShape(.rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isFocused ? Color.white : (isMarked ? Color.red : Color.clear),
                        lineWidth: isFocused ? 2.5 : 1.5
                    )
            }
            .overlay(alignment: insertionEdge ?? .leading) {
                if let insertionEdge {
                    Capsule()
                        .fill(.white)
                        .frame(width: 3)
                        .padding(.vertical, -2)
                        .offset(x: insertionEdge == .leading ? -5 : 5)
                }
            }
            .contentShape(.rect)
            .task(id: asset.localIdentifier) {
                let loaded = await ThumbnailProvider.shared.thumbnail(for: asset)
                guard !Task.isCancelled else { return }
                image = loaded
            }
    }
}
