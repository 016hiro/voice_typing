import AppKit
import Foundation

@MainActor
extension AppDelegate {

    /// Wires `outputs.samples` to a `LiveTranscriber` if live mode is on AND
    /// the VAD has been pre-warmed (see `activateBackend`). Otherwise drains
    /// the samples stream so AudioCapture's continuation doesn't backlog.
    ///
    /// `useLive` is computed in `startRecording` so the maxDuration cap on
    /// `audio.start` matches the path we'll take here. Re-checks invariants
    /// defensively in case state changed between the two call sites (rare —
    /// they execute back-to-back on the main actor).
    func startLiveTranscriberIfEnabled(samples: AsyncStream<[Float]>, useLive: Bool) {
        guard useLive,
              let qwen = recognizer as? QwenASRRecognizer,
              let vadBox = cachedVADBox else {
            Task.detached { for await _ in samples {} }
            return
        }

        // Snapshot ASR-side state at Fn↓ so a mid-recording dictionary edit
        // doesn't desync the bias context from the hit detection that runs
        // post-transcribe.
        let language = state.language
        let dictEntries = state.dictionary.entries
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let asrContext = GlossaryBuilder.buildForASR(activeBackend, entries: dictEntries, language: language)
        let profile = state.profiles.lookup(bundleID: frontmostBundleID)
        let profileSnippet = profile?.systemPromptSnippet

        liveSnapshot = LiveRunSnapshot(
            backend: activeBackend,
            language: language,
            dictEntries: dictEntries,
            asrContext: asrContext,
            frontmostBundleID: frontmostBundleID,
            profileSnippet: profileSnippet
        )

        let lt = LiveTranscriber(
            recognizer: qwen,
            vadBox: vadBox,
            tuning: .production,
            language: language,
            context: asrContext
        )
        lt.start()
        activeLiveTranscriber = lt

        // Detached ingest task so the audio thread isn't blocked. The pump
        // inside LiveTranscriber consumes from this stream.
        liveIngestTask = Task.detached {
            for await chunk in samples {
                lt.ingest(samples: chunk)
            }
        }

        if let ctx = asrContext {
            Log.dev(Log.app, "Live: started with bias context (\(ctx.count) chars)")
        } else {
            Log.dev(Log.app, "Live: started with no bias context")
        }
    }

    /// Defensive cleanup hit by the early-return paths in `stopRecording`
    /// (e.g., buffer-too-short, mic failure). Cancelling a finished
    /// LiveTranscriber is safe — the pumpTask check covers it.
    func cleanUpLiveState() {
        activeLiveTranscriber?.cancel()
        activeLiveTranscriber = nil
        liveIngestTask?.cancel()
        liveIngestTask = nil
        liveSnapshot = nil
    }
}
