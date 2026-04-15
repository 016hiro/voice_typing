import Foundation

/// Which ASR engine is powering transcription. Persisted per-user in UserDefaults.
public enum ASRBackend: String, CaseIterable, Codable, Sendable, Identifiable {
    case whisperLargeV3 = "whisper-large-v3"
    case qwenASR06B     = "qwen-asr-0.6b"
    case qwenASR17B     = "qwen-asr-1.7b"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .whisperLargeV3: return "Whisper large-v3"
        case .qwenASR06B:     return "Qwen3-ASR 0.6B"
        case .qwenASR17B:     return "Qwen3-ASR 1.7B"
        }
    }

    /// Subdirectory under `~/Library/Application Support/VoiceTyping/models/`.
    public var storageDirName: String {
        switch self {
        case .whisperLargeV3: return "whisperkit"
        case .qwenASR06B:     return "qwen-asr-0.6b"
        case .qwenASR17B:     return "qwen-asr-1.7b"
        }
    }

    /// Rough on-disk size after full download — used for UI hints.
    public var estimatedSizeLabel: String {
        switch self {
        case .whisperLargeV3: return "~3.0 GB"
        case .qwenASR06B:     return "~400 MB"
        case .qwenASR17B:     return "~1.4 GB"
        }
    }

    /// Estimated bytes for "enough space?" preflight.
    public var estimatedBytes: Int64 {
        switch self {
        case .whisperLargeV3: return 3_000_000_000
        case .qwenASR06B:     return 450_000_000
        case .qwenASR17B:     return 1_500_000_000
        }
    }

    public var isQwen: Bool {
        switch self {
        case .qwenASR06B, .qwenASR17B: return true
        default: return false
        }
    }

    /// HuggingFace model id passed to Qwen3ASRModel.fromPretrained.
    public var qwenModelId: String? {
        switch self {
        case .qwenASR06B: return "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
        case .qwenASR17B: return "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
        default:          return nil
        }
    }

    public static var `default`: ASRBackend { .qwenASR17B }
}
