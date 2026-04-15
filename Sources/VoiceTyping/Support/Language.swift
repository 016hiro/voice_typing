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

    public static var `default`: Language { .zhCN }
}
