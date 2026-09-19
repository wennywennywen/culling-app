import SwiftUI
import Photos
import CullCore

/// A small card, centred over whatever you are looking at, for filing photos.
///
/// Deliberately not a sheet: filing happens mid-review, and a sheet or action
/// sheet hides the very photo you are deciding about. This one is compact and the
/// screen behind it is only lightly dimmed, so the photo stays visible.
///
/// Filing is silent — no system prompt — so the card closes the instant you tap an
/// album. One tap, back to reviewing. (An earlier version also explained that albums
/// point at photos rather than copy them; that note was dropped at the owner's
/// request — see decision #13.)
private struct AlbumPopup: View {
    let assets: [PHAsset]
    let store: AlbumStore
    /// Called after a successful file, with the photos that were filed, so the
    /// caller can clear their delete marks.
    let onFiled: ([PHAsset], AlbumID) -> Void
    let onClose: () -> Void

    @State private var membership: Set<AlbumID> = []
    @State private var isCreating = false
    @State private var newAlbumName = ""
    @State private var errorMessage: String?
    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            // As tall as its rows, capped at about five — a card with one row
            // shouldn't be stretched to fill space, and a long list scrolls.
            // `frame(maxHeight:)` can't do this: it expands to the cap rather than
            // stopping at the content. Rows are a fixed height, so it is counted.
            ScrollView { rows }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(rowsHeight, 230))

        }
        .foregroundStyle(.primary)
        .frame(maxWidth: 300)
        .background(.regularMaterial, in: .rect(cornerRadius: 20))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .padding(.horizontal, 24)
        .task {
            store.load()
            if let single = assets.first, assets.count == 1 {
                membership = store.albums(containing: single)
            }
        }
        .alert("New Album", isPresented: $isCreating) {
            TextField("Name", text: $newAlbumName)
            Button("Cancel", role: .cancel) { newAlbumName = "" }
            Button("Create") { Task { await createAndFile() } }
        }
        .alert(
            "Couldn't file",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .accessibilityAddTraits(.isModal)
    }

    private static let rowHeight: CGFloat = 44

    /// "New Album…" plus one row per album, with a hairline between each.
    private var rowsHeight: CGFloat {
        let count = CGFloat(store.orderedAlbums.count + 1)
        return count * Self.rowHeight + (count - 1)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            Button {
                isCreating = true
            } label: {
                row(Label("New Album…", systemImage: "plus.circle"), checked: false)
            }

            ForEach(store.orderedAlbums) { album in
                Divider().padding(.leading, 16)
                Button {
                    Task { await file(into: album.id) }
                } label: {
                    row(
                        Label(album.title, systemImage: "rectangle.stack"),
                        // Already in here — filing again is a no-op, and saying
                        // so stops you wondering if the tap worked.
                        checked: membership.contains(album.id)
                    )
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text(assets.count == 1 ? "Add to Album" : "Add \(assets.count) to Album")
                .font(.headline)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func row(_ label: Label<Text, Image>, checked: Bool) -> some View {
        HStack {
            label
            Spacer()
            if checked {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: Self.rowHeight)
        .contentShape(.rect)
    }

    private func file(into albumID: AlbumID) async {
        do {
            try await store.file(assets, into: albumID)
            onFiled(assets, albumID)
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createAndFile() async {
        let name = newAlbumName
        newAlbumName = ""
        do {
            let id = try await store.createAlbum(named: name)
            await file(into: id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension View {
    /// Shows the album popup while `assets` is non-empty; setting it back to `[]`
    /// closes it. Tapping outside the card closes it too.
    func albumPopup(
        for assets: Binding<[PHAsset]>,
        store: AlbumStore,
        onFiled: @escaping ([PHAsset], AlbumID) -> Void
    ) -> some View {
        overlay {
            if !assets.wrappedValue.isEmpty {
                ZStack {
                    // Light on purpose — the photo behind is the point.
                    Color.black.opacity(0.2)
                        .ignoresSafeArea()
                        .onTapGesture { assets.wrappedValue = [] }

                    AlbumPopup(
                        assets: assets.wrappedValue,
                        store: store,
                        onFiled: onFiled,
                        onClose: { assets.wrappedValue = [] }
                    )
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.snappy(duration: 0.2), value: assets.wrappedValue.isEmpty)
    }
}
