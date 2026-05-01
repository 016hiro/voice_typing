import AppKit
import Combine
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let state = AppState()
    let audio = AudioCapture()
    let injector = TextInjector()
    let fnMonitor = FnHotkeyMonitor()
    /// v0.6.4: anti-compressor keep-alive for Qwen MLX weights. Started when
    /// the recognizer reaches `.ready`, stopped on swap / non-ready / quit.
    let asrKeepAlive = ASRKeepAlive()

    /// On-device MLX refiner — held as a singleton so the actor's lazy load +
    /// loaded weights survive across refine calls. Created lazily so users who
    /// never enable it don't pay any allocation cost.
    private lazy var localRefinerInstance: LocalMLXRefiner = {
        LocalMLXRefiner(modelDirectory: ModelStore.localRefinerDirectory)
    }()

    /// Routes to either the singleton local refiner or a fresh CloudLLMRefiner
    /// snapshot per call. Cloud is cheap to recreate (no weights, ephemeral
    /// URLSession), so reading `state.llmConfig` per access keeps Settings
    /// edits live without any pub/sub plumbing. Local stays warm.
    var refiner: any LLMRefining {
        if state.localRefinerEnabled {
            return localRefinerInstance
        }
        return CloudLLMRefiner(config: state.llmConfig)
    }

    // v0.6.0: Sparkle 2 auto-update. `startingUpdater: true` triggers the
    // first background check shortly after launch and then runs Sparkle's
    // built-in 24h scheduler. The controller exposes `checkForUpdates(_:)`
    // as the Cocoa target/action for the menu's "Check for Updates…" item.
    // Configuration (feed URL, EdDSA pubkey, automatic checks) lives in
    // Info.plist (SUFeedURL / SUPublicEDKey / SUEnableAutomaticChecks).
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    // Internal (not private) so AppDelegate+Live.swift can read them when
    // setting up the live transcriber at Fn↓.
    var recognizer: SpeechRecognizer!
    var activeBackend: ASRBackend = .default

    lazy var statusController: StatusItemController = {
        let c = StatusItemController(state: state, updaterController: updaterController)
        c.onLanguageSelected = { [weak self] lang in
            self?.state.language = lang
        }
        c.onRefineModeSelected = { [weak self] mode in
            self?.state.refineMode = mode
        }
        c.onASRBackendSelected = { [weak self] backend in
            self?.switchBackend(to: backend)
        }
        c.onGrantAccessibility = {
            Permissions.openAccessibilitySettings()
        }
        c.onGrantMicrophone = {
            Permissions.openMicrophoneSettings()
        }
        c.onQuit = {
            NSApplication.shared.terminate(nil)
        }
        return c
    }()

    lazy var capsuleWindow: CapsuleWindow = CapsuleWindow(state: state)

    private var hotkeyConsumeTask: Task<Void, Never>?
    private var recognizerStateTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    private var permissionTimer: Timer?
    private var infoResetTask: Task<Void, Never>?
    private var backendSwapTask: Task<Void, Never>?
    private var appActivationObserver: NSObjectProtocol?
    /// v0.5.1: drives the "Xs left" capsule overlay near the recording cap.
    /// Started in `startRecording`, cancelled in `stopRecording` (and any
    /// stopRecording early-return path so a stale countdown can't bleed into
    /// the next session).
    private var recordingDurationTask: Task<Void, Never>?

    // MARK: - Live transcriber state (v0.5.0)
    //
    // Mutated only on the main actor. Lifetime: set at Fn↓ in
    // `startLiveTranscriberIfEnabled`, moved into a local in `stopRecording`'s
    // pipelineTask, then cleared. `cachedVADBox` survives across runs so live
    // setup at Fn↓ is synchronous (no awaits → no race with rapid Fn↑).

    var activeLiveTranscriber: LiveTranscriber?
    var liveIngestTask: Task<Void, Never>?
    /// Consumes per-segment yields from `LiveTranscriber.output` and injects
    /// each segment into the focused app the moment it arrives. Returns the
    /// full accumulated transcript when the stream finishes — `stopRecording`
    /// awaits this for latency logging.
    var liveInjectTask: Task<String, Never>?
    var liveSnapshot: LiveRunSnapshot?
    var cachedVADBox: SharedVADBox?

    /// v0.5.1 Debug Capture session writer. Non-nil only while a recording
    /// session is in flight AND `state.debugCaptureEnabled` is on. Set in
    /// `startRecording`, ownership transferred to the pipelineTask in
    /// `stopRecording` which finalizes (writes audio.wav + meta.json) after
    /// transcribe + inject complete.
    var currentDebugWriter: DebugCaptureWriter?

    // MARK: - Hands-free state (v0.5.3)
    //
    // Mutated only on the main actor. See `AppDelegate+HandsFree.swift` for
    // the state machine. Properties live here because Swift extensions can't
    // hold stored properties.

    /// Timestamp of the most recent Fn↓. Compared against now at Fn↑ to
    /// branch tap-vs-hold (threshold = `HandsFree.tapThreshold`).
    var fnPressTime: Date?

    /// True between hands-free entry (Fn↑ < tapThreshold) and stopRecording.
    /// Gates the VAD-event handler — events that fire before this is true
    /// are no-ops.
    var handsFreeActive: Bool = false

    /// True after the first VAD speech event observed in the current
    /// hands-free session. Used to cancel the no-speech timer.
    var handsFreeSpeechObserved: Bool = false

    /// Non-live timing modes need a VAD-only pump to source the speech
    /// events. nil for live-mode hands-free (the LiveTranscriber's own
    /// vadObserver covers it).
    var handsFreeWatchdog: VADWatchdog?

    /// Drains samples into `handsFreeWatchdog` in non-live mode. Replaces
    /// the plain "drain to /dev/null" task in that path.
    var handsFreeWatchdogIngestTask: Task<Void, Never>?

    /// Fires after `HandsFree.noSpeechTimeout` if no VAD event arrives —
    /// hands-free auto-cancel for accidental taps.
    var handsFreeNoSpeechTask: Task<Void, Never>?

    /// Armed after each `.speechEnded`; fires after
    /// `HandsFree.postSpeechSilence` to trigger normal stopRecording.
    /// Cancelled on subsequent `.speechStarted`.
    var handsFreeSilenceTask: Task<Void, Never>?

    /// ASR-side state captured at Fn↓ when live mode is on. Refine/inject
    /// snapshots still happen at Fn↑ (latest user choice). Held early so the
    /// live transcribe and the dictionary-hit detection use a consistent
    /// dictEntries snapshot even if the user edits the dictionary mid-recording.
    struct LiveRunSnapshot {
        let backend: ASRBackend
        let language: Language
        let dictEntries: [DictionaryEntry]
        let asrContext: String?
        let frontmostBundleID: String?
        let profileSnippet: String?
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set HF_ENDPOINT before any HubApi (WhisperKit / speech-swift) is
        // constructed. swift-transformers' HubApi reads this env var at init
        // time, so all downstream model downloads route through whichever
        // endpoint we pick here.
        HFEndpointResolver.applyCachedOrDefault()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ModelStore.migrateV010WhisperLayoutIfNeeded()

        // Background bandwidth probe → re-setenv with the winner and persist
        // to cache for next launch. Detached so it doesn't block any of the
        // app-init steps below; the prepare() path awaits this via
        // `awaitResolutionIfPending(...)` before actually pulling models.
        Task.detached(priority: .utility) {
            _ = await HFEndpointResolver.resolveAndApply()
        }

        // v0.5.1 Debug Capture maintenance: purge by age + size at launch.
        // Cheap (file-system stats only) so doing it inline before the rest of
        // app setup keeps the on-disk footprint bounded across runs even if
        // the user opted into long retention then forgot to come back.
        let purgedByAge = DebugCapture.purgeOlderThan(days: state.debugCaptureRetentionDays)
        let purgedByCap = DebugCapture.purgeIfOverCap()
        if purgedByAge + purgedByCap > 0 {
            Log.app.info("DebugCapture launch purge: \(purgedByAge, privacy: .public) by-age, \(purgedByCap, privacy: .public) by-cap")
        }

        _ = statusController

        refreshPermissions()
        schedulePermissionPolling()

        Task {
            let granted = await Permissions.requestMicrophone()
            self.state.microphoneGranted = granted
            Log.app.info("Microphone granted: \(granted, privacy: .public)")
        }

        startFnMonitor()
        startFrontmostAppTracking()

        hotkeyConsumeTask = Task { [weak self] in
            guard let self else { return }
            for await transition in self.fnMonitor.events {
                await MainActor.run { [weak self] in
                    self?.handleFn(transition)
                }
            }
        }

        // First-launch onboarding: if the default backend's model isn't on
        // disk and we've never asked the user, confirm before triggering the
        // ~1.4 GB Qwen download. If they defer, skip auto-activation entirely
        // — they can opt in later via Settings → Manage Models.
        let deferActivation = shouldShowFirstLaunchOnboarding() && !showFirstLaunchOnboarding()
        if !deferActivation {
            activateBackend(state.asrBackend, forceReload: true)
        } else {
            Log.app.info("Onboarding: user deferred initial download; recognizer not auto-activated")
            // Surface "no model" as `.failed` so Settings + capsule show the
            // real situation instead of the inherited `.unloaded` default
            // (which the rest of the UI reads as "Preparing…" / "still
            // loading"). The error message points the user to the manual
            // download flow.
            let err = NSError(
                domain: "VoiceTyping.Onboarding",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No model downloaded. Open Settings → Manage Models to install one."]
            )
            state.recognizerState = .failed(err)
        }

        // If `main.swift`'s migration step failed to write the extracted
        // API key into Keychain (rare — only on truly degraded Keychain
        // state), tell the user now so they can re-enter the key. The
        // plaintext has already been cleared from UserDefaults either
        // way, so `state.llmConfig.apiKey` is empty at this point.
        if let failure = LLMConfigStore.migrationFailure {
            showAPIKeyMigrationFailureAlert(reason: failure)
        }
    }

    private func shouldShowFirstLaunchOnboarding() -> Bool {
        let ud = UserDefaults.standard
        if ud.object(forKey: "onboardingShownAt") != nil {
            return false  // already asked once
        }
        if ModelStore.isComplete(state.asrBackend) {
            return false  // model already on disk (e.g. dev install with prior cache)
        }
        return true
    }

    /// Returns true iff the user confirmed the download. Marks onboarding
    /// as shown either way so we never ask twice.
    private func showFirstLaunchOnboarding() -> Bool {
        let backend = state.asrBackend
        let alert = NSAlert()
        alert.messageText = "Download speech recognition model?"
        alert.informativeText = """
        VoiceTyping needs to download \(backend.displayName) (\(backend.estimatedSizeLabel)) before \
        you can dictate. The download runs in the background.

        You can also pick a different model later from Settings → Manage Models.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download Now")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        UserDefaults.standard.set(Date(), forKey: "onboardingShownAt")
        return response == .alertFirstButtonReturn
    }

    private func showAPIKeyMigrationFailureAlert(reason: String) {
        let alert = NSAlert()
        alert.messageText = "API key couldn't be migrated"
        alert.informativeText = """
        VoiceTyping tried to move your OpenAI-compatible API key from its v0.3 \
        storage into the macOS Keychain, but the Keychain write failed:

        \(reason)

        The old plaintext copy has been removed. Please re-enter your API key \
        in Settings → LLM.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            statusController.openSettings(tab: .llm)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        fnMonitor.stop()
        hotkeyConsumeTask?.cancel()
        recognizerStateTask?.cancel()
        pipelineTask?.cancel()
        backendSwapTask?.cancel()
        recordingDurationTask?.cancel()
        permissionTimer?.invalidate()
        asrKeepAlive.stop()
        if let obs = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }

    // MARK: - Frontmost-app tracking

    /// Keeps `state.lastNonSelfFrontmostBundleID` current, so the Profiles tab's
    /// "Add frontmost app" can target the real previously-active app — not
    /// VoiceTyping itself, which becomes frontmost the moment Settings opens.
    private func startFrontmostAppTracking() {
        // Seed: VoiceTyping is LSUIElement so whatever is foregrounded right
        // now is the user's actual workspace. If that's somehow us anyway,
        // leave the value nil and wait for the next activation.
        let ours = Bundle.main.bundleIdentifier
        if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           bid != ours {
            state.lastNonSelfFrontmostBundleID = bid
        }

        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let self,
                  let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular,
                  let bid = app.bundleIdentifier,
                  bid != Bundle.main.bundleIdentifier else { return }
            MainActor.assumeIsolated {
                self.state.lastNonSelfFrontmostBundleID = bid
            }
        }
    }

    // MARK: - Backend management

    /// Called by menu. If already active, no-op. Otherwise unload old, swap, prepare new.
    func switchBackend(to backend: ASRBackend) {
        guard backend != activeBackend else { return }
        state.asrBackend = backend
        activateBackend(backend, forceReload: true)
    }

    /// (Re)construct the recognizer for `backend` and kick off prepare(). If a previous
    /// recognizer exists, its observation stream is cancelled first.
    private func activateBackend(_ backend: ASRBackend, forceReload: Bool) {
        backendSwapTask?.cancel()
        recognizerStateTask?.cancel()
        pipelineTask?.cancel()
        // v0.6.4: stop keep-alive before tearing down the old recognizer so
        // an in-flight tick can't dispatch against a model we're about to
        // unload. New recognizer's state observer re-starts it on `.ready`.
        asrKeepAlive.stop()

        // Unload old Qwen to free weights (WhisperKit doesn't expose unload).
        if let old = recognizer as? QwenASRRecognizer {
            old.unload()
        }

        // v0.5.1 UX: detect partial / corrupt downloads from a killed previous
        // session BEFORE prepare() so the next load runs against a clean
        // working tree (or empty dir → upstream re-downloads). `repairIfIncomplete`
        // is sync filesystem-stat work, fast enough to do inline; logs a
        // user-visible line if anything was actually deleted.
        if !ModelStore.isComplete(backend) {
            let repaired = ModelStore.repairIfIncomplete(backend)
            if repaired {
                Log.app.info("Detected incomplete model for \(backend.rawValue, privacy: .public), cleaning and re-downloading")
            }
        }

        let newRecognizer = RecognizerFactory.make(backend)
        self.recognizer = newRecognizer
        self.activeBackend = backend
        self.state.recognizerState = .unloaded

        // Observe state stream
        recognizerStateTask = Task { [weak self] in
            guard let self else { return }
            for await s in newRecognizer.stateStream {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.state.recognizerState = s
                    // Refresh model inventory when download completes
                    if case .ready = s {
                        self.state.modelInventoryTick &+= 1
                    }
                    // v0.6.4: gate keep-alive on `.ready`. Whisper backend
                    // doesn't conform to KeepAliveTarget — the `as?` skips it.
                    // Any non-ready state stops the timer so we don't dispatch
                    // dummy transcribes during loading / failure.
                    if case .ready = s,
                       let qwen = newRecognizer as? QwenASRRecognizer {
                        self.asrKeepAlive.start(target: qwen)
                    } else {
                        self.asrKeepAlive.stop()
                    }
                }
            }
        }

        // Kick off prepare on detached task — may download
        backendSwapTask = Task.detached { [recognizer = newRecognizer, backend] in
            // First-download path: wait for the bandwidth probe so we route
            // through the right endpoint instead of a stale default. Cached
            // installs skip the wait (no download about to happen).
            if !ModelStore.isComplete(backend) {
                await HFEndpointResolver.awaitResolutionIfPending()
            }
            do {
                try await recognizer.prepare()
            } catch {
                Log.app.error("Recognizer prepare failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Pre-warm Silero VAD for live-mic streaming. Loaded lazily via
        // `vadActor.get()`, but the live setup at Fn↓ needs it sync to avoid
        // a race where Fn↑ fires before VAD is ready. Fire-and-forget — if
        // it fails (e.g. SpeechVAD bundle missing in dev build), live mode
        // simply falls back to batch this run.
        if backend.isQwen {
            Task.detached { [weak self] in
                do {
                    let box = try await QwenASRRecognizer.vadActor.get()
                    await MainActor.run { [weak self] in
                        self?.cachedVADBox = box
                        Log.dev(Log.app, "Live: VAD pre-warmed and cached")
                    }
                } catch {
                    Log.app.warning("Live: VAD pre-warm failed (\(error.localizedDescription, privacy: .public)) — live mode will fall back to batch")
                }
            }
        }

        // Bump inventory so UI re-reads state.
        state.modelInventoryTick &+= 1
    }

    /// Called by Settings after a user deletes a backend's files.
    func reloadActiveBackendIfAffected(_ backend: ASRBackend) {
        if backend == activeBackend {
            activateBackend(backend, forceReload: true)
        }
        state.modelInventoryTick &+= 1
    }

    // MARK: - Permissions

    private func refreshPermissions() {
        state.accessibilityGranted = Permissions.checkAccessibility(prompt: false)
        state.microphoneGranted = Permissions.microphoneAuthorized()
    }

    private func schedulePermissionPolling() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let wasAX = self.state.accessibilityGranted
                self.refreshPermissions()
                if !wasAX && self.state.accessibilityGranted {
                    self.startFnMonitor()
                }
            }
        }
    }

    private func startFnMonitor() {
        do {
            try fnMonitor.start(promptIfNeeded: true)
            state.accessibilityGranted = true
        } catch {
            Log.app.warning("Fn monitor start failed: \(String(describing: error), privacy: .public)")
            state.accessibilityGranted = Permissions.checkAccessibility(prompt: false)
        }
    }

    // MARK: - Pipeline

    private func handleFn(_ transition: FnHotkeyMonitor.Transition) {
        switch transition {
        case .pressed:
            // v0.5.3: Fn-tap during hands-free = cancel (discard audio).
            // Same gesture as entry — symmetric and avoids reaching for esc.
            if handsFreeActive {
                cancelHandsFree()
                return
            }
            fnPressTime = Date()
            startRecording()
        case .released:
            // v0.5.3: tap-vs-hold decision happens here, not at Fn↓. Audio
            // captured from t=0 either way, so no audio is lost regardless.
            let pressedAt = fnPressTime
            fnPressTime = nil
            let duration: TimeInterval = pressedAt
                .map { Date().timeIntervalSince($0) } ?? .infinity
            if shouldEnterHandsFree(duration: duration) {
                enterHandsFree()
            } else {
                stopRecording()
            }
        }
    }

    private func startRecording() {
        guard state.status == .idle || isInfoState else {
            return
        }
        guard state.microphoneGranted else {
            flashInfo(message(for: .micDenied), autoHide: true)
            return
        }
        switch state.recognizerState {
        case .ready:
            break
        case .loading:
            flashInfo(message(for: .modelLoading), autoHide: true)
            return
        case .failed:
            flashInfo(message(for: .modelFailed), autoHide: true)
            return
        case .unloaded:
            flashInfo(message(for: .modelLoading), autoHide: true)
            return
        }

        // Decide live mode up-front so we can pass the right maxDuration cap.
        // Cap derives from `RecordingPolicy.maxDuration` — single source of
        // truth shared with the v0.5.3 hands-free path.
        let useLive = state.liveStreamingEnabled
            && activeBackend.isQwen
            && (recognizer is QwenASRRecognizer)
            && cachedVADBox != nil
        let cap = RecordingPolicy.maxDuration(timing: state.transcriptionTiming,
                                               backend: activeBackend)

        do {
            let outputs = try audio.start(maxDuration: cap)
            state.status = .recording
            infoResetTask?.cancel()
            capsuleWindow.show(levels: outputs.levels)

            // v0.5.1 Debug Capture: open a session writer if the toggle is on.
            // Created BEFORE `startLiveTranscriberIfEnabled` so the live path
            // can pass an observer that funnels per-segment events into it.
            // Snapshot is the Fn↓ state — survives later state edits.
            let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let asrCtx = GlossaryBuilder.buildForASR(activeBackend,
                                                     entries: state.dictionary.entries,
                                                     language: state.language)
            let snippet = state.profiles.lookup(bundleID: bid)?.systemPromptSnippet
            currentDebugWriter = DebugCaptureWriter.begin(
                state: state,
                backend: activeBackend,
                language: state.language,
                liveMode: useLive,
                frontmostBundleID: bid,
                profileSnippet: snippet,
                asrContext: asrCtx
            )

            // v0.5.3: if hands-free conditions might fire on Fn↑, wire a VAD
            // observer up-front so the watchdog/live pump has it ready by the
            // time the user releases. The observer is gated by
            // `handsFreeActive` so events that fire before hands-free entry
            // are no-ops.
            let mightHandsFree = state.handsFreeEnabled
                && activeBackend.isQwen
                && cachedVADBox != nil
            let vadObserver: LiveTranscriber.VADObserver?
            if mightHandsFree {
                let observer: LiveTranscriber.VADObserver = { [weak self] event in
                    Task { @MainActor in self?.handleHandsFreeVAD(event) }
                }
                vadObserver = observer
            } else {
                vadObserver = nil
            }

            // v0.5.3: non-live + hands-free needs a VAD-only watchdog because
            // LiveTranscriber isn't running. The watchdog will consume
            // `outputs.samples` itself, so suppress the default drain.
            let needsWatchdog = !useLive && mightHandsFree && cachedVADBox != nil

            // Live wiring (no-op when useLive is false; drains samples to
            // /dev/null unless the watchdog branch will consume them).
            startLiveTranscriberIfEnabled(samples: outputs.samples,
                                           useLive: useLive,
                                           vadObserver: vadObserver,
                                           drainIfNotLive: !needsWatchdog)

            if needsWatchdog, let vadBox = cachedVADBox, let obs = vadObserver {
                startHandsFreeWatchdog(samples: outputs.samples, vadBox: vadBox, observer: obs)
            }
            // v0.5.1: countdown overlay near the cap. Live mode (cap=600) gets
            // a 60 s warning window; batch (cap=60) gets a 10 s window. Most
            // sessions never trigger because users rarely hold Fn near the cap.
            startRecordingDurationTimer(maxDuration: cap)
        } catch {
            Log.app.error("Audio start failed: \(error.localizedDescription, privacy: .public)")
            flashInfo(message(for: .micFailed), autoHide: true)
        }
    }

    /// Schedules a "Xs left" overlay starting `warningWindow` seconds before
    /// the audio capture cap fires. Window scales with the cap — long live
    /// sessions get a generous 60 s heads-up, short batch sessions get 10 s.
    /// The overlay text bypasses `state.status` so the recording-state gate
    /// in `stopRecording` keeps working; cleanup is the caller's
    /// responsibility (see `clearRecordingDurationTimer`).
    @MainActor
    private func startRecordingDurationTimer(maxDuration: TimeInterval) {
        recordingDurationTask?.cancel()
        state.capsuleOverlayText = nil
        let warningWindow: TimeInterval = maxDuration > 120 ? 60 : 10
        let threshold = max(0, maxDuration - warningWindow)
        let start = Date()
        recordingDurationTask = Task { [weak self] in
            // Sleep until the warning window opens. `Task.sleep` is
            // cancellation-aware → Fn↑ tears this down promptly.
            try? await Task.sleep(nanoseconds: UInt64(threshold * 1_000_000_000))
            while !Task.isCancelled {
                let remaining = maxDuration - Date().timeIntervalSince(start)
                if remaining <= 0 { break }
                let label = "\(Int(ceil(remaining)))s left"
                await MainActor.run { [weak self] in
                    self?.state.capsuleOverlayText = label
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    @MainActor
    func clearRecordingDurationTimer() {
        recordingDurationTask?.cancel()
        recordingDurationTask = nil
        state.capsuleOverlayText = nil
    }

    private var isInfoState: Bool {
        if case .info = state.status { return true }
        return false
    }

    func stopRecording() {
        guard state.status == .recording else { return }
        let buffer = audio.stop()
        state.status = .transcribing
        clearRecordingDurationTimer()
        // v0.5.3: tear down hands-free state if it was active. Safe to call
        // unconditionally — no-op when handsFreeActive is already false.
        cleanupHandsFreeState()

        // v0.5.1 Debug Capture: hand writer ownership off to the pipelineTask
        // (or abort on early return). Clearing the field eagerly so a quick
        // re-press of Fn starts a fresh session rather than appending into
        // the in-flight one.
        let captureWriter = currentDebugWriter
        currentDebugWriter = nil

        // Guard against ultra-short taps (e.g. accidental Fn press). The Qwen
        // mel extractor and Whisper both assume at least one FFT window
        // (~400 samples @ 16 kHz ≈ 25 ms); feeding less crashes the process.
        if buffer.samples.count < 400 {
            Log.app.info("stopRecording: buffer too short (\(buffer.samples.count, privacy: .public) samples), skipping ASR")
            cleanUpLiveState()
            captureWriter?.abort()
            flashInfo(message(for: .noSpeech), autoHide: true)
            return
        }

        // Move the live-mode handle off the field so the next Fn cycle starts
        // from a clean slate. nil out before launching the pipelineTask so a
        // reentrant startRecording can't see stale state.
        let liveTranscriber = activeLiveTranscriber
        let liveIngest = liveIngestTask
        let liveInject = liveInjectTask
        let liveSnap = liveSnapshot
        activeLiveTranscriber = nil
        liveIngestTask = nil
        liveInjectTask = nil
        liveSnapshot = nil

        // ASR-side state: live mode uses the early snapshot (captured at Fn↓);
        // batch mode snapshots at Fn↑. Refine/inject snapshots are always Fn↑.
        let backend: ASRBackend
        let language: Language
        let dictEntries: [DictionaryEntry]
        let asrContext: String?
        let frontmostBundleID: String?
        let profileSnippet: String?
        if let snap = liveSnap {
            backend = snap.backend
            language = snap.language
            dictEntries = snap.dictEntries
            asrContext = snap.asrContext
            frontmostBundleID = snap.frontmostBundleID
            profileSnippet = snap.profileSnippet
        } else {
            backend = activeBackend
            language = state.language
            dictEntries = state.dictionary.entries
            frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            asrContext = GlossaryBuilder.buildForASR(backend, entries: dictEntries, language: language)
            let profile = state.profiles.lookup(bundleID: frontmostBundleID)
            profileSnippet = profile?.systemPromptSnippet
            if let profile {
                Log.dev(Log.app, "Context profile: \(profile.name) (bundle=\(profile.bundleID))")
            }
        }
        let mode = state.refineMode
        let llmConfig = state.llmConfig
        // v0.7.0 #R6/#R7: pick the refine delivery mode and apply the
        // streaming deny-list (Notion → batch, see ADR 0001) before
        // dispatching. `rawFirst` survives only as the legacy log/capture
        // flag (the persisted toggle is gone).
        let delivery = RefineDelivery.resolved(state.refineDelivery, bundleID: frontmostBundleID)
        // Streaming is opt-in and Whisper has no streaming engine. If the toggle is on but
        // the active backend is Whisper, fall through to the batch path silently — the
        // Settings UI already disables the toggle in that case. Irrelevant when live
        // mode is on (live takes precedence and produces its own transcript).
        let useStreaming = state.streamingEnabled && backend.isQwen
        if let ctx = asrContext {
            Log.dev(Log.app, "ASR bias: backend=\(backend.rawValue) entries=\(dictEntries.count) context=\(ctx)")
        } else {
            Log.dev(Log.app, "ASR bias: none (entries=\(dictEntries.count), backend=\(backend.rawValue))")
        }

        let tracker = LatencyTracker()

        pipelineTask?.cancel()
        pipelineTask = Task { [weak self] in
            guard let self else { return }

            // --- Live mode ---
            // Segments were transcribed AND injected as they arrived (see
            // `AppDelegate+Live.swift`'s inject task). Here we just await the
            // drain to know we have the final transcript, then close out the
            // capsule UI. Refine is intentionally skipped — see devlog v0.5.0
            // "明确不做" for why.
            if let lt = liveTranscriber {
                tracker.mark(.asrStart)
                await liveIngest?.value     // upstream samples drained
                lt.finish()                  // signal flush of any tail segment
                let transcript = (await liveInject?.value) ?? ""
                tracker.mark(.asrEnd)
                let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                Log.dev(Log.asr, "Live drain final: \(trimmed.count) chars")

                await MainActor.run {
                    if trimmed.isEmpty {
                        self.flashInfo(self.message(for: .noSpeech), autoHide: true)
                    } else {
                        self.capsuleWindow.hide()
                        self.state.status = .idle
                    }
                }
                tracker.log(
                    backend: backend.rawValue,
                    mode: "live",  // refine is skipped in live mode
                    dictEntries: dictEntries.count,
                    delivery: "live"
                )
                captureWriter?.finalize(audio: buffer)
                return
            }

            // --- Batch / post-record streaming ---
            tracker.mark(.asrStart)
            let asrStartedAt = Date()
            var transcript = ""
            do {
                transcript = try await self.runASR(
                    buffer: buffer,
                    language: language,
                    context: asrContext,
                    useStreaming: useStreaming
                )
            } catch {
                Log.app.error("Transcribe failed: \(error.localizedDescription, privacy: .public)")
            }
            tracker.mark(.asrEnd)
            let asrMs = Int(Date().timeIntervalSince(asrStartedAt) * 1000)

            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                captureWriter?.abort()
                await MainActor.run {
                    self.flashInfo(self.message(for: .noSpeech), autoHide: true)
                }
                return
            }

            // v0.5.1 Debug Capture: batch records one segment for the whole
            // transcript (per-yield capture would require threading the writer
            // through `runASR` / `transcribeStreaming` and isn't worth the
            // surface for the analyses that v0.5.1 ships).
            captureWriter?.appendSegment(.init(
                timestamp: Date(),
                startSec: 0,
                endSec: buffer.duration,
                rawText: trimmed,
                filter: .kept,
                transcribeMs: asrMs
            ))

            // Record ASR-side dictionary hits.
            let asrHits = GlossaryBuilder.matchedEntryIDs(in: trimmed, entries: dictEntries)
            await MainActor.run { self.state.noteDictionaryMatches(asrHits) }

            // Decide whether refinement will run at all.
            let willRefine = (mode.systemPrompt != nil) && llmConfig.hasCredentials

            let injStart = Date()
            if !willRefine {
                // No refine — straight inject of raw. delivery is moot.
                await self.injectWaitingForRefine(
                    raw: trimmed,
                    willRefine: false,
                    mode: mode,
                    language: language,
                    dictEntries: dictEntries,
                    llmConfig: llmConfig,
                    backend: backend,
                    profileSnippet: profileSnippet,
                    tracker: tracker,
                    captureWriter: captureWriter
                )
            } else {
                switch delivery {
                case .streaming:
                    await self.injectStreamingRefine(
                        raw: trimmed,
                        mode: mode,
                        language: language,
                        dictEntries: dictEntries,
                        backend: backend,
                        profileSnippet: profileSnippet,
                        tracker: tracker,
                        captureWriter: captureWriter
                    )
                case .rawFirst:
                    await self.injectRawFirstThenRefine(
                        raw: trimmed,
                        mode: mode,
                        language: language,
                        dictEntries: dictEntries,
                        llmConfig: llmConfig,
                        backend: backend,
                        bundleID: frontmostBundleID,
                        profileSnippet: profileSnippet,
                        tracker: tracker,
                        captureWriter: captureWriter
                    )
                case .batch:
                    await self.injectWaitingForRefine(
                        raw: trimmed,
                        willRefine: true,
                        mode: mode,
                        language: language,
                        dictEntries: dictEntries,
                        llmConfig: llmConfig,
                        backend: backend,
                        profileSnippet: profileSnippet,
                        tracker: tracker,
                        captureWriter: captureWriter
                    )
                }
            }
            let injMs = Int(Date().timeIntervalSince(injStart) * 1000)
            // Batch-mode injection record. Status is always `.ok` because the
            // injectWaitingForRefine / injectRawFirstThenRefine paths don't
            // surface a failure signal — if the inject failed, the user would
            // see no text appear and the writer's audio.wav + segments.jsonl
            // are still useful for diagnosis.
            captureWriter?.appendInjection(.init(
                timestamp: Date(),
                chars: trimmed.count,
                textPreview: String(trimmed.prefix(120)),
                targetBundleID: frontmostBundleID,
                actualBundleID: nil,
                status: .ok,
                elapsedMs: injMs
            ))
            captureWriter?.finalize(audio: buffer)
        }
    }

    /// Dispatches to the streaming or batch recognizer call. Streaming still
    /// runs (long-recording support, progressive ASR) but partials are no
    /// longer rendered on screen — v0.4.4 removed the transcript preview UI.
    /// Streaming is Qwen-only — Whisper falls through to the batch path.
    private func runASR(
        buffer: AudioBuffer,
        language: Language,
        context: String?,
        useStreaming: Bool
    ) async throws -> String {
        if useStreaming, let qwen = recognizer as? QwenASRRecognizer {
            var latest = ""
            for try await partial in qwen.transcribeStreaming(
                buffer, language: language, context: context,
                tuning: .production
            ) {
                latest = partial
            }
            return latest
        }
        return try await self.recognizer.transcribe(
            buffer, language: language, context: context
        )
    }

    /// Classic v0.2-shaped pipeline: transcribe → (optional refine) → paste once.
    private func injectWaitingForRefine(
        raw: String,
        willRefine: Bool,
        mode: RefineMode,
        language: Language,
        dictEntries: [DictionaryEntry],
        llmConfig: LLMConfig,
        backend: ASRBackend,
        profileSnippet: String?,
        tracker: LatencyTracker,
        captureWriter: DebugCaptureWriter?
    ) async {
        var finalText = raw
        if willRefine {
            await MainActor.run {
                self.state.status = .refining
            }
            let glossary = GlossaryBuilder.buildLLMGlossary(from: dictEntries)
            // v0.6.3 #R8: capture refine I/O for offline cloud↔local A/B.
            // Backend label snapshotted from MainActor before await so a
            // mid-call Settings flip can't mislabel the record. The writer
            // is the *local* one threaded in from pipelineTask — reading
            // `self.currentDebugWriter` here would always see nil because
            // stopRecording nils that field at line 653 before the async
            // pipeline runs.
            let refineCaptureBackend = await MainActor.run { self.state.localRefinerEnabled ? "local" : "cloud" }
            let refineStarted = Date()
            tracker.mark(.llmStart)
            let refined = await self.refiner.refine(
                raw,
                language: language,
                mode: mode,
                glossary: glossary,
                profileSnippet: profileSnippet
            )
            tracker.mark(.llmEnd)
            captureWriter?.appendRefine(DebugCaptureWriter.RefineRecord(
                timestamp: refineStarted,
                input: raw,
                output: refined,
                mode: mode.rawValue,
                backend: refineCaptureBackend,
                latencyMs: Int(Date().timeIntervalSince(refineStarted) * 1000),
                glossary: glossary,
                profileSnippet: profileSnippet,
                rawFirst: false
            ))
            finalText = refined

            let llmHits = GlossaryBuilder.matchedEntryIDs(in: refined, entries: dictEntries)
            await MainActor.run { self.state.noteDictionaryMatches(llmHits) }
        }

        tracker.mark(.injectStart)
        await self.injector.inject(finalText)
        tracker.mark(.injectEnd)

        await MainActor.run {
            self.capsuleWindow.hide()
            self.state.status = .idle
        }

        tracker.log(
            backend: backend.rawValue,
            mode: mode.rawValue,
            dictEntries: dictEntries.count,
            delivery: RefineDelivery.batch.rawValue
        )
    }

    /// v0.7.0 #R6: streaming refine path. Drives `refineStream` directly into
    /// `injector.injectIncremental(stream:)` — chunks land in the focused app
    /// at sentence/word boundaries as the LLM produces them. No raw-first
    /// fallback, no post-hoc replace; user sees forward-only writing.
    ///
    /// **Cancellation (#R8)** — two signals route to the same `pipelineTask`:
    /// 1. **Esc**: a global keydown monitor watches for `kVK_Escape` and
    ///    cancels `pipelineTask`. The monitor doesn't intercept (target app
    ///    may also see Esc — usually a no-op / popover dismiss, acceptable).
    /// 2. **Focus loss**: the wrapped stream snapshots the frontmost bundle
    ///    ID at start; on each chunk it re-checks and finishes the stream
    ///    with `CancellationError` if the user has switched apps.
    /// Both surface inside `injectIncremental` as a CancellationError, which
    /// drops the pending buffer and restores the pasteboard.
    private func injectStreamingRefine(
        raw: String,
        mode: RefineMode,
        language: Language,
        dictEntries: [DictionaryEntry],
        backend: ASRBackend,
        profileSnippet: String?,
        tracker: LatencyTracker,
        captureWriter: DebugCaptureWriter?
    ) async {
        await MainActor.run {
            self.state.status = .refining
            self.state.streamingChars = 0
        }
        let glossary = GlossaryBuilder.buildLLMGlossary(from: dictEntries)
        let refineCaptureBackend = await MainActor.run { self.state.localRefinerEnabled ? "local" : "cloud" }
        let refineStarted = Date()
        let initialBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let pipelineTaskRef = self.pipelineTask

        // Esc monitor — addGlobalMonitorForEvents handler runs on the main
        // run loop, so calling Task.cancel() from it is safe; cancel() itself
        // is also thread-safe.
        let escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // kVK_Escape
                Log.app.info("StreamingRefine: Esc cancel")
                pipelineTaskRef?.cancel()
            }
        }
        defer {
            if let m = escMonitor { NSEvent.removeMonitor(m) }
        }

        // Streaming overlaps the llm and inject phases — both bounds match
        // the life of refineStream consumption.
        tracker.mark(.llmStart)
        tracker.mark(.injectStart)

        let upstream = self.refiner.refineStream(
            raw,
            language: language,
            mode: mode,
            glossary: glossary,
            profileSnippet: profileSnippet
        )

        // Wrap upstream with the focus-loss watch + capsule progress counter.
        // We can't put the focus check inside `injectIncremental` without
        // coupling it to `NSWorkspace`, and we can't put it inside `refiner`
        // because the refiner is platform-agnostic. Doing it here keeps both
        // boundaries clean.
        let watched = AsyncThrowingStream<String, Error> { continuation in
            let task = Task { [weak self] in
                do {
                    for try await chunk in upstream {
                        let current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                        if current != initialBundleID {
                            Log.app.info("StreamingRefine: focus changed \(initialBundleID ?? "nil", privacy: .public) → \(current ?? "nil", privacy: .public), cancelling")
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        if let self {
                            let count = chunk.count
                            await MainActor.run { self.state.streamingChars += count }
                        }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        let result = await self.injector.injectIncremental(stream: watched)

        tracker.mark(.injectEnd)
        tracker.mark(.llmEnd)

        captureWriter?.appendRefine(DebugCaptureWriter.RefineRecord(
            timestamp: refineStarted,
            input: raw,
            output: result.accumulated,
            mode: mode.rawValue,
            backend: refineCaptureBackend,
            latencyMs: Int(Date().timeIntervalSince(refineStarted) * 1000),
            glossary: glossary,
            profileSnippet: profileSnippet,
            rawFirst: false
        ))

        let llmHits = GlossaryBuilder.matchedEntryIDs(in: result.accumulated, entries: dictEntries)
        await MainActor.run {
            self.state.noteDictionaryMatches(llmHits)
            self.state.streamingChars = 0
            self.capsuleWindow.hide()
            self.state.status = .idle
        }

        Log.app.notice("StreamingRefine chars=\(result.charsInjected, privacy: .public) accumulated=\(result.accumulated.count, privacy: .public) cancelled=\(result.cancelled, privacy: .public) errored=\(result.streamError != nil, privacy: .public)")

        tracker.log(
            backend: backend.rawValue,
            mode: mode.rawValue,
            dictEntries: dictEntries.count,
            delivery: RefineDelivery.streaming.rawValue
        )
    }

    /// Raw-first: paste ASR output now, start refiner in parallel, replace later
    /// via Cmd+Z + re-paste IF the user hasn't moved on.
    private func injectRawFirstThenRefine(
        raw: String,
        mode: RefineMode,
        language: Language,
        dictEntries: [DictionaryEntry],
        llmConfig: LLMConfig,
        backend: ASRBackend,
        bundleID: String?,
        profileSnippet: String?,
        tracker: LatencyTracker,
        captureWriter: DebugCaptureWriter?
    ) async {
        // Step 1: paste raw immediately.
        tracker.mark(.injectStart)
        await self.injector.inject(raw)
        tracker.mark(.injectEnd)

        await MainActor.run {
            self.capsuleWindow.hide()
            self.state.status = .idle
        }

        // Step 2: refine in the background.
        let glossary = GlossaryBuilder.buildLLMGlossary(from: dictEntries)
        // v0.6.3 #R8: capture refine I/O. Same snapshot pattern as the
        // post-record path above — backend label captured before await so
        // mid-flight Settings flips don't mislabel the record. The writer
        // is the *local* one threaded in from pipelineTask (see comment in
        // injectWaitingForRefine for why `self.currentDebugWriter` doesn't
        // work here).
        let refineCaptureBackend = await MainActor.run { self.state.localRefinerEnabled ? "local" : "cloud" }
        let refineStarted = Date()
        tracker.mark(.llmStart)
        let refined = await self.refiner.refine(
            raw,
            language: language,
            mode: mode,
            glossary: glossary,
            profileSnippet: profileSnippet
        )
        tracker.mark(.llmEnd)
        captureWriter?.appendRefine(DebugCaptureWriter.RefineRecord(
            timestamp: refineStarted,
            input: raw,
            output: refined,
            mode: mode.rawValue,
            backend: refineCaptureBackend,
            latencyMs: Int(Date().timeIntervalSince(refineStarted) * 1000),
            glossary: glossary,
            profileSnippet: profileSnippet,
            rawFirst: true
        ))

        let trimmedRefined = refined.trimmingCharacters(in: .whitespacesAndNewlines)

        // Step 3: if refiner changed nothing or still in the same app, try to replace.
        let unchanged = trimmedRefined == raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentBundleID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        let focusSafe = (currentBundleID != nil) && (currentBundleID == bundleID)

        let llmHits = GlossaryBuilder.matchedEntryIDs(in: trimmedRefined, entries: dictEntries)
        await MainActor.run { self.state.noteDictionaryMatches(llmHits) }

        if !unchanged && focusSafe {
            // Undo the raw paste, then paste refined. Uses Cmd+Z which all cocoa
            // text fields honor; on failure we simply leave the raw output in place.
            await self.replaceLastInjection(with: trimmedRefined)
        } else if !focusSafe {
            Log.app.info("Raw-first refine skipped rewrite: focus moved from \(bundleID ?? "nil", privacy: .public) to \(currentBundleID ?? "nil", privacy: .public)")
        }

        tracker.log(
            backend: backend.rawValue,
            mode: mode.rawValue,
            dictEntries: dictEntries.count,
            delivery: RefineDelivery.rawFirst.rawValue
        )
    }

    /// Simulates Cmd+Z (to remove the previous paste) then pastes `refined`.
    private func replaceLastInjection(with refined: String) async {
        await MainActor.run {
            // Send Cmd+Z through the same HID tap path as Cmd+V.
            let zKey: CGKeyCode = 0x06 // kVK_ANSI_Z
            let source = CGEventSource(stateID: .hidSystemState)
            if let down = CGEvent(keyboardEventSource: source, virtualKey: zKey, keyDown: true) {
                down.flags = .maskCommand
                down.post(tap: .cghidEventTap)
            }
            usleep(20_000)
            if let up = CGEvent(keyboardEventSource: source, virtualKey: zKey, keyDown: false) {
                up.flags = .maskCommand
                up.post(tap: .cghidEventTap)
            }
        }
        // Small grace for the host app to process the undo.
        try? await Task.sleep(nanoseconds: 60_000_000)
        await self.injector.inject(refined)
    }

    // MARK: - Flash messaging via capsule

    private enum FlashMessage {
        case micDenied, micFailed, modelLoading, modelFailed, noSpeech
    }

    private func message(for f: FlashMessage) -> String {
        switch f {
        case .micDenied:    return "Microphone permission needed"
        case .micFailed:    return "Could not start microphone"
        case .modelLoading: return "Model still loading…"
        case .modelFailed:  return "Model failed to load"
        case .noSpeech:     return "No speech detected"
        }
    }

    private func flashInfo(_ msg: String, autoHide: Bool) {
        state.status = .info(msg)
        capsuleWindow.show(levels: nil)

        infoResetTask?.cancel()
        if autoHide {
            infoResetTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run {
                    guard let self else { return }
                    if case .info = self.state.status {
                        self.capsuleWindow.hide()
                        self.state.status = .idle
                    }
                }
            }
        }
    }

    // MARK: - Live transcriber (v0.5.0)
    //
    // Definitions live in `AppDelegate+Live.swift` so the live-streaming wiring
    // (LiveTranscriber lifecycle, samples ingest task, snapshot capture) stays
    // separable from the post-record batch pipeline above.
}
