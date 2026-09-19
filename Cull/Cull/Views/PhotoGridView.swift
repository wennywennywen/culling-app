import SwiftUI
import Photos
import CullCore

/// Collects each rendered cell's frame so a drag can be hit-tested against them.
///
/// Only cells `LazyVGrid` has actually materialised report in, so this stays at
/// roughly a screenful of entries no matter how large the library is.
private struct CellFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The whole library, newest first, and where a group gets chosen.
///
/// Selecting here is **not** marking. Choosing a group is a blue checkmark and is
/// entirely harmless; marking for deletion is the red circle, and only exists
/// inside review. Keeping the two affordances distinct matters — one picks what
/// to look at, the other decides what dies.
struct PhotoGridView: View {
    let library: PhotoLibraryModel

    @AppStorage("galleryColumnCount") private var columnCount = 3

    /// Off by default, like the Photos app: tapping a photo opens it. **Select**
    /// turns tapping into picking a group.
    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var reviewModel: ReviewModel?
    @State private var albumStore = AlbumStore()
    @State private var filingAssets: [PHAsset] = []
    @State private var notice: String?

    /// The selection being deleted from the grid's trash button. Non-nil shows the
    /// same confirm sheet the review screen uses.
    @State private var deleteModel: ReviewModel?

    /// Delete marks shared by every review opened from here, so backing out of one
    /// and coming back finds them again. In memory only (decision #5).
    @State private var marks = MarkStore()
    @State private var isDeleting = false

    // Drag-to-select state
    @State private var cellFrames: [String: CGRect] = [:]
    @State private var isDragSelecting = false
    @State private var dragAnchorID: String?
    @State private var selectionBeforeDrag: Set<String> = []
    @State private var dragAdds = true

    private let spacing: CGFloat = 2

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.assets.isEmpty {
                    ContentUnavailableView(
                        "No photos yet",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Photos you take will show up here.")
                    )
                } else {
                    grid
                }
            }
            .navigationTitle(isSelecting ? selectionTitle : "Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) { selectionBar }
            .navigationDestination(item: $reviewModel) { model in
                ReviewView(model: model)
            }
            .alert(
                "Cull",
                isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
            ) {
                Button("OK", role: .cancel) { notice = nil }
            } message: {
                Text(notice ?? "")
            }
            .albumPopup(for: $filingAssets, store: albumStore) { _, _ in
                // Filing from the library is purely additive — there are no
                // delete marks out here to clear.
                selection.removeAll()
            }
            .sheet(isPresented: Binding(
                get: { deleteModel != nil },
                set: { if !$0 { deleteModel = nil } }
            )) {
                if let deleteModel {
                    ConfirmDeleteSheet(model: deleteModel, isDeleting: $isDeleting) { outcome in
                        finishDelete(outcome)
                    }
                }
            }
            // Photos deleted in review (or elsewhere) shouldn't linger in the
            // selection and inflate its count.
            .onChange(of: library.assets.count) {
                let live = Set(library.assets.map(\.localIdentifier))
                selection.formIntersection(live)
                marks.keepOnly(Set(live.map(PhotoID.init)))
            }
        }
    }

    private var selectionTitle: String {
        selection.isEmpty ? "Select photos" : "\(selection.count) selected"
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(isSelecting ? "Cancel" : "Select") {
                withAnimation(.snappy(duration: 0.2)) {
                    isSelecting.toggle()
                    if !isSelecting { selection.removeAll() }
                }
            }
        }

        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Photos per row", selection: $columnCount) {
                    Label("3 per row", systemImage: "square.grid.3x3").tag(3)
                    Label("5 per row", systemImage: "square.grid.4x3.fill").tag(5)
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: columnCount == 3 ? "square.grid.3x3" : "square.grid.4x3.fill")
            }
            .accessibilityLabel("Photos per row")
        }
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: spacing) {
                ForEach(library.assets, id: \.localIdentifier) { asset in
                    PhotoThumbnail(
                        asset: asset,
                        isSelecting: isSelecting,
                        isSelected: selection.contains(asset.localIdentifier),
                        checkSize: columnCount >= 5 ? 16 : 22
                    ) {
                        if isSelecting {
                            toggleSelection(of: asset.localIdentifier)
                        } else {
                            openPhoto(asset)
                        }
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: CellFramesKey.self,
                                value: [asset.localIdentifier: geo.frame(in: .named("grid"))]
                            )
                        }
                    )
                }
            }
            .padding(.horizontal, spacing)
            .animation(.snappy(duration: 0.2), value: columnCount)
        }
        .coordinateSpace(name: "grid")
        .onPreferenceChange(CellFramesKey.self) { cellFrames = $0 }
        // Suspended mid-gesture once a drag is classified as a selection, so the
        // finger can sweep down through rows without the list scrolling away
        // underneath it.
        .scrollDisabled(isDragSelecting)
        .simultaneousGesture(isSelecting ? dragSelectGesture : nil)
        .onDisappear { ThumbnailProvider.shared.resetCache() }
    }

    // MARK: - Drag to select

    /// Sweep across photos to select a run of them.
    ///
    /// A drag in selection mode is ambiguous — it could mean "scroll" or "select
    /// these". It is classified once, from the first few points of movement:
    /// mostly-sideways means select, mostly-vertical means scroll. Once it is a
    /// selection the gesture keeps it, so a sweep can curve down through rows
    /// without turning back into a scroll halfway.
    private var dragSelectGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("grid"))
            .onChanged { value in
                if !isDragSelecting {
                    let dx = abs(value.translation.width)
                    let dy = abs(value.translation.height)
                    guard dx > dy else { return } // vertical: leave it to the scroll view

                    guard let startID = assetID(at: value.startLocation) else { return }
                    isDragSelecting = true
                    dragAnchorID = startID
                    selectionBeforeDrag = selection
                    // Starting on a selected photo means the sweep is removing,
                    // which is how you undo an overshoot without starting over.
                    dragAdds = !selection.contains(startID)
                }

                guard isDragSelecting,
                      let anchorID = dragAnchorID,
                      let currentID = assetID(at: value.location)
                else { return }

                applySweep(from: anchorID, to: currentID)
            }
            .onEnded { _ in
                isDragSelecting = false
                dragAnchorID = nil
                selectionBeforeDrag = []
            }
    }

    /// Which photo is under this point, if any.
    private func assetID(at point: CGPoint) -> String? {
        cellFrames.first { $0.value.contains(point) }?.key
    }

    /// Applies the swept range to the selection as it stood when the drag began.
    ///
    /// Recomputed from `selectionBeforeDrag` every update rather than mutated
    /// incrementally, so backing up over your own path correctly un-does it.
    private func applySweep(from anchorID: String, to currentID: String) {
        let ids = library.assets.map(\.localIdentifier)
        guard let a = ids.firstIndex(of: anchorID),
              let b = ids.firstIndex(of: currentID)
        else { return }

        let swept = Set(ids[min(a, b)...max(a, b)])
        selection = dragAdds
            ? selectionBeforeDrag.union(swept)
            : selectionBeforeDrag.subtracting(swept)
    }

    private func toggleSelection(of id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    // MARK: - Selection bar

    private var selectionBar: some View {
        HStack(spacing: 12) {
            if !selection.isEmpty {
                Button {
                    filingAssets = selectedAssets()
                } label: {
                    Label("Album", systemImage: "rectangle.stack.badge.plus")
                }
            }

            Spacer()

            // Always useful: with nothing picked it offers a time range instead of
            // a selection step, so browsing-and-culling still needs no picking.
            // Never disabled — a disabled primary action just looks broken.
            if selection.isEmpty {
                Menu {
                    ForEach(ReviewPeriod.allCases, id: \.self) { period in
                        Button(period.title) { startReview(in: period) }
                    }
                } label: {
                    Text("Custom Review")
                        .frame(minWidth: 92)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    startReview()
                } label: {
                    Text("Review \(selection.count)")
                        .frame(minWidth: 92)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    startDelete()
                } label: {
                    Image(systemName: "trash")
                        .frame(minWidth: 20)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .accessibilityLabel("Delete \(selection.count) selected")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// Opens one photo full-screen, like tapping a photo in the Photos app: the
    /// whole library, newest first, resting on the one you tapped.
    private func openPhoto(_ asset: PHAsset) {
        let model = ReviewModel(assets: library.assets, marks: marks)
        model.goTo(PhotoID(asset.localIdentifier))
        reviewModel = model
    }

    /// Sends the selection to the confirm sheet. Marking here is local state in a
    /// throwaway model — nothing is deleted until the sheet's Delete button and
    /// iOS's own confirmation, both of which go through `BatchDelete`.
    private func startDelete() {
        // No shared marks here: this model is a throwaway, and cancelling the
        // preview must not leave its marks behind for later reviews.
        let model = ReviewModel(assets: selectedAssets())
        guard !model.isEmpty else { return }
        model.markAll()
        deleteModel = model
    }

    private func finishDelete(_ outcome: BatchDelete.Outcome) {
        // Only clear the selection if photos really went; otherwise the user can
        // simply try again with the same selection.
        if outcome.removedAny { selection.removeAll() }
        notice = outcome.userMessage
    }

    /// Review everything taken within `period`, newest first.
    ///
    /// The range is the user's choice, not an inferred grouping. Marking, filing
    /// and deleting behave exactly as they do for a hand-picked group; only the
    /// source of the list differs.
    private func startReview(in period: ReviewPeriod) {
        let now = Date()
        let chosen = library.assets.filter { period.includes($0.creationDate, relativeTo: now) }
        guard !chosen.isEmpty else {
            // An empty review screen reads as broken; say what happened instead.
            notice = "No photos in the \(period.title.lowercased())."
            return
        }
        reviewModel = ReviewModel(assets: chosen, marks: marks)
    }

    /// Selected photos in grid order, not tap order.
    private func selectedAssets() -> [PHAsset] {
        library.assets.filter { selection.contains($0.localIdentifier) }
    }

    private func startReview() {
        // Preserve the grid's newest-first order rather than the order the user
        // happened to tap in — paging through a shoot chronologically is what
        // makes near-identical shots comparable.
        let chosen = library.assets.filter { selection.contains($0.localIdentifier) }
        guard !chosen.isEmpty else { return }

        // The selection is kept, so backing out of review returns to the same
        // picks instead of an emptied grid.
        reviewModel = ReviewModel(assets: chosen, marks: marks)
    }
}

// MARK: - One grid cell

private struct PhotoThumbnail: View {
    let asset: PHAsset
    let isSelecting: Bool
    let isSelected: Bool
    var checkSize: CGFloat = 22
    let onTap: () -> Void

    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .overlay {
                if isSelected {
                    Rectangle()
                        .strokeBorder(.blue, lineWidth: 1.5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelecting {
                    SelectionCheck(isSelected: isSelected, size: checkSize)
                        .padding(4)
                }
            }
            .contentShape(.rect)
            .onTapGesture(perform: onTap)
            .animation(.snappy(duration: 0.15), value: isSelected)
            .task(id: asset.localIdentifier) {
                // `.task(id:)` cancels and restarts if the cell is recycled for
                // a different asset, so a slow load can never land on the wrong
                // photo.
                let loaded = await ThumbnailProvider.shared.thumbnail(for: asset)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.15)) { image = loaded }
            }
    }
}

/// Blue checkmark: "include this in the group". Deliberately not the red circle.
private struct SelectionCheck: View {
    let isSelected: Bool
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? .blue : .black.opacity(0.25))
            Circle()
                .strokeBorder(.white, lineWidth: 1.5)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}
