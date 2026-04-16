import Foundation

enum ModelStore {
    /// `~/Library/Application Support/VoiceTyping/models/`
    static var modelsURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VoiceTyping", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Per-backend subdirectory. Created on access.
    static func directory(for backend: ASRBackend) -> URL {
        let url = modelsURL.appendingPathComponent(backend.storageDirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Best-effort "is this backend's model already fully downloaded?"
    /// For WhisperKit: look for the AudioEncoder weights binary. WhisperKit appends
    /// `models/<repo>/<model>/...` under whatever `downloadBase` we pass it.
    /// For Qwen: look for at least one .safetensors file anywhere under the backend dir.
    static func isDownloaded(_ backend: ASRBackend) -> Bool {
        let dir = directory(for: backend)
        switch backend {
        case .whisperLargeV3:
            let sentinel = dir
                .appendingPathComponent("models")          // WhisperKit's auto-prefix
                .appendingPathComponent("argmaxinc")
                .appendingPathComponent("whisperkit-coreml")
                .appendingPathComponent("openai_whisper-large-v3")
                .appendingPathComponent("AudioEncoder.mlmodelc")
                .appendingPathComponent("weights")
                .appendingPathComponent("weight.bin")
            return FileManager.default.fileExists(atPath: sentinel.path)
        case .qwenASR06B, .qwenASR17B:
            return containsSafetensors(in: dir)
        }
    }

    /// Sum of file sizes under the backend's directory, in bytes. 0 if missing.
    static func sizeOnDisk(_ backend: ASRBackend) -> Int64 {
        let dir = directory(for: backend)
        return directorySize(at: dir)
    }

    /// Delete everything under the backend's directory. Does not touch other backends.
    static func delete(_ backend: ASRBackend) throws {
        let dir = directory(for: backend)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return }
        // Remove contents rather than the dir itself, so subsequent re-download has a place to write.
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in contents {
            try fm.removeItem(at: url)
        }
    }

    /// Free space available in the Application Support volume.
    static func availableBytes() -> Int64 {
        let url = modelsURL
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let avail = values.volumeAvailableCapacityForImportantUsage {
            return avail
        }
        return .max
    }

    // MARK: - Migration

    /// v0.1.0 passed `~/Library/Application Support/VoiceTyping/models/` to WhisperKit
    /// as its downloadBase. WhisperKit then created a literal `models/` subdir inside —
    /// so the v0.1.0 weights actually live at `<modelsURL>/models/argmaxinc/...` and
    /// `<modelsURL>/models/openai/...`. We move the whole `models/` subtree into the new
    /// per-backend `whisperkit/` directory so v0.2.0's `downloadBase = .../whisperkit/`
    /// finds them under `whisperkit/models/argmaxinc/...`.
    /// No-op if the new layout is already populated or the old layout is empty.
    static func migrateV010WhisperLayoutIfNeeded() {
        let fm = FileManager.default
        let oldNested = modelsURL.appendingPathComponent("models", isDirectory: true)
        let newDir = directory(for: .whisperLargeV3)
        let newNested = newDir.appendingPathComponent("models", isDirectory: true)

        guard fm.fileExists(atPath: oldNested.path) else { return }
        guard !fm.fileExists(atPath: newNested.path) else { return }

        do {
            try fm.moveItem(at: oldNested, to: newNested)
            Log.app.info("Migrated v0.1.0 WhisperKit models into whisperkit/ subdirectory")
        } catch {
            Log.app.warning("v0.1.0 model migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helpers

    private static func containsSafetensors(in dir: URL) -> Bool {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return false
        }
        for case let url as URL in enumerator {
            if url.pathExtension == "safetensors" {
                if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                   let size = values.fileSize, size > 1_000_000 {
                    return true
                }
            }
        }
        return false
    }

    private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true, let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

extension Int64 {
    var humanReadableBytes: String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        fmt.allowedUnits = [.useMB, .useGB]
        return fmt.string(fromByteCount: self)
    }
}
