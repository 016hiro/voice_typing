import Foundation

/// v0.7.0 #R7: how refined text reaches the focused app. Replaces the
/// pre-v0.7.0 `rawFirstEnabled` boolean — three modes are mutually exclusive
/// at the type level so the UI can render a single picker instead of two
/// toggles with hidden interaction rules.
///
/// **streaming** (default) — `refineStream` yields delta chunks, injector
/// pastes at sentence/word boundaries as they arrive (ADR 0001). Best
/// perceived latency. Auto-falls back to `.batch` for `notion.id` per the
/// inject spike findings.
///
/// **rawFirst** — pastes raw ASR immediately, refines in background, then
/// Cmd+Z + repaste with refined text if the focus is still in the same app.
/// Pre-v0.7.0 fast-path. Trades a visible flicker for the lowest possible
/// time-to-first-text, useful on slow networks / cold local refiner loads.
///
/// **batch** — wait for the full refine, then paste once. The slowest UX
/// but the cleanest output — also the implicit fallback when streaming
/// would misbehave (Notion block-splitting, bundle IDs we know don't tolerate
/// chunked Cmd+V well).
enum RefineDelivery: String, CaseIterable, Codable, Sendable, Identifiable {
    case streaming
    case rawFirst
    case batch

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .streaming: return "Streaming"
        case .rawFirst:  return "Raw-first"
        case .batch:     return "Batch"
        }
    }

    var summary: String {
        switch self {
        case .streaming: return "Refine and paste in real time. Best UX."
        case .rawFirst:  return "Paste raw immediately, replace with refined when ready."
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
