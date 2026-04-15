import SwiftUI

struct CapsuleView: View {
    @ObservedObject var state: AppState
    let levels: AsyncStream<Float>?
    var onSizeChange: (CGSize) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Waveform5BarView(levels: levels)
                .frame(width: 44, height: 32)

            Text(state.labelTextForCapsule)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: 520, alignment: .leading)
                .animation(.spring(response: 0.25, dampingFraction: 0.85),
                           value: state.labelTextForCapsule)
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .frame(minWidth: 160)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: SizeKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(SizeKey.self) { size in
            onSizeChange(size)
        }
    }
}

private struct SizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
