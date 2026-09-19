import SwiftUI

/// Routes on photo-library access.
///
/// Access is re-read every time the app becomes active, because the user can
/// change it in Settings while we are backgrounded — which is exactly what the
/// denied and limited screens ask them to go and do.
struct RootView: View {
    @State private var library = PhotoLibraryModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch library.access {
            case .undetermined:
                AccessRequestView { await library.requestAccess() }
            case .denied:
                AccessDeniedView()
            case .limited:
                LimitedAccessView()
            case .full:
                PhotoGridView(library: library)
            }
        }
        .animation(.default, value: library.access)
        .task { library.refreshAccessStatus() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            library.refreshAccessStatus()
        }
    }
}
