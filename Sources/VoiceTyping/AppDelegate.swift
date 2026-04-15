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
        c.onLLMEnabledChanged = { [weak self] enabled in
            guard let self else { return }
            var cfg = self.state.llmConfig
            cfg.enabled = enabled
            self.state.llmConfig = cfg
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        fnMonitor.stop()
        hotkeyConsumeTask?.cancel()
        recognizerStateTask?.cancel()
        pipelineTask?.cancel()
        backendSwapTask?.cancel()
        permissionTimer?.invalidate()
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

        pipelineTask?.cancel()
        pipelineTask = Task { [weak self] in
            guard let self else { return }

            var transcript = ""
            do {
                transcript = try await self.recognizer.transcribe(buffer, language: self.state.language)
            } catch {
                Log.app.error("Transcribe failed: \(error.localizedDescription, privacy: .public)")
            }

            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                await MainActor.run {
                    self.flashInfo(self.message(for: .noSpeech), autoHide: true)
                }
                return
            }

            // LLM refinement
            var finalText = trimmed
            if self.state.llmConfig.isUsable {
                await MainActor.run {
                    self.state.capsuleText = trimmed
                    self.state.status = .refining
                }
                let refined = await self.refiner.refine(trimmed, language: self.state.language, config: self.state.llmConfig)
                finalText = refined
            }

            await self.injector.inject(finalText)

            await MainActor.run {
                self.capsuleWindow.hide()
                self.state.capsuleText = ""
                self.state.status = .idle
            }
        }
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
