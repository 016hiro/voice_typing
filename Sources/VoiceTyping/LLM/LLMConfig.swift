import Foundation

struct LLMConfig: Codable, Equatable {
    /// Legacy v0.1/v0.2 flag; superseded by `AppState.refineMode` in v0.3.
    /// Kept on disk for migration only — newly-saved configs always leave it `true`.
    var enabled: Bool
    var baseURL: String
    var apiKey: String
    var model: String
    var timeout: TimeInterval

    static let `default` = LLMConfig(
        enabled: true,
        baseURL: "https://api.openai.com/v1",
        apiKey: "",
        model: "gpt-4o-mini",
        timeout: 8
    )

    /// True when base URL, API key, and model are all populated — i.e. the config
    /// *could* actually hit an endpoint. Independent of whether refinement is on.
    var hasCredentials: Bool {
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
