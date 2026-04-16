import Foundation

public enum Language: String, CaseIterable, Codable, Sendable, Identifiable {
    case en = "en"
    case zhCN = "zh-CN"
    case zhTW = "zh-TW"
    case ja = "ja"
    case ko = "ko"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .en:   return "English"
        case .zhCN: return "简体中文"
        case .zhTW: return "繁體中文"
        case .ja:   return "日本語"
        case .ko:   return "한국어"
        }
    }

    /// Language code Whisper expects (ISO-639-1-ish).
    public var whisperCode: String {
        switch self {
        case .en:   return "en"
        case .zhCN: return "zh"
        case .zhTW: return "zh"
        case .ja:   return "ja"
        case .ko:   return "ko"
        }
    }

    /// Language name Qwen3-ASR expects — full English word, lowercase.
    public var qwenName: String {
        switch self {
        case .en:   return "english"
        case .zhCN: return "chinese"
        case .zhTW: return "chinese"
        case .ja:   return "japanese"
        case .ko:   return "korean"
        }
    }

    public static var `default`: Language { .zhCN }

    /// True for zh-CN / zh-TW. Drives the Qwen ASR bias context to the
    /// `热词：X、Y。` form seen in Alibaba's Chinese docs; other languages fall
    /// back to the bare comma-separated list style used in the official CLI example.
    var isChinese: Bool {
        switch self {
        case .zhCN, .zhTW: return true
        case .en, .ja, .ko: return false
        }
    }
}
