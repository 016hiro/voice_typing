import Foundation

/// v0.7.0 #R7: how refined text reaches the focused app. Two modes,
/// mutually exclusive at the type level so the UI is a simple two-segment
/// picker.
///
/// **streaming** (default) — `refineStream` yields delta chunks, injector
/// pastes at sentence/word boundaries as they arrive (ADR 0001). Best
/// perceived latency. Auto-falls back to `.batch` for `notion.id` per the
/// inject spike findings.
///
/// **batch** — wait for the full refine, then paste once. Slower UX but
/// cleanest output — also the implicit fallback for bundle IDs that don't
/// tolerate chunked Cmd+V (Notion block-splitting in particular).
///
/// Pre-v0.7.0's `rawFirst` mode (paste raw immediately, refine in
/// background, Cmd+Z + repaste refined) was dropped during v0.7.0 dogfood.
/// Streaming now provides the same time-to-first-text win without the
/// flicker, the IME-fragile Cmd+Z replace, or the dual code path. Existing
/// users who had `rawFirstEnabled=true` migrate to `.streaming` on first
/// v0.7.0 launch.
enum RefineDelivery: String, CaseIterable, Codable, Sendable, Identifiable {
    case streaming
    case batch

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .streaming: return "Streaming"
        case .batch:     return "Batch"
        }
    }

    var summary: String {
        switch self {
        case .streaming: return "Refine and paste in real time. Best UX."
        case .batch:     return "Wait for the full refine, then paste once."
        }
    }

    /// Bundle IDs where streaming is known to misbehave (block-splitting,
    /// markdown autocomplete eating chunks, etc.). Caller maps a frontmost
    /// `bundleID` through this set and downgrades `.streaming → .batch` when
    /// it hits. ADR 0001 documents the spike that picked these.
    static let streamingDenyList: Set<String> = [
        "notion.id"
    ]

    /// If `delivery` is `.streaming` and `bundleID` is in the deny-list,
    /// returns `.batch`. Otherwise returns `delivery` unchanged. Centralizes
    /// the deny-list rule so both the AppDelegate dispatch and any future
    /// "what would happen if I refined now" UI affordance share one source.
    static func resolved(_ delivery: RefineDelivery, bundleID: String?) -> RefineDelivery {
        guard delivery == .streaming, let id = bundleID, streamingDenyList.contains(id) else {
            return delivery
        }
        return .batch
    }
}
