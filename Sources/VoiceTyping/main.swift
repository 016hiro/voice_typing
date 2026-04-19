import AppKit

MainActor.assumeIsolated {
    // v0.3.x → v0.4.0: move API key from UserDefaults plaintext to the
    // Keychain. Must run before `AppDelegate()` because the delegate owns
    // an `AppState` stored property whose initializer reads `llmConfig` —
    // if migration ran after, the in-memory struct would still have an
    // empty apiKey until an unrelated save triggered a reload.
    LLMConfigStore.migrateIfNeeded()

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar takeover
    app.run()
}
