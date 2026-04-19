import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let state = AppState()
    let audio = AudioCapture()
    let injector = TextInjector()
    let refiner = LLMRefiner()
    let fnMonitor = FnHotkeyMonitor()

    private var recognizer: SpeechRecognizer!
    private var activeBackend: ASRBackend = .default

    lazy var statusController: StatusItemController = {
        let c = StatusItemController(state: state)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        ModelStore.migrateV010WhisperLayoutIfNeeded()

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

        // Construct and prepare the initial backend.
        activateBackend(state.asrBackend, forceReload: true)

        // If `main.swift`'s migration step failed to write the extracted
        // API key into Keychain (rare — only on truly degraded Keychain
        // state), tell the user now so they can re-enter the key. The
        // plaintext has already been cleared from UserDefaults either
        // way, so `state.llmConfig.apiKey` is empty at this point.
        if let failure = LLMConfigStore.migrationFailure {
            showAPIKeyMigrationFailureAlert(reason: failure)
        }
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
        permissionTimer?.invalidate()
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

        // Unload old Qwen to free weights (WhisperKit doesn't expose unload).
        if let old = recognizer as? QwenASRRecognizer {
            old.unload()
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
                    self?.state.recognizerState = s
                    // Refresh model inventory when download completes
                    if case .ready = s {
                        self?.state.modelInventoryTick &+= 1
                    }
                }
            }
        }

        // Kick off prepare on detached task — may download
        backendSwapTask = Task.detached { [recognizer = newRecognizer] in
            do {
                try await recognizer.prepare()
            } catch {
                Log.app.error("Recognizer prepare failed: \(error.localizedDescription, privacy: .public)")
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
        case .pressed:  startRecording()
        case .released: stopRecording()
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

        do {
            let levels = try audio.start()
            state.capsuleText = ""
            state.status = .recording
            infoResetTask?.cancel()
            capsuleWindow.show(levels: levels)
        } catch {
            Log.app.error("Audio start failed: \(error.localizedDescription, privacy: .public)")
            flashInfo(message(for: .micFailed), autoHide: true)
        }
    }

    private var isInfoState: Bool {
        if case .info = state.status { return true }
        return false
    }

    private func stopRecording() {
        guard state.status == .recording else { return }
        let buffer = audio.stop()
        state.status = .transcribing

        // Guard against ultra-short taps (e.g. accidental Fn press). The Qwen
        // mel extractor and Whisper both assume at least one FFT window
        // (~400 samples @ 16 kHz ≈ 25 ms); feeding less crashes the process.
        if buffer.samples.count < 400 {
            Log.app.info("stopRecording: buffer too short (\(buffer.samples.count, privacy: .public) samples), skipping ASR")
            flashInfo(message(for: .noSpeech), autoHide: true)
            return
        }

        // Snapshot everything that affects this pipeline run so later mutations
        // (user edits the dictionary, switches refine mode, etc.) don't corrupt
        // the in-flight transcription.
        let backend = activeBackend
        let language = state.language
        let dictEntries = state.dictionary.entries
        let mode = state.refineMode
        let llmConfig = state.llmConfig
        let rawFirst = state.rawFirstEnabled
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let asrContext = GlossaryBuilder.buildForASR(backend, entries: dictEntries, language: language)
        let profile = state.profiles.lookup(bundleID: frontmostBundleID)
        let profileSnippet = profile?.systemPromptSnippet
        if let ctx = asrContext {
            Log.app.info("ASR bias: backend=\(backend.rawValue, privacy: .public) entries=\(dictEntries.count, privacy: .public) context=\(ctx, privacy: .public)")
        } else {
            Log.app.info("ASR bias: none (entries=\(dictEntries.count, privacy: .public), backend=\(backend.rawValue, privacy: .public))")
        }
        if let profile {
            Log.app.info("Context profile: \(profile.name, privacy: .public) (bundle=\(profile.bundleID, privacy: .public))")
        }

        let tracker = LatencyTracker()

        pipelineTask?.cancel()
        pipelineTask = Task { [weak self] in
            guard let self else { return }

            // --- ASR ---
            tracker.mark(.asrStart)
            var transcript = ""
            do {
                transcript = try await self.recognizer.transcribe(
                    buffer,
                    language: language,
                    context: asrContext
                )
            } catch {
                Log.app.error("Transcribe failed: \(error.localizedDescription, privacy: .public)")
            }
            tracker.mark(.asrEnd)

            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                await MainActor.run {
                    self.flashInfo(self.message(for: .noSpeech), autoHide: true)
                }
                return
            }

            // Record ASR-side dictionary hits.
            let asrHits = GlossaryBuilder.matchedEntryIDs(in: trimmed, entries: dictEntries)
            await MainActor.run { self.state.noteDictionaryMatches(asrHits) }

            // Decide whether refinement will run at all.
            let willRefine = (mode.systemPrompt != nil) && llmConfig.hasCredentials

            if willRefine && rawFirst {
                // Raw-first: inject raw immediately, refine in background, replace if safe.
                await self.injectRawFirstThenRefine(
                    raw: trimmed,
                    mode: mode,
                    language: language,
                    dictEntries: dictEntries,
                    llmConfig: llmConfig,
                    backend: backend,
                    bundleID: frontmostBundleID,
                    profileSnippet: profileSnippet,
                    tracker: tracker
                )
            } else {
                await self.injectWaitingForRefine(
                    raw: trimmed,
                    willRefine: willRefine,
                    mode: mode,
                    language: language,
                    dictEntries: dictEntries,
                    llmConfig: llmConfig,
                    backend: backend,
                    profileSnippet: profileSnippet,
                    tracker: tracker
                )
            }
        }
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
        tracker: LatencyTracker
    ) async {
        var finalText = raw
        if willRefine {
            await MainActor.run {
                self.state.capsuleText = raw
                self.state.status = .refining
            }
            let glossary = GlossaryBuilder.buildLLMGlossary(from: dictEntries)
            tracker.mark(.llmStart)
            let refined = await self.refiner.refine(
                raw,
                language: language,
                mode: mode,
                glossary: glossary,
                profileSnippet: profileSnippet,
                config: llmConfig
            )
            tracker.mark(.llmEnd)
            finalText = refined

            let llmHits = GlossaryBuilder.matchedEntryIDs(in: refined, entries: dictEntries)
            await MainActor.run { self.state.noteDictionaryMatches(llmHits) }
        }

        tracker.mark(.injectStart)
        await self.injector.inject(finalText)
        tracker.mark(.injectEnd)

        await MainActor.run {
            self.capsuleWindow.hide()
            self.state.capsuleText = ""
            self.state.status = .idle
        }

        tracker.log(
            backend: backend.rawValue,
            mode: mode.rawValue,
            dictEntries: dictEntries.count,
            rawFirst: false
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
        tracker: LatencyTracker
    ) async {
        // Step 1: paste raw immediately.
        tracker.mark(.injectStart)
        await self.injector.inject(raw)
        tracker.mark(.injectEnd)

        await MainActor.run {
            self.capsuleWindow.hide()
            self.state.capsuleText = ""
            self.state.status = .idle
        }

        // Step 2: refine in the background.
        let glossary = GlossaryBuilder.buildLLMGlossary(from: dictEntries)
        tracker.mark(.llmStart)
        let refined = await self.refiner.refine(
            raw,
            language: language,
            mode: mode,
            glossary: glossary,
            profileSnippet: profileSnippet,
            config: llmConfig
        )
        tracker.mark(.llmEnd)

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
            rawFirst: true
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
        state.capsuleText = ""
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
}
