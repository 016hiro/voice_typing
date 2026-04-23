import SwiftUI

struct CapsuleView: View {
    @ObservedObject var state: AppState
    let levels: AsyncStream<Float>?  // unused in A10; kept for API stability
    var onSizeChange: (CGSize) -> Void

    var body: some View {
        HStack(spacing: 14) {
            // v0.5.3: morse tint shifts to warm-orange in hands-free so the
            // user can tell at a glance which mode they're in (no Fn pressed
            // = could be confusing without a visual cue).
            MorseIndicator(tint: state.handsFreeActive ? .orange : .primary)
                .frame(height: 12)

            // v0.5.3 HF badge — small pill rendered only during hands-free.
            // Lives between the morse and the status text so the layout
            // shifts predictably (status text just slides right).
            if state.handsFreeActive {
                HandsFreeBadge()
            }

            Text(state.capsuleOverlayText ?? state.statusTextForCapsule)
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .tracking(2)
                .textCase(.uppercase)
                // v0.5.3: status text follows the morse tint in hands-free
                // so the overall capsule reads as one warm-orange block
                // rather than mixed orange + white.
                .foregroundStyle(state.handsFreeActive ? AnyShapeStyle(Color.orange) : AnyShapeStyle(HierarchicalShapeStyle.primary))
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

    var tint: Color = .primary

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(Array(Self.segments.enumerated()), id: \.offset) { idx, width in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tint)
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

/// v0.5.3 hands-free state pill. Small, low-chrome — the morse tint shift
/// already screams "different mode"; this just labels it. Orange to match
/// the morse tint and reinforce the visual signal.
private struct HandsFreeBadge: View {
    var body: some View {
        Text("HF")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.orange)
            )
    }
}
