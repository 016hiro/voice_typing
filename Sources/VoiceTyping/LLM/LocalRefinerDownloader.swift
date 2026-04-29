import Foundation
import HuggingFace

/// Drives the v0.6.3 local refiner download from Settings UI. Uses
/// swift-huggingface's `HubClient.downloadSnapshot(of:to:)` so weights
/// land directly in `ModelStore.localRefinerDirectory` (flat layout,
/// no nested HF cache structure to translate).
///
/// Lives as `@StateObject` on `LLMTab` — single instance per Settings
/// window. Cancelling the task aborts mid-flight; partial files are
/// cleaned up at next launch via `ModelStore.repairLocalRefinerIfIncomplete`.
@MainActor
final class LocalRefinerDownloader: ObservableObject {

    enum Phase: Equatable {
        case idle
        case downloading(written: Int64, total: Int64)
        case succeeded
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private var task: Task<Void, Never>?

    /// True while a download is actively in flight (covers both
    /// `.downloading` and the brief moment before the first progress tick).
    var isActive: Bool {
        if case .downloading = phase { return true }
        return false
    }

    func start() {
        guard !isActive else { return }
        phase = .downloading(written: 0, total: 0)
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    private func run() async {
        let client = HubClient()
        guard let repoID = HuggingFace.Repo.ID(rawValue: ModelStore.localRefinerModelId) else {
            phase = .failed("Invalid repo id: \(ModelStore.localRefinerModelId)")
            return
        }
        let destination = ModelStore.localRefinerDirectory
        do {
            _ = try await client.downloadSnapshot(
                of: repoID,
                to: destination,
                progressHandler: { @MainActor [weak self] progress in
                    guard let self else { return }
                    let written = progress.completedUnitCount
                    let total = progress.totalUnitCount > 0 ? progress.totalUnitCount : 0
                    self.phase = .downloading(written: written, total: total)
                }
            )
            // Defensive: verify what we just downloaded actually passes the
            // strict completeness check. Catches truncated mid-flight aborts
            // that the snapshot API doesn't surface as errors.
            guard ModelStore.isLocalRefinerComplete() else {
                phase = .failed("Download finished but model files failed completeness check.")
                return
            }
            phase = .succeeded
            Log.llm.info("LocalRefinerDownloader: download complete at \(destination.path, privacy: .public)")
        } catch {
            if Task.isCancelled {
                phase = .idle
            } else {
                phase = .failed(error.localizedDescription)
                Log.llm.error("LocalRefinerDownloader failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
