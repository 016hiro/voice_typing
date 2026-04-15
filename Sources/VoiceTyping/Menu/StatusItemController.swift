import AppKit
import Combine

@MainActor
final class StatusItemController: NSObject {

    private let state: AppState
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []

    private var settingsWindowController: SettingsWindowController?

    // Delegate-style callbacks wired by AppDelegate
    var onLanguageSelected: ((Language) -> Void)?
    var onLLMEnabledChanged: ((Bool) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onGrantAccessibility: (() -> Void)?
    var onGrantMicrophone: (() -> Void)?
    var onQuit: (() -> Void)?

    init(state: AppState) {
        self.state = state
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

        state.$recognizerState.sink { [weak self] _ in
            self?.updateIcon()
            self?.rebuildMenu()
        }.store(in: &cancellables)

        state.$accessibilityGranted.sink { [weak self] _ in
            self?.updateIcon()
            self?.rebuildMenu()
        }.store(in: &cancellables)
    }

    // MARK: - Icon

    enum IconState { case idle, recording, loading, needsPermission }

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
                title = "Preparing model…"
            } else {
                title = String(format: "Preparing model… %d%%", Int(progress * 100))
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

        // LLM Refinement submenu
        let llmItem = NSMenuItem(title: "LLM Refinement", action: nil, keyEquivalent: "")
        llmItem.submenu = buildLLMMenu()
        menu.addItem(llmItem)

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

    private func buildLLMMenu() -> NSMenu {
        let m = NSMenu()
        let enableItem = NSMenuItem(title: state.llmConfig.enabled ? "✓ Enabled" : "Enabled",
                                    action: #selector(toggleLLM),
                                    keyEquivalent: "")
        enableItem.state = state.llmConfig.enabled ? .on : .off
        enableItem.target = self
        m.addItem(enableItem)

        m.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        m.addItem(settingsItem)

        return m
    }

    // MARK: - Actions

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let lang = sender.representedObject as? Language else { return }
        onLanguageSelected?(lang)
    }

    @objc private func toggleLLM() {
        onLLMEnabledChanged?(!state.llmConfig.enabled)
    }

    @objc private func openSettings() {
        onOpenSettings?()
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(state: state)
        }
        settingsWindowController?.show()
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
        // Refresh labels (Permissions may have changed while menu was inactive)
        Task { @MainActor in self.rebuildMenu() }
    }
}
