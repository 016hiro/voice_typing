import AppKit
import Combine
import Sparkle

@MainActor
final class StatusItemController: NSObject {

    private let state: AppState
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []
    /// v0.6.0: target of the "Check for Updates…" menu item. Owned by
    /// AppDelegate (must outlive every menu rebuild) so we just hold a
    /// reference here.
    private let updaterController: SPUStandardUpdaterController

    private var settingsWindowController: SettingsWindowController?

    // Delegate-style callbacks wired by AppDelegate
    var onLanguageSelected: ((Language) -> Void)?
    var onRefineModeSelected: ((RefineMode) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onASRBackendSelected: ((ASRBackend) -> Void)?
    var onGrantAccessibility: (() -> Void)?
    var onGrantMicrophone: (() -> Void)?
    var onQuit: (() -> Void)?

    init(state: AppState, updaterController: SPUStandardUpdaterController) {
        self.state = state
        self.updaterController = updaterController
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = Self.icon(for: .idle)
            button.image?.isTemplate = true
        }
        statusItem.menu = menu
        menu.delegate = self

        observe()
        rebuildMenu()
    }

    private func observe() {
        state.$status.sink { [weak self] _ in
            guard let self else { return }
            self.updateIcon()
        }.store(in: &cancellables)

        state.$language.sink { [weak self] _ in
            self?.rebuildMenu()
        }.store(in: &cancellables)

        state.$llmConfig.sink { [weak self] _ in
            self?.rebuildMenu()
        }.store(in: &cancellables)

        state.$refineMode.sink { [weak self] _ in
            self?.rebuildMenu()
        }.store(in: &cancellables)

        state.$asrBackend.sink { [weak self] _ in
            self?.rebuildMenu()
        }.store(in: &cancellables)

        // Coalesce recognizerState changes: the loading-progress callback fires many
        // times per second; rebuilding the whole NSMenu on every progress tick caused
        // visible flicker / "stacked menu" artifacts when the user kept the menu open.
        // Only rebuild on state-kind transitions (loading→ready, etc.).
        state.$recognizerState.sink { [weak self] _ in
            self?.updateIcon()
        }.store(in: &cancellables)

        state.$recognizerState
            .map { Self.stateKind($0) }
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }.store(in: &cancellables)

        state.$accessibilityGranted.sink { [weak self] _ in
            self?.updateIcon()
            self?.rebuildMenu()
        }.store(in: &cancellables)

        state.$modelInventoryTick.sink { [weak self] _ in
            self?.rebuildMenu()
        }.store(in: &cancellables)
    }

    // MARK: - Icon

    enum IconState { case idle, recording, loading, needsPermission }

    /// Discriminator for `RecognizerState`'s 4 cases — used to coalesce update bursts
    /// where only the inner `progress` value changes (which drives flicker).
    private static func stateKind(_ s: RecognizerState) -> Int {
        switch s {
        case .unloaded: return 0
        case .loading:  return 1
        case .ready:    return 2
        case .failed:   return 3
        }
    }

    private func currentIconState() -> IconState {
        if !state.accessibilityGranted || !state.microphoneGranted {
            return .needsPermission
        }
        if case .loading = state.recognizerState { return .loading }
        if case .failed = state.recognizerState { return .needsPermission }
        if state.status == .recording || state.status == .transcribing || state.status == .refining {
            return .recording
        }
        return .idle
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let image = Self.icon(for: currentIconState())
        image?.isTemplate = true
        button.image = image
    }

    private static func icon(for s: IconState) -> NSImage? {
        let name: String
        switch s {
        case .idle:             name = "mic.fill"
        case .recording:        name = "mic.circle.fill"
        case .loading:          name = "arrow.down.circle"
        case .needsPermission:  name = "exclamationmark.triangle"
        }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "VoiceTyping")
        return img
    }

    // MARK: - Menu construction

    private func rebuildMenu() {
        menu.removeAllItems()

        if !state.accessibilityGranted {
            let item = NSMenuItem(title: "Grant Accessibility Permission…", action: #selector(grantAccessibility), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }
        if !state.microphoneGranted {
            let item = NSMenuItem(title: "Grant Microphone Permission…", action: #selector(grantMicrophone), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }

        if case let .loading(progress) = state.recognizerState {
            let title: String
            if progress < 0 {
                title = "Preparing \(state.asrBackend.displayName)…"
            } else {
                title = String(format: "Preparing %@… %d%%", state.asrBackend.displayName, Int(progress * 100))
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }
        if case let .failed(err) = state.recognizerState {
            let item = NSMenuItem(title: "Model load failed: \(err.localizedDescription)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        // Language submenu
        let langItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        langItem.submenu = buildLanguageMenu()
        menu.addItem(langItem)

        // Model (ASR backend) submenu
        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelItem.submenu = buildModelMenu()
        menu.addItem(modelItem)

        // Refinement submenu (4-mode picker only — Settings moved out to top level)
        let llmItem = NSMenuItem(
            title: "Refinement · \(state.refineMode.displayName)",
            action: nil,
            keyEquivalent: ""
        )
        llmItem.submenu = buildLLMMenu()
        menu.addItem(llmItem)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(openSettingsDefault),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        // v0.6.0: Sparkle wires its own enabled-state on this item — it stays
        // disabled while a check is in flight, and gets re-enabled when the
        // updater is idle. `target` is the SPUStandardUpdaterController itself.
        let checkUpdates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkUpdates.target = updaterController
        menu.addItem(checkUpdates)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About VoiceTyping", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit VoiceTyping", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func buildLanguageMenu() -> NSMenu {
        let m = NSMenu()
        for lang in Language.allCases {
            let item = NSMenuItem(title: lang.displayName,
                                  action: #selector(selectLanguage(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = lang
            item.state = (lang == state.language) ? .on : .off
            m.addItem(item)
        }
        return m
    }

    private func buildModelMenu() -> NSMenu {
        let m = NSMenu()

        for backend in ASRBackend.allCases {
            let title = modelMenuTitle(for: backend)
            let item = NSMenuItem(title: title,
                                  action: #selector(selectASRBackend(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = backend
            item.state = (backend == state.asrBackend) ? .on : .off
            m.addItem(item)
        }

        m.addItem(.separator())

        let manage = NSMenuItem(title: "Manage Models…",
                                action: #selector(openManageModels),
                                keyEquivalent: "")
        manage.target = self
        m.addItem(manage)

        return m
    }

    /// "Qwen3-ASR 1.7B · ~1.4 GB · Downloaded" etc.
    private func modelMenuTitle(for backend: ASRBackend) -> String {
        let name = backend.displayName
        let status: String

        if backend == state.asrBackend {
            if case let .loading(progress) = state.recognizerState, progress >= 0 {
                status = String(format: "Downloading %d%%", Int(progress * 100))
            } else if case .loading = state.recognizerState {
                status = "Loading…"
            } else if case .ready = state.recognizerState {
                status = "Active"
            } else if case .failed = state.recognizerState {
                status = "Failed"
            } else {
                status = "Active"
            }
        } else if ModelStore.isDownloaded(backend) {
            status = "Downloaded"
        } else {
            status = "Not downloaded"
        }

        return "\(name) · \(backend.estimatedSizeLabel) · \(status)"
    }

    private func buildLLMMenu() -> NSMenu {
        let m = NSMenu()
        for mode in RefineMode.allCases {
            let item = NSMenuItem(title: mode.displayName,
                                  action: #selector(selectRefineMode(_:)),
                                  keyEquivalent: "")
            item.representedObject = mode
            item.target = self
            item.state = (mode == state.refineMode) ? .on : .off
            item.toolTip = mode.shortDescription
            m.addItem(item)
        }
        return m
    }

    // MARK: - Actions

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let lang = sender.representedObject as? Language else { return }
        onLanguageSelected?(lang)
    }

    @objc private func selectASRBackend(_ sender: NSMenuItem) {
        guard let backend = sender.representedObject as? ASRBackend else { return }
        onASRBackendSelected?(backend)
    }

    @objc private func openManageModels() {
        openSettings(tab: .models)
    }

    @objc private func selectRefineMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? RefineMode else { return }
        onRefineModeSelected?(mode)
    }

    @objc private func openSettingsDefault() {
        openSettings(tab: .models)
    }

    func openSettings(tab: SettingsTab) {
        onOpenSettings?()
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                state: state,
                onRequestReloadBackend: { [weak self] backend in
                    self?.onASRBackendSelected?(backend)
                }
            )
        }
        settingsWindowController?.show(tab: tab)
    }

    @objc private func grantAccessibility() {
        onGrantAccessibility?()
    }

    @objc private func grantMicrophone() {
        onGrantMicrophone?()
    }

    @objc private func showAbout() {
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        onQuit?()
    }
}

extension StatusItemController: NSMenuDelegate {
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in self.rebuildMenu() }
    }
}
