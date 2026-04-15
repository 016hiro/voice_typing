import SwiftUI

struct Waveform5BarView: View {
    let levels: AsyncStream<Float>?

    private static let barWeights: [CGFloat] = [0.5, 0.8, 1.0, 0.75, 0.55]
    private static let barCount = 5
    private static let barWidth: CGFloat = 6
    private static let barSpacing: CGFloat = 3
    private static let maxBarHeight: CGFloat = 32
    private static let minBarHeight: CGFloat = 4
    private static let baseline: CGFloat = 0.08

    @State private var barLevels: [CGFloat] = Array(repeating: baseline, count: barCount)

    var body: some View {
        HStack(alignment: .center, spacing: Self.barSpacing) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.primary.opacity(0.82))
                    .frame(width: Self.barWidth,
                           height: max(Self.minBarHeight, barLevels[i] * Self.maxBarHeight))
                    .animation(.linear(duration: 0.033), value: barLevels[i])
            }
        }
        .frame(width: Self.barWidth * CGFloat(Self.barCount) + Self.barSpacing * CGFloat(Self.barCount - 1),
               height: Self.maxBarHeight,
               alignment: .center)
        .task {
            await subscribe()
        }
    }

    // MARK: - Subscription + envelope

    @MainActor
    private func subscribe() async {
        guard let stream = levels else {
            await idleLoop()
            return
        }
        barLevels = Array(repeating: Self.baseline, count: Self.barCount)

        for await level in stream {
            if Task.isCancelled { break }
            applyLevel(level)
        }

        // Stream ended — decay back to baseline gracefully
        for _ in 0..<12 {
            if Task.isCancelled { break }
            applyLevel(0)
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
    }

    @MainActor
    private func idleLoop() async {
        while !Task.isCancelled {
            applyLevel(0)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    @MainActor
    private func applyLevel(_ level: Float) {
        let value = CGFloat(max(0, min(1, level)))
        for i in 0..<Self.barCount {
            let jitter = CGFloat.random(in: -0.04...0.04)
            let target = max(Self.baseline, value * Self.barWeights[i] * (1 + jitter))
            let current = barLevels[i]
            if target > current {
                barLevels[i] = current * 0.6 + target * 0.4      // attack 40%
            } else {
                barLevels[i] = current * 0.85 + target * 0.15    // release 15%
            }
        }
    }
}
