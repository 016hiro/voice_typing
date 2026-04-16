import Foundation
import Combine
import SwiftUI

@MainActor
final class AppState: ObservableObject {

    enum CapsuleStatus: Equatable {
        case idle
        case recording
        case transcribing
        case refining
        case info(String)
    }

    @Published var status: CapsuleStatus = .idle
    @Published var capsuleText: String = ""
    @Published var capsuleVisible: Bool = false

    @Published var language: Language {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "language") }
    }

    @Published var llmConfig: LLMConfig {
        didSet { LLMConfigStore.save(llmConfig) }
    }

    @Published var asrBackend: ASRBackend {
        didSet { UserDefaults.standard.set(asrBackend.rawValue, forKey: "asrBackend") }
    }

    @Published var recognizerState: RecognizerState = .unloaded
    @Published var accessibilityGranted: Bool = false
    @Published var microphoneGranted: Bool = false

    /// Bumped when model listings (downloaded/deleted/downloading) change, so menus can refresh.
    @Published var modelInventoryTick: Int = 0

    init() {
        let raw = UserDefaults.standard.string(forKey: "language") ?? Language.default.rawValue
        self.language = Language(rawValue: raw) ?? .default
        self.llmConfig = LLMConfigStore.load()

        let backendRaw = UserDefaults.standard.string(forKey: "asrBackend")
        let persisted = backendRaw.flatMap { ASRBackend(rawValue: $0) } ?? .default
        // Don't autoload a Qwen backend if MLX isn't bundled; downgrade to default
        // (which is itself MLX-aware). User can still manually pick Qwen from the menu;
        // they'll then see the "MLX shaders missing" error in Manage Models.
        if persisted.isQwen && !MLXSupport.isAvailable {
            self.asrBackend = .default
        } else {
            self.asrBackend = persisted
        }
    }

    var labelTextForCapsule: String {
        switch status {
        case .idle, .recording:
            return capsuleText.isEmpty ? placeholderForLanguage() : capsuleText
        case .transcribing:
            return capsuleText.isEmpty ? transcribingLabel() : capsuleText
        case .refining:
            return "Refining…"
        case .info(let msg):
            return msg
        }
    }

    private func placeholderForLanguage() -> String {
        switch language {
        case .en:   return "Listening…"
        case .zhCN: return "聆听中…"
        case .zhTW: return "聆聽中…"
        case .ja:   return "聞き取り中…"
        case .ko:   return "듣고 있습니다…"
        }
    }

    private func transcribingLabel() -> String {
        switch language {
        case .en:   return "Transcribing…"
        case .zhCN: return "转写中…"
        case .zhTW: return "轉寫中…"
        case .ja:   return "変換中…"
        case .ko:   return "변환 중…"
        }
    }
}
