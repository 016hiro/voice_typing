import AppKit
import Foundation

/// v0.7.0 #R9 redo: outcome of the live-mode inject task. Two paths share
/// this struct:
///
/// - **Cloud / no-refine**: per segment we do a single raw `injector.inject`,
///   then at session end (`pipelineTask`) batch-refine the transcript and
///   `Cmd+Z × segmentCount + paste` to replace. `refinedInline=false`,
///   `segmentCount` ≥ 0.
/// - **Local per-segment**: per segment we run a streaming refine through
///   `LocalLiveSegmentSession` straight into `injector.injectIncremental`,
///   so refined text is on screen immediately. No session-end replace.
///   `refinedInline=true`, `segmentCount=0` (no raw paste to undo).
///
/// `segmentCount` only counts segments that actually pasted — focus-loss
/// drops a segment from inject AND from the count, so a session-end
/// Cmd+Z × N matches reality.
struct LiveInjectResult: Sendable {
    let transcript: String
    let segmentCount: Int
    let refinedInline: Bool
}

@MainActor
extension AppDelegate {

    /// Wires `outputs.samples` to a `LiveTranscriber` if live mode is on AND
    /// the VAD has been pre-warmed (see `activateBackend`). Otherwise drains
    /// the samples stream so AudioCapture's continuation doesn't backlog —
    /// unless `drainIfNotLive` is false, in which case the caller is
    /// responsible for consuming `samples` (used by the v0.5.3 hands-free
    /// watchdog path so two consumers don't race for the same stream).
    ///
    /// `useLive` is computed in `startRecording` so the maxDuration cap on
    /// `audio.start` matches the path we'll take here. Re-checks invariants
    /// defensively in case state changed between the two call sites (rare —
    /// they execute back-to-back on the main actor).
    ///
    /// `vadObserver` (v0.5.3) is plumbed into the LiveTranscriber so the
    /// hands-free state machine can react to silence events the moment VAD
    /// fires them.
    func startLiveTranscriberIfEnabled(samples: AsyncStream<[Float]>,
                                        useLive: Bool,
                                        vadObserver: LiveTranscriber.VADObserver? = nil,
                                        drainIfNotLive: Bool = true) {
        guard useLive,
              let qwen = recognizer as? QwenASRRecognizer,
              let vadBox = cachedVADBox else {
            if drainIfNotLive {
                Task.detached { for await _ in samples {} }
            }
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

        // v0.7.0 #R9 redo: live + refine bifurcates by backend.
        // - Cloud: per-segment raw inject; session-end batch refine + Cmd+Z×N
        //   replace (R9 v1 path). Cheap on API calls; clean Cmd+Z UX; user
        //   waits ~1-3s after Fn↑ for refined to land.
        // - Local: per-segment streaming refine with chat-history-carried
        //   context (`LocalLiveSegmentSession`); refined text appears
        //   progressively as user speaks. Free locally; messier Cmd+Z (each
        //   chunk is its own undo step) but acceptable since live users
        //   rarely undo whole sessions.
        // `RefineDelivery` setting (streaming/rawFirst/batch) is ignored in
        // live mode — the path is determined by `state.localRefinerEnabled`.
        // ADR 0001 documents the choice.
        let refineMode = state.refineMode
        // v0.7.0 #R9 redo bug-fix: gate via `state.refinerReady` not raw
        // `llmConfig.hasCredentials` — local-only users have blank cloud
        // creds by design, and the old gate silently bypassed refine for
        // them. `refinerReady` routes through the active backend.
        let willRefine = (refineMode.systemPrompt != nil) && state.refinerReady
        let useLocalPerSegment = willRefine
            && state.localRefinerEnabled
            && ModelStore.isLocalRefinerComplete(atDirectory: ModelStore.localRefinerDirectory)
        let segmentGlossary = GlossaryBuilder.buildLLMGlossary(from: dictEntries)
        let localLiveSession: LocalLiveSegmentSession? = useLocalPerSegment
            ? localRefinerInstance.makeLiveSegmentSession(
                mode: refineMode,
                glossary: segmentGlossary,
                profileSnippet: profileSnippet)
            : nil
        if useLocalPerSegment {
            Log.app.info("Live: local per-segment streaming refine session opened")
        } else if willRefine {
            Log.app.info("Live: cloud session-end batch refine path (refine deferred to Fn↑)")
        }

        // v0.5.1 Debug Capture: pipe both kept and HallucinationFilter-dropped
        // segments into the writer so the offline analyses (#6 in
        // todo/v0.5.1.md) have the filter ± data they need. Observer is
        // captured weakly via the writer reference; nil writer (toggle off)
        // means we don't pass an observer at all.
        let captureWriter = self.currentDebugWriter
        var segmentObserver: LiveTranscriber.SegmentObserver?
        if let writer = captureWriter {
            segmentObserver = { (event: LiveTranscriber.SegmentEvent) in
                writer.appendSegment(DebugCaptureWriter.SegmentRecord(
                    timestamp: Date(),
                    startSec: event.startSec,
                    endSec: event.endSec,
                    rawText: event.rawText,
                    filter: event.kept ? .kept : .hallucinationFiltered,
                    transcribeMs: event.transcribeMs
                ))
            }
        }

        let lt = LiveTranscriber(
            recognizer: qwen,
            vadBox: vadBox,
            tuning: .production,
            language: language,
            context: asrContext,
            segmentObserver: segmentObserver,
            vadObserver: vadObserver
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
        let injectWriter = captureWriter   // local capture so the closure is Sendable
        liveInjectTask = Task.detached { [localLiveSession] in
            var accumulated = ""
            var segmentCount = 0
            let usingLocalLive = (localLiveSession != nil)
            do {
                for try await segment in lt.output {
                    // First segment goes in as-is; subsequent segments get a
                    // leading space so English reads naturally. Chinese also
                    // gets the space, matching v0.4.5 batch-streaming output.
                    let separator = accumulated.isEmpty ? "" : " "
                    let delta = separator + segment

                    // Focus check — same gate for both paths. If the user
                    // switched apps mid-recording, drop this segment entirely
                    // (no inject, no refine, no segmentCount bump).
                    let currentBundleID: String? = await MainActor.run {
                        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    }
                    let injStart = Date()
                    let status: DebugCaptureWriter.InjectStatus
                    if currentBundleID == frontmostBundleID {
                        if let liveSession = localLiveSession {
                            // Local per-segment streaming refine. We build a
                            // wrapper stream that yields the separator first
                            // (so the model only sees the raw segment, not a
                            // leading space its history wouldn't match), then
                            // forwards refined chunks. injectIncremental
                            // pastes at flush boundaries (#R5).
                            let stream = AsyncThrowingStream<String, Error> { continuation in
                                let task = Task {
                                    if !separator.isEmpty {
                                        continuation.yield(separator)
                                    }
                                    do {
                                        for try await chunk in liveSession.refineSegmentStream(segment) {
                                            continuation.yield(chunk)
                                        }
                                        continuation.finish()
                                    } catch {
                                        continuation.finish(throwing: error)
                                    }
                                }
                                continuation.onTermination = { _ in task.cancel() }
                            }
                            _ = await injector.injectIncremental(stream: stream)
                            // Don't bump segmentCount — there's no raw paste
                            // to undo at session end on this path.
                        } else {
                            await injector.inject(delta)
                            segmentCount += 1
                        }
                        status = .ok
                    } else {
                        Log.app.info("Live: focus moved (\(frontmostBundleID ?? "nil", privacy: .public) → \(currentBundleID ?? "nil", privacy: .public)) — segment dropped from inject (\(segment.count, privacy: .public) chars)")
                        status = .focusChanged
                    }
                    let injMs = Int(Date().timeIntervalSince(injStart) * 1000)
                    injectWriter?.appendInjection(.init(
                        timestamp: Date(),
                        chars: delta.count,
                        textPreview: String(delta.prefix(120)),
                        targetBundleID: frontmostBundleID,
                        actualBundleID: currentBundleID,
                        status: status,
                        elapsedMs: injMs
                    ))

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
            // Release the live ChatSession + KV cache. Idempotent; safe even
            // when localLiveSession is nil (just a no-op via optional chain).
            await localLiveSession?.end()
            return LiveInjectResult(
                transcript: accumulated,
                segmentCount: segmentCount,
                refinedInline: usingLocalLive
            )
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
