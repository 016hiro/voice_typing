import SwiftUI

struct CapsuleView: View {
    @ObservedObject var state: AppState
    let levels: AsyncStream<Float>?  // unused in A10; kept for API stability
    var onSizeChange: (CGSize) -> Void

    var body: some View {
        HStack(spacing: 14) {
            MorseIndicator()
                .frame(height: 12)

            Text(state.statusTextForCapsule)
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .tracking(2)
                .textCase(.uppercase)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: 520, alignment: .leading)
        }
        // Dual-halo so the indicator stays legible over any background
        // (opposing shadows ensure contrast on both dark and light surfaces).
        .shadow(color: .black.opacity(0.55), radius: 6, x: 0, y: 1)
        .shadow(color: .white.opacity(0.35), radius: 4, x: 0, y: 0)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
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
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// A10 Morse rhythm: 7 bar segments with staggered sinusoidal opacity pulse.
/// Widths mimic a morse sequence (dash/dash/dot/dot/dash/dot/dash).
private struct MorseIndicator: View {
    private static let segments: [CGFloat] = [14, 14, 4, 4, 14, 4, 14]
    private static let period: Double = 2.1
    private static let stagger: Double = 0.14
    private static let minOpacity: Double = 0.18

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(Array(Self.segments.enumerated()), id: \.offset) { idx, width in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary)
                        .frame(width: width, height: 3)
                        .opacity(opacity(at: t, index: idx))
                }
            }
        }
    }

    private func opacity(at time: Double, index: Int) -> Double {
        let shifted = time - Double(index) * Self.stagger
        var phase = shifted.truncatingRemainder(dividingBy: Self.period) / Self.period
        if phase < 0 { phase += 1 }
        // Matches CSS ease-in-out keyframes (0%,100% → min, 50% → 1.0)
        let wave = (1 - cos(phase * 2 * .pi)) / 2
        return Self.minOpacity + wave * (1 - Self.minOpacity)
    }
}
