import XCTest
@testable import VoiceTyping

/// Covers the v0.5.1 incomplete-model detection: `isComplete` + `repairIfIncomplete`.
/// Tests stage a fake on-disk layout under a temp directory and call the
/// `atDirectory:` overloads so they don't touch the user's real Application
/// Support cache.
final class ModelStoreTests: XCTestCase {

    private var tempBase: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceTypingTests-ModelStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let url = tempBase, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        try super.tearDownWithError()
    }

    // MARK: - Whisper

    func testIsComplete_Whisper_MissingDirectory_ReturnsFalse() throws {
        XCTAssertFalse(ModelStore.isComplete(.whisperLargeV3, atDirectory: tempBase))
    }

    func testIsComplete_Whisper_TruncatedWeights_ReturnsFalse() throws {
        try seedWhisper(audioBytes: 50, textBytes: 2_000_000, melBytes: 200_000)
        // AudioEncoder weight under 100 KB threshold → incomplete.
        XCTAssertFalse(ModelStore.isComplete(.whisperLargeV3, atDirectory: tempBase))
    }

    func testIsComplete_Whisper_AllAboveThreshold_ReturnsTrue() throws {
        try seedWhisper(audioBytes: 200_000, textBytes: 200_000, melBytes: 150_000)
        XCTAssertTrue(ModelStore.isComplete(.whisperLargeV3, atDirectory: tempBase))
    }

    func testRepair_Whisper_RemovesIncompleteSubdir() throws {
        try seedWhisper(audioBytes: 50, textBytes: 2_000_000, melBytes: 200_000)
        let audioDir = whisperBase.appendingPathComponent("AudioEncoder.mlmodelc", isDirectory: true)
        let textDir  = whisperBase.appendingPathComponent("TextDecoder.mlmodelc",  isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: textDir.path))

        let repaired = ModelStore.repairIfIncomplete(.whisperLargeV3, atDirectory: tempBase)

        XCTAssertTrue(repaired, "repair should report work done")
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioDir.path),
                       "incomplete AudioEncoder.mlmodelc should be deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: textDir.path),
                      "healthy TextDecoder.mlmodelc should be left alone")
    }

    func testRepair_Whisper_NoOp_WhenComplete() throws {
        try seedWhisper(audioBytes: 200_000, textBytes: 200_000, melBytes: 150_000)
        let repaired = ModelStore.repairIfIncomplete(.whisperLargeV3, atDirectory: tempBase)
        XCTAssertFalse(repaired)
        // Files still present
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: whisperBase.appendingPathComponent("AudioEncoder.mlmodelc/weights/weight.bin").path))
    }

    // MARK: - Qwen

    func testIsComplete_Qwen_MissingFiles_ReturnsFalse() throws {
        XCTAssertFalse(ModelStore.isComplete(.qwenASR17B, atDirectory: tempBase))
    }

    func testIsComplete_Qwen_TruncatedWeights_ReturnsFalse() throws {
        try seedQwen(.qwenASR17B, weightsBytes: 100, vocabBytes: 200_000)
        XCTAssertFalse(ModelStore.isComplete(.qwenASR17B, atDirectory: tempBase))
    }

    func testIsComplete_Qwen_MissingVocab_ReturnsFalse() throws {
        try seedQwen(.qwenASR17B, weightsBytes: 2_000_000, vocabBytes: nil)
        XCTAssertFalse(ModelStore.isComplete(.qwenASR17B, atDirectory: tempBase))
    }

    func testIsComplete_Qwen_AllAboveThreshold_ReturnsTrue() throws {
        try seedQwen(.qwenASR17B, weightsBytes: 2_000_000, vocabBytes: 200_000)
        XCTAssertTrue(ModelStore.isComplete(.qwenASR17B, atDirectory: tempBase))
    }

    func testRepair_Qwen_RemovesIncompleteVariantDir() throws {
        try seedQwen(.qwenASR17B, weightsBytes: 100, vocabBytes: 200_000)
        let variantDir = qwenBase(.qwenASR17B)
        XCTAssertTrue(FileManager.default.fileExists(atPath: variantDir.path))

        let repaired = ModelStore.repairIfIncomplete(.qwenASR17B, atDirectory: tempBase)

        XCTAssertTrue(repaired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: variantDir.path),
                       "incomplete Qwen variant subdir should be deleted")
    }

    func testRepair_Qwen_NoOp_WhenComplete() throws {
        try seedQwen(.qwenASR17B, weightsBytes: 2_000_000, vocabBytes: 200_000)
        let repaired = ModelStore.repairIfIncomplete(.qwenASR17B, atDirectory: tempBase)
        XCTAssertFalse(repaired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: qwenBase(.qwenASR17B).path))
    }

    // MARK: - Helpers

    private var whisperBase: URL {
        tempBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent("openai_whisper-large-v3", isDirectory: true)
    }

    private func qwenBase(_ backend: ASRBackend) -> URL {
        tempBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(backend.qwenModelId!, isDirectory: true)
    }

    private func seedWhisper(audioBytes: Int, textBytes: Int, melBytes: Int) throws {
        try writeStub(at: whisperBase.appendingPathComponent("AudioEncoder.mlmodelc/weights/weight.bin"), bytes: audioBytes)
        try writeStub(at: whisperBase.appendingPathComponent("TextDecoder.mlmodelc/weights/weight.bin"), bytes: textBytes)
        try writeStub(at: whisperBase.appendingPathComponent("MelSpectrogram.mlmodelc/weights/weight.bin"), bytes: melBytes)
    }

    /// Stages a Qwen variant layout. Pass `vocabBytes: nil` to simulate a
    /// missing vocab.json (e.g. download killed before tokenizer files).
    private func seedQwen(_ backend: ASRBackend, weightsBytes: Int, vocabBytes: Int?) throws {
        let base = qwenBase(backend)
        try writeStub(at: base.appendingPathComponent("model.safetensors"), bytes: weightsBytes)
        if let vb = vocabBytes {
            try writeStub(at: base.appendingPathComponent("vocab.json"), bytes: vb)
        }
    }

    private func writeStub(at url: URL, bytes: Int) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(repeating: 0, count: bytes)
        try data.write(to: url)
    }
}
