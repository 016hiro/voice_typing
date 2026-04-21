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

        // Warn-only: live mode + refine combination is intentionally unsupported
        // for v0.5.0 (Cmd+Z chain across N segment pastes is fragile, see devlog).
        // The pipelineTask's live branch will skip refine; flag it here so
        // someone debugging "why isn't my refine running" finds the answer in logs.
        if state.refineMode.systemPrompt != nil && state.llmConfig.hasCredentials {
            Log.app.info("Live: refine mode \(self.state.refineMode.rawValue, privacy: .public) skipped — live + refine not yet supported, see v0.5.0 devlog")
        }

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

        // Detached inject task: each segment yielded by LiveTranscriber.output
        // gets injected into the focused app immediately. This is the live UX
        // win — text appears as the user is still talking (after each VAD
        // segment or 25 s force-split). Returns the accumulated transcript
        // when the stream finishes; `stopRecording` awaits this for logging
        // and capsule cleanup.
        let injector = self.injector
        let appState = self.state
        liveInjectTask = Task.detached {
            var accumulated = ""
            do {
                for try await segment in lt.output {
                    // Compute the delta to inject. First segment goes in
                    // as-is; subsequent segments get a leading space so
                    // English reads naturally. (Chinese gets an extra space
                    // between segments, matching v0.4.5 batch streaming.)
                    let delta = accumulated.isEmpty ? segment : " " + segment

                    // Focus check: if the user switched apps mid-recording,
                    // skip injection but still accumulate so the final
                    // transcript log is complete.
                    let currentBundleID: String? = await MainActor.run {
                        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    }
                    if currentBundleID == frontmostBundleID {
                        await injector.inject(delta)
                    } else {
                        Log.app.info("Live: focus moved (\(frontmostBundleID ?? "nil", privacy: .public) → \(currentBundleID ?? "nil", privacy: .public)) — segment dropped from inject (\(segment.count, privacy: .public) chars)")
                    }

                    accumulated = accumulated.isEmpty ? segment : accumulated + " " + segment

                    // Per-segment dictionary hits — attribute incrementally
                    // so the LRU updates as the user is dictating, not in a
                    // single burst at end.
                    let hits = GlossaryBuilder.matchedEntryIDs(in: segment, entries: dictEntries)
                    if !hits.isEmpty {
                        await MainActor.run { appState.noteDictionaryMatches(hits) }
                    }
                }
            } catch {
                Log.app.error("Live inject task error: \(error.localizedDescription, privacy: .public)")
            }
            return accumulated
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
        liveInjectTask?.cancel()
        liveInjectTask = nil
        liveSnapshot = nil
    }
}
