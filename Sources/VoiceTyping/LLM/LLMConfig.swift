import Foundation

struct LLMConfig: Codable, Equatable {
    var enabled: Bool
    var baseURL: String
    var apiKey: String
    var model: String
    var timeout: TimeInterval

    static let `default` = LLMConfig(
        enabled: false,
        baseURL: "https://api.openai.com/v1",
        apiKey: "",
        model: "gpt-4o-mini",
        timeout: 8
    )

    var isUsable: Bool {
        enabled &&
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty &&
        !model.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

enum LLMConfigStore {
    private static let key = "llmConfig"

    static func load() -> LLMConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let cfg = try? JSONDecoder().decode(LLMConfig.self, from: data) else {
            return .default
        }
        return cfg
    }

    static func save(_ cfg: LLMConfig) {
        if let data = try? JSONEncoder().encode(cfg) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
