import SwiftUI
import UIKit

/// Shared layout for the three states where there is no library to show.
private struct GateLayout<Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    /// `LocalizedStringKey`, not `String` — `Text(someString)` renders markdown
    /// as literal asterisks. Only the `LocalizedStringKey` overload parses it.
    let message: LocalizedStringKey
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: symbol)
                .font(.system(size: 52))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            actions.padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: 420)
    }
}

/// First launch.
///
/// The system dialog offers "Limited Access" as a peer of "Full Access", and it
/// is the option most people tap by reflex. Saying plainly which one to pick,
/// before the dialog appears, is what stops the next screen being the
/// limited-access explanation.
struct AccessRequestView: View {
    let onRequest: () async -> Void
    @State private var isRequesting = false

    var body: some View {
        GateLayout(
            symbol: "photo.stack",
            title: "Clean up your camera roll",
            message: """
                Shot forty photos of the same outfit? Pick a set, swipe through them, \
                and tap a circle on the ones you don't want. Cull deletes them in one go.

                When iOS asks, choose **Allow Full Access** — Cull can only tidy \
                photos it can see. Everything happens on your phone.
                """
        ) {
            Button {
                isRequesting = true
                Task {
                    await onRequest()
                    isRequesting = false
                }
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isRequesting)
        }
    }
}

/// Access refused outright, or blocked by device policy.
struct AccessDeniedView: View {
    var body: some View {
        GateLayout(
            symbol: "lock",
            title: "Photos access is off",
            message: """
                Cull can't see your photo library, so there's nothing for it to do.

                You can turn access on in Settings → Cull → Photos.
                """
        ) {
            OpenSettingsButton()
        }
    }
}

/// The state the plan singles out: never render this as an empty grid.
///
/// Limited access sounds like a milder "yes" but it inverts what this app does.
/// Cull's job is the photos you have *not* sorted yet; limited access shows it
/// only the ones you already picked out by hand.
struct LimitedAccessView: View {
    var body: some View {
        GateLayout(
            symbol: "photo.badge.exclamationmark",
            title: "Cull needs your whole library",
            message: """
                Right now Cull can only see a few photos you selected by hand.

                That's the one thing it can't work with — Cull exists to clear out \
                the shots you *haven't* sorted through, so it has to be able to see \
                them. Choosing photos yourself is the job it's meant to save you.

                Nothing leaves your phone either way.
                """
        ) {
            OpenSettingsButton(title: "Allow Full Access in Settings")
        }
    }
}

private struct OpenSettingsButton: View {
    var title: String = "Open Settings"
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            openURL(url)
        } label: {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}
