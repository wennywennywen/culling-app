import SwiftUI
import Photos
import CullCore

/// Page through a chosen group, mark the rejects, file the keepers, delete once.
///
/// The core interaction rule, enforced by construction: **the pager's swipe is
/// navigation and nothing else.** Marking happens only through `MarkCircle`.
/// That is what makes paging back and forth free — a stray swipe can never cost
/// a photo.
struct ReviewView: View {
    let model: ReviewModel

    @State private var albumStore = AlbumStore()
    @State private var showingGroupGrid = false
    @State private var showingConfirmDelete = false
    @State private var isDeleting = false
    @State private var notice: String?

    /// Photos waiting on an album choice. Non-empty shows the album popup.
    @State private var albumTarget: [PHAsset] = []

    /// Drag state for the filmstrip under the photo.
    @State private var strip = FilmstripState()

    @Environment(\.colorScheme) private var systemColorScheme

    /// Which page the scroll view is resting on, as a `localIdentifier`.
    @State private var visibleID: String?

    var body: some View {
        Group {
            if model.isEmpty {
                ContentUnavailableView(
                    "All done",
                    systemImage: "checkmark.circle",
                    description: Text("Nothing left in this group.")
                )
            } else if showingGroupGrid {
                groupGrid
            } else {
                reviewPager
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingGroupGrid.toggle()
                } label: {
                    Image(systemName: showingGroupGrid ? "rectangle.portrait" : "square.grid.2x2")
                }
                .accessibilityLabel(showingGroupGrid ? "Show one at a time" : "Show all")
            }
        }
        .safeAreaInset(edge: .bottom) { statusBar }
        .task { albumStore.load() }
        .onDisappear { ThumbnailProvider.shared.stopCachingPages() }
        .albumPopup(for: $albumTarget, store: albumStore) { assets, albumID in
            // Filing implies keeping — this clears any delete mark. Runs only after
            // the write succeeds, so a failed file never looks like a save.
            model.recordFiled(assets.map { PhotoID($0.localIdentifier) }, into: albumID)
        }
        .sheet(isPresented: $showingConfirmDelete) {
            ConfirmDeleteSheet(model: model, isDeleting: $isDeleting) { outcome in
                handle(outcome)
            }
        }
        .alert(
            "Cull",
            isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
        ) {
            Button("OK", role: .cancel) { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    /// Plain text, deliberately.
    ///
    /// `navigationTitle` taking a `String` uses the non-localized overload, which
    /// does **not** parse `^[…](inflect:)` markup — it renders it raw on screen.
    /// Inflection only works when the value reaches a `LocalizedStringKey`, so
    /// computed `String` properties must spell plurals out themselves.
    private var navigationTitle: String {
        model.markedCount > 0 ? "\(model.markedCount) marked" : ""
    }

    // MARK: - Pager

    /// The photo with its filmstrip directly underneath, like the Photos app —
    /// there from the moment review opens, so reordering happens while you cull.
    private var reviewPager: some View {
        VStack(spacing: 0) {
            pager
            Filmstrip(
                model: model,
                assets: model.assets,
                focusedID: $visibleID,
                state: strip
            )
            .background(.black)
            .environment(\.colorScheme, .dark)
        }
    }

    /// A lazy paging scroll view rather than `TabView`.
    ///
    /// `TabView` builds a child view for every element up front. That is fine for
    /// a forty-photo shoot and badly wrong for a Custom Review over months of photos —
    /// it is the main reason paging felt like it was catching. `LazyHStack` only
    /// materialises what is near the viewport, so cost stops scaling with library
    /// size.
    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(model.assets, id: \.localIdentifier) { asset in
                    let id = PhotoID(asset.localIdentifier)
                    ReviewPage(
                        asset: asset,
                        isMarked: model.isMarked(id),
                        isFiled: !model.albums(for: id).isEmpty,
                        onToggleMark: { model.toggleMark(id) },
                        onFile: { presentAlbumPicker(for: [asset]) }
                    )
                    .containerRelativeFrame(.horizontal)
                    .id(asset.localIdentifier)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $visibleID)
        .scrollIndicators(.hidden)
        .background(.black)
        .onAppear { visibleID = model.currentPhoto?.rawValue }
        .onChange(of: visibleID) { _, new in
            guard let new else { return }
            // Navigation only. If this ever mutates marks, swiping starts
            // destroying photos.
            model.goTo(PhotoID(new))
            prefetchPages(around: new)
        }
    }

    /// Warms the neighbouring pages so a swipe lands on an image that is already
    /// decoded instead of starting one from cold.
    private func prefetchPages(around identifier: String) {
        guard let index = model.assets.firstIndex(where: { $0.localIdentifier == identifier })
        else { return }

        // Two either side. These are full-screen bitmaps — a wider window buys
        // little and costs a lot of memory.
        let lower = max(0, index - 2)
        let upper = min(model.assets.count - 1, index + 2)
        let window = Array(model.assets[lower...upper])

        let size = UIScreen.main.bounds.size
        let scale = UITraitCollection.current.displayScale
        ThumbnailProvider.shared.startCachingPages(
            window,
            size: CGSize(width: size.width * scale, height: size.height * scale)
        )
    }

    // MARK: - Group grid

    private var groupGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3),
                spacing: 2
            ) {
                ForEach(model.assets, id: \.localIdentifier) { asset in
                    let id = PhotoID(asset.localIdentifier)
                    MarkableCell(
                        asset: asset,
                        isMarked: model.isMarked(id),
                        isFiled: !model.albums(for: id).isEmpty,
                        onToggleMark: { model.toggleMark(id) },
                        onOpen: {
                            model.goTo(id)
                            showingGroupGrid = false
                        },
                        onFile: { presentAlbumPicker(for: [asset]) }
                    )
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Status bar

    /// Always there — "0 photos marked", Clear and the trash can — so the layout never
    /// shifts and the controls are where you expect them. Clear and trash wake up
    /// once something is marked.
    private var statusBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("^[\(model.markedCount) photo](inflect: true) marked")
                    .font(.subheadline.weight(.medium))
                if model.filedCount > 0 {
                    Text("^[\(model.filedCount) photo](inflect: true) filed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Clear") { model.unmarkAll() }
                .font(.subheadline)
                .disabled(model.markedCount == 0)

            Button {
                showingConfirmDelete = true
            } label: {
                Image(systemName: "trash")
                    .frame(minWidth: 20)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(model.markedCount == 0)
            .accessibilityLabel("Delete \(model.markedCount) marked")
        }
        .frame(minHeight: 36)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(showingGroupGrid ? AnyShapeStyle(.bar) : AnyShapeStyle(.black))
        .environment(\.colorScheme, showingGroupGrid ? systemColorScheme : .dark)
    }

    // MARK: - Filing

    private func presentAlbumPicker(for assets: [PHAsset]) {
        albumTarget = assets
    }

    // MARK: - Deletion outcome

    private func handle(_ outcome: BatchDelete.Outcome) {
        // Only drop photos that really left the library. If iOS never confirmed and
        // a re-fetch shows them still there, they stay in the session to retry.
        if outcome.removedAny {
            model.removeDeleted(model.session.deletionBatch)
        }
        notice = outcome.userMessage
    }
}

// MARK: - Confirm sheet

/// Last look before deleting: each photo that will go, one at a time, with the
/// filmstrip under it, and one Delete button.
///
/// Shared by the review screen and the library grid's trash button, so both end
/// at the same place. It behaves like review itself — the circle, double-tap and
/// the filmstrip all mark and un-mark — so a photo you decide to keep can be
/// rescued right here.
///
/// Deliberately not skippable: `BatchDelete` is the only way out, and iOS adds its
/// own confirmation on top.
struct ConfirmDeleteSheet: View {
    let model: ReviewModel
    @Binding var isDeleting: Bool
    let onFinished: (BatchDelete.Outcome) -> Void

    @Environment(\.dismiss) private var dismiss

    /// The photos that were marked when the sheet opened.
    ///
    /// A photo you un-mark here stays on screen — its circle simply goes hollow —
    /// instead of vanishing mid-swipe. `@State` because the sheet content is
    /// rebuilt whenever a mark changes, and a plain `let` would re-snapshot and
    /// drop the photo anyway. Delete still sends only what is marked *now*.
    @State private var batch: Set<PhotoID>

    /// The photo the pager rests on, as a `localIdentifier`.
    @State private var focusedID: String?

    @State private var strip = FilmstripState()

    init(
        model: ReviewModel,
        isDeleting: Binding<Bool>,
        onFinished: @escaping (BatchDelete.Outcome) -> Void
    ) {
        self.model = model
        self._isDeleting = isDeleting
        self.onFinished = onFinished

        let ids = model.session.deletionBatch
        _batch = State(initialValue: Set(ids))
        let start = model.currentPhoto.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        _focusedID = State(initialValue: start?.rawValue)
    }

    /// The batch in the session's current order.
    private var batchAssets: [PHAsset] {
        model.assets.filter { batch.contains(PhotoID($0.localIdentifier)) }
    }

    var body: some View {
        let assets = batchAssets

        NavigationStack {
            VStack(spacing: 0) {
                pager(assets)
                Filmstrip(
                    model: model,
                    assets: assets,
                    focusedID: $focusedID,
                    state: strip
                )
                .background(.black)
                .environment(\.colorScheme, .dark)
            }
            .background(.black)
            .navigationTitle("\(model.markedCount) to delete")
            .navigationBarTitleDisplayMode(.inline)
            // The pager's black runs up under the bar, so the default dark title
            // text vanishes into it.
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { footer }
        }
        .interactiveDismissDisabled(isDeleting)
    }

    private func pager(_ assets: [PHAsset]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(assets, id: \.localIdentifier) { asset in
                    let id = PhotoID(asset.localIdentifier)
                    ReviewPage(
                        asset: asset,
                        isMarked: model.isMarked(id),
                        isFiled: false,
                        onToggleMark: { model.toggleMark(id) },
                        onFile: {}
                    )
                    .containerRelativeFrame(.horizontal)
                    .id(asset.localIdentifier)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $focusedID)
        .scrollIndicators(.hidden)
        .background(.black)
        .onChange(of: focusedID) { _, new in
            // Navigation only. Same rule as the main pager.
            guard let new else { return }
            model.goTo(PhotoID(new))
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            // Says what makes deleting safe — it isn't permanent yet.
            Text("Goes to Recently Deleted for 30 days.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                Task { await runDelete() }
            } label: {
                if isDeleting {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Delete \(model.markedCount)").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)
            .disabled(isDeleting || model.markedCount == 0)
        }
        .padding(20)
        .background(.bar)
    }

    private func runDelete() async {
        isDeleting = true
        // iOS shows its own confirmation on top of this one and it cannot be
        // suppressed. One dialog covers the whole batch — which is exactly why
        // marking and deleting are separate steps.
        let outcome = await BatchDelete.delete(model.markedAssets)
        isDeleting = false
        onFinished(outcome)
        dismiss()
    }
}

// MARK: - One full-screen photo

private struct ReviewPage: View {
    let asset: PHAsset
    let isMarked: Bool
    let isFiled: Bool
    let onToggleMark: () -> Void
    let onFile: () -> Void

    /// Low-res stand-in, almost always already warm in the grid's cache.
    @State private var thumbnail: UIImage?
    /// The real thing, once it has decoded.
    @State private var fullImage: UIImage?

    /// Prefer the sharp one, fall back to the instant one.
    private var displayed: UIImage? { fullImage ?? thumbnail }

    var body: some View {
        GeometryReader { proxy in
            // The photo is letterboxed inside the screen, so overlays have to be
            // pinned to the *photo's* rectangle. Anchoring them to the container
            // leaves them floating in the black margin instead of on the image.
            let fitted = fittedSize(in: proxy.size)
            // Sit a little above centre, like the Photos app. Capped, and only
            // from spare room, so a tall photo is never pushed up under the bar.
            let lift = min(20, max(0, proxy.size.height - fitted.height) / 2)

            ZStack {
                Color.black

                Group {
                    if let displayed {
                        Image(uiImage: displayed)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .frame(width: fitted.width, height: fitted.height)
                // Double-tap marks or un-marks, same as the circle — which sits too
                // high on a big phone to reach one-handed. Set before the overlays
                // so a single tap on the circle itself is left alone.
                .onTapGesture(count: 2, perform: onToggleMark)
                .overlay(alignment: .topTrailing) {
                    MarkCircle(isMarked: isMarked, size: 26, action: onToggleMark)
                        .padding(2)
                }
                .overlay(alignment: .topLeading) {
                    if isFiled {
                        Image(systemName: "rectangle.stack.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.35), in: .circle)
                            .padding(6)
                    }
                }
                .contentShape(.rect)
                .onLongPressGesture(minimumDuration: 0.35, perform: onFile)
                .offset(y: -lift)
            }
            .animation(.snappy(duration: 0.15), value: isMarked)
            .task(id: asset.localIdentifier) {
                // Thumbnail first. The grid has almost certainly cached it, so it
                // arrives immediately — a swipe lands on a soft picture that then
                // sharpens, rather than on a spinner. This is most of what makes
                // fast paging feel smooth.
                if fullImage == nil {
                    thumbnail = await ThumbnailProvider.shared.thumbnail(for: asset)
                }
                guard !Task.isCancelled else { return }

                // GeometryReader reports .zero on the first layout pass. Asking
                // PhotoKit for a zero-sized image gets you a useless one, and it
                // would be cached at that size — so fall back to the screen
                // bounds until a real size arrives.
                let fallback = UIScreen.main.bounds.size
                let points = proxy.size.width > 1 ? proxy.size : fallback
                let scale = UITraitCollection.current.displayScale
                let target = CGSize(width: points.width * scale, height: points.height * scale)

                let loaded = await ThumbnailProvider.shared.displayImage(for: asset, size: target)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.12)) { fullImage = loaded }
            }
        }
    }

    /// How large the photo actually renders once letterboxed into `container`.
    ///
    /// Derived from `PHAsset`'s pixel dimensions rather than the loaded image, so
    /// the overlays are positioned correctly on the very first frame instead of
    /// jumping when the photo finishes loading.
    private func fittedSize(in container: CGSize) -> CGSize {
        let width = CGFloat(asset.pixelWidth)
        let height = CGFloat(asset.pixelHeight)
        guard width > 0, height > 0, container.width > 0, container.height > 0 else {
            return container
        }

        let scale = min(container.width / width, container.height / height)
        return CGSize(width: width * scale, height: height * scale)
    }
}

// MARK: - One thumbnail with a mark circle

private struct MarkableCell: View {
    let asset: PHAsset
    let isMarked: Bool
    let isFiled: Bool
    let onToggleMark: () -> Void
    let onOpen: () -> Void
    let onFile: (() -> Void)?

    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay {
                // A red frame around the cell, not a wash over the photo — the
                // point of this screen is judging the photos, and tinting them
                // is exactly what stops you being able to.
                if isMarked {
                    Rectangle().strokeBorder(.red, lineWidth: 1.5)
                }
            }
            .overlay(alignment: .topLeading) {
                if isFiled {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.35), in: .circle)
                        .padding(3)
                }
            }
            .overlay(alignment: .topTrailing) {
                MarkCircle(isMarked: isMarked, size: 22, action: onToggleMark)
                    .padding(-4)
            }
            .contentShape(.rect)
            .onTapGesture(perform: onOpen)
            .onLongPressGesture(minimumDuration: 0.35) { onFile?() }
            .animation(.snappy(duration: 0.15), value: isMarked)
            .task(id: asset.localIdentifier) {
                let loaded = await ThumbnailProvider.shared.thumbnail(for: asset)
                guard !Task.isCancelled else { return }
                image = loaded
            }
    }
}
