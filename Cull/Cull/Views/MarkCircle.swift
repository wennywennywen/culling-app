import SwiftUI

/// The circle you tap to mark a photo for deletion.
///
/// The one destructive affordance in the app, and deliberately the *only* way to
/// mark: swipes navigate. Because it is the most-repeated control here, the tap
/// target is padded well beyond the visible glyph.
struct MarkCircle: View {
    let isMarked: Bool
    var size: CGFloat = 28
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // Dark scrim so the circle stays visible over a white photo.
                Circle()
                    .fill(.black.opacity(isMarked ? 0 : 0.25))

                Circle()
                    .strokeBorder(.white, lineWidth: 2)

                if isMarked {
                    Circle()
                        .fill(.red)
                        .padding(2)

                    Image(systemName: "xmark")
                        .font(.system(size: size * 0.42, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .contentShape(.circle)
            .padding(10) // enlarges the hit area without moving the glyph
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.15), value: isMarked)
        .accessibilityLabel(isMarked ? "Marked for deletion" : "Keep")
        .accessibilityHint("Marks this photo to be deleted later. Nothing is deleted until you confirm.")
    }
}

#Preview {
    HStack(spacing: 24) {
        MarkCircle(isMarked: false) {}
        MarkCircle(isMarked: true) {}
    }
    .padding()
    .background(.gray)
}
