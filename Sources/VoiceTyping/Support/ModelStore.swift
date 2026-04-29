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

    /// Stricter than `isDownloaded`: verifies the *critical* files exist and
    /// meet a size threshold. Returns true only when the model is plausibly
    /// loadable. Used at app launch to detect partial downloads from killed/
    /// crashed prior sessions — `isDownloaded` would return true on a 0-byte
    /// stub safetensors and the next `prepare()` would crash inside upstream.
    ///
    /// Thresholds are deliberately conservative (100 KB for `.bin`, 1 MB for
    /// safetensors). Real files are MB-GB; the threshold catches truly broken
    /// stubs without false-positiving when upstream switches to smaller
    /// model variants. If a partial-download case slips through (e.g. a 50 MB
    /// stub of a 1 GB file) the upcoming `prepare()` will fail loudly inside
    /// upstream — recoverable via Settings → "Re-download". The threshold is
    /// the cheap pre-flight, not a safety net.
    static func isComplete(_ backend: ASRBackend) -> Bool {
        return isComplete(backend, atDirectory: directory(for: backend))
    }

    /// Testable variant: same logic as `isComplete(_:)` but takes the backend's
    /// root URL instead of resolving via `directory(for:)`. Lets unit tests
    /// stage a fake layout under a temp directory.
    static func isComplete(_ backend: ASRBackend, atDirectory dir: URL) -> Bool {
        let fm = FileManager.default
        switch backend {
        case .whisperLargeV3:
            // Three CoreML compiled .mlmodelc bundles, each with a
            // weights/weight.bin sentinel. Mel is small (~365 KB real);
            // encoder + decoder are GB-scale.
            let base = dir
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent("argmaxinc", isDirectory: true)
                .appendingPathComponent("whisperkit-coreml", isDirectory: true)
                .appendingPathComponent("openai_whisper-large-v3", isDirectory: true)
            let critical = [
                base.appendingPathComponent("AudioEncoder.mlmodelc/weights/weight.bin"),
                base.appendingPathComponent("TextDecoder.mlmodelc/weights/weight.bin"),
                base.appendingPathComponent("MelSpectrogram.mlmodelc/weights/weight.bin")
            ]
            for url in critical {
                guard fm.fileExists(atPath: url.path),
                      let size = fileSize(at: url),
                      size >= 100_000 else {
                    return false
                }
            }
            return true
        case .qwenASR06B, .qwenASR17B:
            guard let id = backend.qwenModelId else { return false }
            // Hub-style nesting matches QwenASRRecognizer's cacheDir
            // construction (`models/<org>/<model>/`).
            let base = dir
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
            let weights = base.appendingPathComponent("model.safetensors")
            let vocab   = base.appendingPathComponent("vocab.json")
            guard fm.fileExists(atPath: weights.path),
                  let wsz = fileSize(at: weights), wsz >= 1_000_000 else { return false }
            guard fm.fileExists(atPath: vocab.path),
                  let vsz = fileSize(at: vocab), vsz >= 100_000 else { return false }
            return true
        }
    }

    /// Removes the file/subdir that failed `isComplete` so the next
    /// `prepare()` re-downloads from clean. Conservative: targets only the
    /// failing artifacts, not the entire backend dir, so a co-resident healthy
    /// second variant in the same dir is preserved (currently no such case
    /// exists in the layout, but cheap insurance).
    ///
    /// Returns true if any deletion happened. Caller can use this signal to
    /// surface a user-visible log line ("re-downloading X").
    @discardableResult
    static func repairIfIncomplete(_ backend: ASRBackend) -> Bool {
        return repairIfIncomplete(backend, atDirectory: directory(for: backend))
    }

    /// Testable variant: same logic as `repairIfIncomplete(_:)` but takes the
    /// backend's root URL.
    @discardableResult
    static func repairIfIncomplete(_ backend: ASRBackend, atDirectory dir: URL) -> Bool {
        let fm = FileManager.default
        var repaired = false
        switch backend {
        case .whisperLargeV3:
            let base = dir
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent("argmaxinc", isDirectory: true)
                .appendingPathComponent("whisperkit-coreml", isDirectory: true)
                .appendingPathComponent("openai_whisper-large-v3", isDirectory: true)
            for name in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"] {
                let mlmodelc = base.appendingPathComponent(name, isDirectory: true)
                let weight = mlmodelc.appendingPathComponent("weights/weight.bin")
                let needsRepair: Bool = {
                    if !fm.fileExists(atPath: weight.path) { return true }
                    if let sz = fileSize(at: weight), sz < 100_000 { return true }
                    return false
                }()
                guard needsRepair, fm.fileExists(atPath: mlmodelc.path) else { continue }
                do {
                    try fm.removeItem(at: mlmodelc)
                    Log.app.info("ModelStore: removed incomplete \(name, privacy: .public) for \(backend.rawValue, privacy: .public) — will re-download")
                    repaired = true
                } catch {
                    Log.app.error("ModelStore: failed to remove incomplete \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        case .qwenASR06B, .qwenASR17B:
            guard let id = backend.qwenModelId else { return false }
            let base = dir
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
            // Qwen is a single big safetensors plus tokenizer files. If
            // either weights or vocab is broken, the simplest recovery is to
            // delete the whole model variant subdir and let `fromPretrained`
            // re-download all six files. Granular per-file repair would risk
            // leaving inconsistent versions if the safetensors and config
            // came from different upstream commits.
            let weights = base.appendingPathComponent("model.safetensors")
            let vocab   = base.appendingPathComponent("vocab.json")
            let needsRepair: Bool = {
                if !fm.fileExists(atPath: weights.path) { return true }
                if !fm.fileExists(atPath: vocab.path) { return true }
                if let sz = fileSize(at: weights), sz < 1_000_000 { return true }
                if let sz = fileSize(at: vocab), sz < 100_000 { return true }
                return false
            }()
            guard needsRepair, fm.fileExists(atPath: base.path) else { return false }
            do {
                try fm.removeItem(at: base)
                Log.app.info("ModelStore: removed incomplete Qwen model dir for \(backend.rawValue, privacy: .public) — will re-download")
                repaired = true
            } catch {
                Log.app.error("ModelStore: failed to remove incomplete Qwen dir: \(error.localizedDescription, privacy: .public)")
            }
        }
        return repaired
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

    // MARK: - v0.6.3 local MLX refiner (Qwen3.5-4B-MLX-4bit)
    //
    // Direct standalone methods rather than extending `ASRBackend` enum —
    // the local refiner isn't an ASR backend and shouldn't pollute that
    // type's switch statements / Settings UI dispatch. If a second local
    // refiner ever lands (e.g. Gemma alternative) we'll introduce a parallel
    // `RefinerBackend` enum then. YAGNI for now: one model, direct paths.

    /// HuggingFace repo ID for the v0.6.3 local refiner. Single source of
    /// truth — used by `localRefinerDirectory` for the on-disk path and by
    /// `LocalMLXRefiner` (#R6) when handing the id to mlx-swift-lm.
    static let localRefinerModelId = "mlx-community/Qwen3.5-4B-MLX-4bit"

    /// `~/Library/Application Support/VoiceTyping/models/local-refiner/<modelId>/`.
    /// Created on access. Sits parallel to ASR backend dirs; the `local-refiner`
    /// segment isolates it so existing ASR `delete`/`size` code can't accidentally
    /// see it.
    static var localRefinerDirectory: URL {
        let url = modelsURL
            .appendingPathComponent("local-refiner", isDirectory: true)
            .appendingPathComponent(localRefinerModelId, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Strict "is the local refiner ready to load?" check, mirroring the
    /// `isComplete` style used for ASR backends. Verifies config + tokenizer
    /// + weights all exist and pass conservative size thresholds.
    static func isLocalRefinerComplete() -> Bool {
        return isLocalRefinerComplete(atDirectory: localRefinerDirectory)
    }

    /// Testable variant — same logic but takes the model dir directly so unit
    /// tests can stage fake layouts under a temp dir.
    static func isLocalRefinerComplete(atDirectory dir: URL) -> Bool {
        let fm = FileManager.default
        // 1. Model config — mlx-swift-lm needs this to pick the architecture
        //    (Qwen35Model vs Qwen35MoEModel etc). Tiny but mandatory.
        let config = dir.appendingPathComponent("config.json")
        guard fm.fileExists(atPath: config.path),
              let csz = fileSize(at: config), csz >= 1_000 else { return false }
        // 2. Tokenizer — `tokenizer.json` is the consolidated form
        //    swift-transformers reads. `tokenizer_config.json` carries the
        //    chat template + the `enable_thinking` Jinja branch we depend on.
        let tokenizer = dir.appendingPathComponent("tokenizer.json")
        guard fm.fileExists(atPath: tokenizer.path),
              let tsz = fileSize(at: tokenizer), tsz >= 100_000 else { return false }
        let tokenizerCfg = dir.appendingPathComponent("tokenizer_config.json")
        guard fm.fileExists(atPath: tokenizerCfg.path),
              let tcsz = fileSize(at: tokenizerCfg), tcsz >= 1_000 else { return false }
        // 3. Weights — Qwen3.5-4B-MLX-4bit ships as a single ~3 GB
        //    `model.safetensors`. Larger same-family variants ship sharded
        //    (`model-00001-of-00007.safetensors` + an index json). Handle both
        //    so the same logic works if we add a 7B/27B option later.
        let singleSafetensors = dir.appendingPathComponent("model.safetensors")
        if fm.fileExists(atPath: singleSafetensors.path),
           let sz = fileSize(at: singleSafetensors), sz >= 100_000_000 {
            return true   // single-file path — done
        }
        // Sharded path: `model.safetensors.index.json` lists each shard via
        // its `weight_map`. Verify every referenced shard exists with size.
        let indexFile = dir.appendingPathComponent("model.safetensors.index.json")
        guard fm.fileExists(atPath: indexFile.path),
              let indexData = try? Data(contentsOf: indexFile),
              let json = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any],
              let weightMap = json["weight_map"] as? [String: String] else {
            return false
        }
        let shardNames = Set(weightMap.values)
        guard !shardNames.isEmpty else { return false }
        for shardName in shardNames {
            let shard = dir.appendingPathComponent(shardName)
            guard fm.fileExists(atPath: shard.path),
                  let ssz = fileSize(at: shard), ssz >= 1_000_000 else { return false }
        }
        return true
    }

    /// Removes the local refiner dir if it's incomplete. Settings UI calls
    /// this before showing the toggle as "ready" so a partial download from
    /// a killed prior session doesn't trip mlx-swift-lm's loader.
    @discardableResult
    static func repairLocalRefinerIfIncomplete() -> Bool {
        return repairLocalRefinerIfIncomplete(atDirectory: localRefinerDirectory)
    }

    @discardableResult
    static func repairLocalRefinerIfIncomplete(atDirectory dir: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return false }
        guard !isLocalRefinerComplete(atDirectory: dir) else { return false }
        do {
            try fm.removeItem(at: dir)
            Log.app.info("ModelStore: removed incomplete local refiner — will re-download")
            return true
        } catch {
            Log.app.error("ModelStore: failed to remove incomplete local refiner: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Sum of file sizes under the local refiner dir. 0 if nothing downloaded.
    static var localRefinerSizeOnDisk: Int64 {
        return directorySize(at: localRefinerDirectory)
    }

    /// Delete all local refiner weights — used by Settings → Remove model.
    /// Mirrors `delete(_:)` for ASR backends: removes contents, leaves the
    /// dir intact so re-download has a place to write.
    static func deleteLocalRefiner() throws {
        let dir = localRefinerDirectory
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return }
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in contents {
            try fm.removeItem(at: url)
        }
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
        for case let url as URL in enumerator where url.pathExtension == "safetensors" {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize, size > 1_000_000 {
                return true
            }
        }
        return false
    }

    private static func fileSize(at url: URL) -> Int64? {
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let s = v.fileSize else { return nil }
        return Int64(s)
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
