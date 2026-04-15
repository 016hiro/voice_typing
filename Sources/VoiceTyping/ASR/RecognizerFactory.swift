import Foundation

enum RecognizerFactory {
    static func make(_ backend: ASRBackend) -> SpeechRecognizer {
        let dir = ModelStore.directory(for: backend)
        switch backend {
        case .whisperLargeV3:
            return WhisperKitRecognizer(downloadBase: dir)
        case .qwenASR06B, .qwenASR17B:
            return QwenASRRecognizer(backend: backend, cacheDir: dir)
        }
    }
}
