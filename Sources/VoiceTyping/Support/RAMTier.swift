import Darwin
import Foundation

/// Mac RAM tier — drives v0.6.3 Settings UI gating for the local refiner.
///
/// Tier boundaries:
/// - `.low`  (< 16 GB):   local refiner not exposed (would cause severe swap)
/// - `.mid`  (16–23 GB):  local refiner opt-in with ⚠ "may swap" warning
/// - `.high` (≥ 24 GB):   local refiner opt-in, no warning (default OFF still)
///
/// Read once at first access via `sysctl hw.memsize`. Not persisted to
/// `UserDefaults` — fresh detect each launch avoids stale values when a user
/// migrates their config to a different Mac (Migration Assistant / dotfile
/// sync). On the rare sysctl failure we fall back to `.low` so we don't
/// expose RAM-hungry features we can't confirm have headroom for.
enum RAMTier: Sendable, Equatable {
    case low
    case mid
    case high

    static let current: RAMTier = {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        let result = sysctlbyname("hw.memsize", &size, &len, nil, 0)
        guard result == 0, size > 0 else { return .low }
        return forBytes(size)
    }()

    /// Pure tier mapping — exposed for unit tests so we can verify the
    /// boundaries without faking sysctl. Boundaries are inclusive on the
    /// low side (16 GB → `.mid`, 24 GB → `.high`).
    static func forBytes(_ bytes: UInt64) -> RAMTier {
        let gib = bytes / (1024 * 1024 * 1024)
        switch gib {
        case 0..<16:  return .low
        case 16..<24: return .mid
        default:      return .high
        }
    }
}
