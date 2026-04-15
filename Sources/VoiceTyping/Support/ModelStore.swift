import Foundation

enum ModelStore {
    /// ~/Library/Application Support/VoiceTyping/models/
    static var modelsURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VoiceTyping", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
