import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable, Hashable, Identifiable {
    case models
    case llm
    case dictionary
    case profiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .models:     return "Models"
        case .llm:        return "LLM"
        case .dictionary: return "Dictionary"
        case .profiles:   return "Profiles"
        }
    }

    var systemImage: String {
        switch self {
        case .models:     return "waveform"
        case .llm:        return "sparkles"
        case .dictionary: return "character.book.closed"
        case .profiles:   return "text.bubble"
        }
    }
}

// MARK: - Dimensions

/// Keep sizes in one place so the NSWindow content rect and the SwiftUI frame
/// stay consistent. The outer window is larger than the panel so the glass
/// shadow has transparent space to spread into.
private enum Panel {
    static let width: CGFloat = 760
    static let height: CGFloat = 600
    static let cornerRadius: CGFloat = 28
    /// Breathing room around the panel for the soft shadow.
    static let shadowMargin: CGFloat = 28
}

// Palette pulled verbatim from the Liquid Glass design handoff. Every text
// style that's explicit in the CSS (--text-*, --text-chip-*, etc.) has a
// matching constant here so the Swift UI doesn't drift into SwiftUI's
// `.primary` / `.secondary` defaults (which skew grey, not cool-white).
private enum LG {
    // Text — by role
    static let text       = Color.white                                         // #ffffff
    static let textDim    = Color(red: 0xE9/255, green: 0xEB/255, blue: 0xF4/255) // #e9ebf4
    static let textFaint  = Color(red: 0xB9/255, green: 0xBC/255, blue: 0xCB/255) // #b9bccb
    static let textDark   = Color(red: 0x15/255, green: 0x15/255, blue: 0x1B/255) // #15151b
    static let chipVal    = Color(red: 177/255, green: 134/255, blue: 93/255)     // #B1865D
    static let chipMute   = Color(red: 120/255, green: 214/255, blue: 226/255)    // #78D6E2

    // States
    static let activeBg   = Color(red: 0x6A/255, green: 0xF0/255, blue: 0xA5/255) // #6af0a5
    static let activeBgHi = Color(red: 0x9C/255, green: 0xFB/255, blue: 0xC4/255)
    static let activeText = Color(red: 0x0C/255, green: 0x23/255, blue: 0x13/255) // #0c2313
    static let rowSelBg   = Color(red: 0x7A/255, green: 0xA0/255, blue: 0xFF/255) // #7aa0ff
}

/// The design's `.fx` class applies a 3-layer text-shadow to every character
/// — a crisp 1px dark outline plus two soft drops. Reduced here to a 2-layer
/// stack which reads cleanly at macOS rendering without the CSS's "crunch".
private extension View {
    func fx() -> some View {
        self
            .shadow(color: .black.opacity(0.55), radius: 1, x: 0, y: 1)
            .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
    }
    /// Inverse — a light halo for dark text sitting on a bright pill.
    func fxDark() -> some View {
        self.shadow(color: .white.opacity(0.7), radius: 1, x: 0, y: 1)
    }
}

// MARK: - Window controller

@MainActor
final class SettingsWindowController {

    private let state: AppState
    private var window: NSWindow?
    private let onRequestReloadBackend: (ASRBackend) -> Void

    init(state: AppState, onRequestReloadBackend: @escaping (ASRBackend) -> Void) {
        self.state = state
        self.onRequestReloadBackend = onRequestReloadBackend
    }

    func show(tab: SettingsTab = .models) {
        if let w = window {
            (w.contentViewController as? NSHostingController<SettingsView>)?.rootView.selectedTab = tab
            w.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(
            state: state,
            selectedTab: tab,
            onClose: { [weak self] in self?.window?.close() },
            onRequestReloadBackend: onRequestReloadBackend
        )

        let host = NSHostingController(rootView: view)
        // Hosting view must be fully transparent — any opaque backing will
        // render as a visible rectangle outside our rounded glass panel.
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor

        // The window is larger than the visible glass panel by `shadowMargin`
        // on each side. The SwiftUI root centers the panel inside this area;
        // the surrounding transparent padding is where the Liquid Glass
        // shadow bleeds into.
        let outerWidth  = Panel.width  + Panel.shadowMargin * 2
        let outerHeight = Panel.height + Panel.shadowMargin * 2
        let w = BorderlessKeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: outerWidth, height: outerHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.contentViewController = host
        w.isOpaque = false
        w.backgroundColor = .clear
        // NSWindow's built-in shadow is always rectangular (follows the
        // window's frame, not the content's shape). Suppress it and let
        // SwiftUI's .shadow() modifier follow the rounded panel.
        w.hasShadow = false
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.fullScreenAuxiliary]
        w.contentView?.wantsLayer = true
        w.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        w.center()

        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

/// Borderless windows don't become key by default; override so textfields focus
/// and keyboard shortcuts (Escape → Done, Return → Save) still work.
private final class BorderlessKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Root SwiftUI view

private struct SettingsView: View {
    @ObservedObject var state: AppState
    @State var selectedTab: SettingsTab
    let onClose: () -> Void
    let onRequestReloadBackend: (ASRBackend) -> Void

    var body: some View {
        // The glass panel is placed in a ZStack so it sits inside a larger
        // transparent area where its shadow can bleed.
        ZStack {
            Color.clear
            panel
        }
        .frame(
            width:  Panel.width  + Panel.shadowMargin * 2,
            height: Panel.height + Panel.shadowMargin * 2
        )
    }

    @ViewBuilder
    private var panel: some View {
        panelContent
            .frame(width: Panel.width, height: Panel.height)
            .panelSurface(cornerRadius: Panel.cornerRadius)
            // Top specular + bottom refraction rim echoing the Liquid Glass
            // design's ::before / ::after pseudo-elements.
            .overlay(
                RoundedRectangle(cornerRadius: Panel.cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.45),
                                Color.white.opacity(0.08),
                                Color.white.opacity(0.14),
                            ],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 14)
            .shadow(color: .black.opacity(0.25), radius: 6,  x: 0, y: 2)
    }

    private var panelContent: some View {
        VStack(spacing: 16) {
            TabPills(selected: $selectedTab)
                .padding(.top, 18)

            Group {
                switch selectedTab {
                case .models:
                    ModelsTab(state: state, onRequestReloadBackend: onRequestReloadBackend)
                case .llm:
                    LLMTab(state: state)
                case .dictionary:
                    DictionaryTab(state: state)
                case .profiles:
                    ProfilesTab(state: state)
                }
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            HStack {
                Spacer()
                DoneButton(action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 16)
        }
    }
}

// MARK: - Liquid Glass helpers

private extension View {
    /// macOS 26+ gets the real Liquid Glass treatment; older macOS falls back
    /// to ultraThinMaterial + a hairline stroke.
    @ViewBuilder
    func panelSurface(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            )
        }
    }
}

/// Done is the single emphasized control — dark-glass pill with white text,
/// matching the design's `.btn.dark` footer button. Return/Escape still fire it.
private struct DoneButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Done")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LG.text)
                .fx()
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(
                    LinearGradient(
                        colors: [Color.black.opacity(0.55), Color.black.opacity(0.35)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.35), Color.white.opacity(0.08)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                )
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tab pills

private struct TabPills: View {
    @Binding var selected: SettingsTab

    var body: some View {
        HStack(spacing: 14) {
            ForEach(SettingsTab.allCases) { tab in
                pill(for: tab)
            }
        }
        .padding(5)
        // Matches the design's .tabs: dark-tinted glass with a white→white-fade
        // gradient on top and an inset highlight ring. One container, not
        // one-per-pill — unselected pills read as text on this glass.
        .background(
            ZStack {
                Capsule().fill(Color.black.opacity(0.22))
                Capsule().fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.22), Color.white.opacity(0.06)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
        )
        .overlay(
            Capsule().strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.50), Color.white.opacity(0.14)],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            )
        )
        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
    }

    @ViewBuilder
    private func pill(for tab: SettingsTab) -> some View {
        let isSelected = selected == tab
        Button {
            selected = tab
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tab.systemImage)
                    .imageScale(.small)
                    .font(.system(size: 13, weight: .semibold))
                Text(tab.title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(isSelected ? LG.textDark : LG.text)
            .modifier(TabLabelShadow(selected: isSelected))
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(selectedBackground.opacity(isSelected ? 1 : 0))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Selected pill backing — bright white gradient capsule with a crisp
    /// inner ring and a soft drop, matching `.tab[aria-selected="true"]`.
    private var selectedBackground: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [Color.white.opacity(0.95), Color(white: 0.92, opacity: 0.88)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.95), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
    }
}

/// Selected = inverse (light halo on dark text); unselected = stroke on light text.
private struct TabLabelShadow: ViewModifier {
    let selected: Bool
    func body(content: Content) -> some View {
        if selected {
            content.fxDark()
        } else {
            content.fx()
        }
    }
}

// MARK: - Reusable card + labeled field

/// A grouped subsection inside the glass panel. Uses a tinted color fill rather
/// than another glass layer — nested glass doesn't sample cleanly (per the
/// Liquid Glass HIG: glass cannot sample other glass without
/// GlassEffectContainer grouping).
private struct SectionCard<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(LG.text)
                    .fx()
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.10), Color.white.opacity(0.03)],
                startPoint: .top, endPoint: .bottom
            ),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.35), Color.white.opacity(0.08)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

/// Segmented-looking selector for RefineMode that matches the neutral tab
/// pill aesthetic (no accent tint). Equal-width items; selected uses thick
/// material, unselected uses interactive regular glass.
private struct RefineModeSegmented: View {
    @Binding var selected: RefineMode

    var body: some View {
        HStack(spacing: 10) {
            ForEach(RefineMode.allCases) { mode in
                let isSelected = selected == mode
                Button {
                    selected = mode
                } label: {
                    Text(mode.displayName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(isSelected ? LG.textDark : LG.text)
                        .modifier(TabLabelShadow(selected: isSelected))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity)
                        .background(segBackground(selected: isSelected))
                        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func segBackground(selected: Bool) -> some View {
        if selected {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.92), Color(white: 0.92, opacity: 0.82)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.9), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
        } else {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.22), Color.white.opacity(0.06)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                )
        }
    }
}

/// Two-row labeled field (label above, control below) — avoids macOS's
/// `LabeledContent`-inside-`Form` rendering a ghost prompt column next to the
/// label, which looked like a duplicated URL in v0.3 pre-release.
private struct LabeledField<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LG.text)
                .fx()
            content()
        }
    }
}

// MARK: - Models tab

private struct ModelsTab: View {
    @ObservedObject var state: AppState
    let onRequestReloadBackend: (ASRBackend) -> Void

    @State private var pendingDelete: ASRBackend?

    var body: some View {
        VStack(spacing: 14) {
            SectionCard(title: "Speech Recognition Model") {
                VStack(spacing: 0) {
                    ForEach(ASRBackend.allCases) { backend in
                        ModelRow(
                            backend: backend,
                            state: state,
                            onSelect: { onRequestReloadBackend(backend) },
                            onDelete: { pendingDelete = backend }
                        )
                        .id(state.modelInventoryTick)
                        if backend != ASRBackend.allCases.last {
                            Divider().opacity(0.25)
                        }
                    }
                }

                Text("Downloads are cached under `~/Library/Application Support/VoiceTyping/models/` and kept until you delete them.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(LG.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("Delete \(pendingDelete?.displayName ?? "") files?",
               isPresented: .init(
                   get: { pendingDelete != nil },
                   set: { if !$0 { pendingDelete = nil } }
               ),
               presenting: pendingDelete) { backend in
            Button("Delete", role: .destructive) {
                performDelete(backend)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { backend in
            if backend == state.asrBackend {
                Text("This is the currently active model. Deleting unloads it; you'll need to switch to another model or re-download.")
            } else {
                Text("\(backend.estimatedSizeLabel) of weights will be removed. You can re-download later.")
            }
        }
    }

    private func performDelete(_ backend: ASRBackend) {
        do {
            try ModelStore.delete(backend)
            Log.app.info("Deleted model files for \(backend.rawValue, privacy: .public)")
            if backend == state.asrBackend {
                onRequestReloadBackend(backend)
            }
            state.modelInventoryTick &+= 1
        } catch {
            Log.app.error("Delete failed for \(backend.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

private struct ModelRow: View {
    let backend: ASRBackend
    @ObservedObject var state: AppState
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(backend.displayName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(LG.text)
                        .fx()
                    if backend == state.asrBackend {
                        Text("ACTIVE")
                            .font(.system(size: 10, weight: .heavy))
                            .tracking(1.2)
                            .foregroundStyle(LG.activeText)
                            .fxDark()
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                LinearGradient(
                                    colors: [LG.activeBgHi, LG.activeBg],
                                    startPoint: .top, endPoint: .bottom
                                ),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.white.opacity(0.6), lineWidth: 0.5)
                            )
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                    }
                }
                Text(statusLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LG.textFaint)
            }

            Spacer()

            if backend == state.asrBackend, case let .loading(p) = state.recognizerState, p >= 0 {
                ProgressView(value: p).frame(width: 80)
            }

            Button(actionLabel) { onSelect() }
                .disabled(backend == state.asrBackend && stateIsActive)

            Button(role: .destructive) { onDelete() } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!ModelStore.isDownloaded(backend))
            .help(ModelStore.isDownloaded(backend) ? "Delete files" : "Not downloaded")
        }
        .padding(.vertical, 8)
    }

    private var stateIsActive: Bool {
        if case .ready = state.recognizerState { return true }
        return false
    }

    private var statusLabel: String {
        if backend == state.asrBackend {
            switch state.recognizerState {
            case .ready:           return "Active · \(sizeOrEstimate())"
            case .loading(let p):
                if p < 0 { return "Loading…" }
                return String(format: "Downloading %d%%", Int(p * 100))
            case .failed(let err): return "Failed — \(err.localizedDescription)"
            case .unloaded:        return "Preparing…"
            }
        }
        return ModelStore.isDownloaded(backend)
            ? "Downloaded · \(sizeOrEstimate())"
            : "Not downloaded · \(backend.estimatedSizeLabel) to download"
    }

    private var actionLabel: String {
        if backend == state.asrBackend { return "Active" }
        return ModelStore.isDownloaded(backend) ? "Switch" : "Download & Switch"
    }

    private func sizeOrEstimate() -> String {
        let onDisk = ModelStore.sizeOnDisk(backend)
        return onDisk > 1_000_000 ? onDisk.humanReadableBytes : backend.estimatedSizeLabel
    }
}

// MARK: - LLM tab

private struct LLMTab: View {
    @ObservedObject var state: AppState

    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var model: String = ""
    @State private var showAPIKey: Bool = false
    @State private var testStatus: TestStatus = .idle

    enum TestStatus: Equatable {
        case idle, running
        case ok(String)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 14) {

            SectionCard(title: "Refinement") {
                // Custom segmented selector — the system `.segmented` picker
                // renders the selected option in accent blue which conflicts
                // with the "no tint" direction. Reuses the same neutral
                // material-vs-glass treatment as the top tab pills.
                RefineModeSegmented(selected: $state.refineMode)

                Text(state.refineMode.shortDescription)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(LG.textDim)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: $state.rawFirstEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Paste raw first, refine in background")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(LG.text)
                            .fx()
                        Text("Lower perceived latency. Avoid in chat apps that auto-send on Enter.")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(LG.textDim)
                    }
                }
                .disabled(state.refineMode == .off)
                .padding(.top, 2)
            }

            SectionCard(title: "API") {
                LabeledField(title: "Base URL") {
                    TextField("https://api.openai.com/v1", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledField(title: "API Key") {
                    HStack(spacing: 6) {
                        Group {
                            if showAPIKey {
                                TextField("sk-…", text: $apiKey)
                            } else {
                                SecureField("sk-…", text: $apiKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)

                        Button {
                            showAPIKey.toggle()
                        } label: {
                            Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(showAPIKey ? "Hide API key" : "Show API key")

                        Button {
                            apiKey = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Clear API key")
                        .disabled(apiKey.isEmpty)
                    }
                }

                LabeledField(title: "Model") {
                    TextField("gpt-4o-mini", text: $model)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    testStatusView
                    Spacer()
                    Button("Test") { runTest() }
                        .disabled(!canTest || testStatus == .running)
                    Button("Save") { save() }
                        .keyboardShortcut(.return)
                }
            }
        }
        .onAppear { loadCurrent() }
    }

    private var testStatusView: some View {
        Group {
            switch testStatus {
            case .idle:
                Text("")
            case .running:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Testing…").foregroundStyle(.secondary)
                }
            case .ok(let reply):
                Label("OK — \(reply.prefix(40))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .lineLimit(1)
            case .failed(let msg):
                Label("Failed — \(msg)", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .font(.caption)
    }

    private var canTest: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty &&
        !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func loadCurrent() {
        baseURL = state.llmConfig.baseURL
        apiKey  = state.llmConfig.apiKey
        model   = state.llmConfig.model
    }

    private func save() {
        var cfg = state.llmConfig
        cfg.baseURL = baseURL.trimmingCharacters(in: .whitespaces)
        cfg.apiKey  = apiKey
        cfg.model   = model.trimmingCharacters(in: .whitespaces)
        state.llmConfig = cfg
    }

    private func runTest() {
        testStatus = .running
        var cfg = state.llmConfig
        cfg.baseURL = baseURL
        cfg.apiKey  = apiKey
        cfg.model   = model
        let refiner = LLMRefiner()
        Task {
            let result = await refiner.test(config: cfg)
            await MainActor.run {
                switch result {
                case .ok(let reply):
                    testStatus = .ok(reply.trimmingCharacters(in: .whitespacesAndNewlines))
                case .failed(let msg):
                    testStatus = .failed(msg)
                }
            }
        }
    }
}

// MARK: - Dictionary tab

private struct DictionaryTab: View {
    @ObservedObject var state: AppState

    @State private var showingAddDialog = false
    @State private var draftTerm: String = ""
    @State private var draftHints: String = ""
    @State private var draftNote: String = ""
    @State private var editingID: UUID?
    @State private var pendingDeleteIDs: Set<UUID> = []
    @State private var selection: Set<UUID> = []

    private var selectedEntry: DictionaryEntry? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return state.dictionary.entries.first { $0.id == id }
    }

    private var selectedEntries: [DictionaryEntry] {
        state.dictionary.entries.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 14) {
            SectionCard(title: "Custom Vocabulary") {
                Text("Terms injected into ASR and the LLM refiner so your jargon, names, and product terms survive transcription. What gets injected each call depends on recency and the backend's token budget.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(LG.textDim)
                    .fixedSize(horizontal: false, vertical: true)

                injectionStatus

                Table(state.dictionary.entries, selection: $selection) {
                    TableColumn("Term") { entry in
                        Text(entry.term)
                            .font(.body)
                    }
                    .width(min: 120, ideal: 160)

                    TableColumn("Pronunciation hints") { entry in
                        Text(entry.pronunciationHints.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 160, ideal: 220)

                    TableColumn("Note") { entry in
                        Text(entry.note ?? "")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .width(min: 80, ideal: 160)
                }
                .id(state.dictionaryTick)
                .frame(minHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if ids.count == 1, let id = ids.first,
                       let entry = state.dictionary.entries.first(where: { $0.id == id }) {
                        Button("Edit…") { beginEdit(entry) }
                    }
                    if !ids.isEmpty {
                        Button("Delete", role: .destructive) {
                            pendingDeleteIDs = ids
                        }
                    }
                } primaryAction: { ids in
                    if let id = ids.first,
                       let entry = state.dictionary.entries.first(where: { $0.id == id }) {
                        beginEdit(entry)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        clearDraft()
                        showingAddDialog = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }

                    Button {
                        if let entry = selectedEntry { beginEdit(entry) }
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .disabled(selection.count != 1)

                    Button(role: .destructive) {
                        pendingDeleteIDs = selection
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(selection.isEmpty)

                    Divider().frame(height: 16)

                    Button { importFromFile() } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }

                    Button { exportToFile() } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(state.dictionary.entries.isEmpty)

                    Spacer()

                    Text(String(format: "%d / %d entries", state.dictionary.entries.count, CustomDictionary.softEntryCap))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LG.textFaint)
                }
            }
        }
        .sheet(isPresented: $showingAddDialog) {
            editorSheet
        }
        .alert(deleteAlertTitle,
               isPresented: .init(
                   get: { !pendingDeleteIDs.isEmpty },
                   set: { if !$0 { pendingDeleteIDs = [] } }
               ),
               presenting: pendingDeleteIDs.isEmpty ? nil : pendingDeleteIDs) { ids in
            Button("Delete", role: .destructive) {
                for id in ids { state.removeDictionaryEntry(id: id) }
                selection.subtract(ids)
                pendingDeleteIDs = []
            }
            Button("Cancel", role: .cancel) { pendingDeleteIDs = [] }
        } message: { _ in
            Text("This only removes the entry locally. You can re-add it later.")
        }
    }

    private var deleteAlertTitle: String {
        pendingDeleteIDs.count > 1
            ? "Delete \(pendingDeleteIDs.count) entries?"
            : "Delete this entry?"
    }

    // MARK: Injection status

    private var injectionStatus: some View {
        let entries = state.dictionary.entries
        let qwen    = GlossaryBuilder.qwenReport(from: entries)
        let whisper = GlossaryBuilder.whisperReport(from: entries)
        let llm     = GlossaryBuilder.llmReport(from: entries)

        return HStack(spacing: 10) {
            statusPill(title: "Qwen", report: qwen)
            statusPill(title: "Whisper", report: whisper)
            statusPill(title: "LLM", report: llm)
            Spacer()
        }
    }

    private func statusPill(title: String, report: GlossaryBuilder.InjectionReport) -> some View {
        let pct = report.budget > 0 ? Double(report.tokens) / Double(report.budget) : 0
        let tight = pct > 0.85
        return HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LG.text)
                .fx()
            Text("\(report.injected)/\(report.total)")
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(LG.text)
                .fx()
            Circle()
                .fill(Color.white.opacity(0.5))
                .frame(width: 4, height: 4)
            // Tokens (warm tan) / budget + "t" suffix (cool cyan). When we're
            // tight on budget, the token count flips to orange to flag it.
            (
                Text("\(report.tokens)")
                    .foregroundStyle(tight ? .orange : LG.chipVal)
                +
                Text("/\(report.budget)t")
                    .foregroundStyle(LG.chipMute)
            )
            .font(.system(size: 11.5, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.22), Color.white.opacity(0.06)],
                startPoint: .top, endPoint: .bottom
            ),
            in: Capsule()
        )
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
    }

    // MARK: Editor sheet

    private var editorSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editingID == nil ? "Add Vocabulary Entry" : "Edit Vocabulary Entry")
                .font(.headline)

            LabeledField(title: "Term") {
                TextField("e.g. Python, Kubernetes, Qwen3-ASR", text: $draftTerm)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledField(title: "Pronunciation hints (comma-separated)") {
                TextField("配森, 派森", text: $draftHints)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledField(title: "Note (optional)") {
                TextField("your own reminder, not shown to the model", text: $draftNote)
                    .textFieldStyle(.roundedBorder)
            }

            Text("The term is the canonical spelling. Hints are how you pronounce it — they bias ASR and help the LLM map variants back to the term.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { showingAddDialog = false }
                    .keyboardShortcut(.cancelAction)
                Button(editingID == nil ? "Add" : "Save") { commitEdit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draftTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func clearDraft() {
        draftTerm = ""
        draftHints = ""
        draftNote = ""
        editingID = nil
    }

    private func beginEdit(_ entry: DictionaryEntry) {
        draftTerm = entry.term
        draftHints = entry.pronunciationHints.joined(separator: ", ")
        draftNote = entry.note ?? ""
        editingID = entry.id
        showingAddDialog = true
    }

    private func commitEdit() {
        let term = draftTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        let hints = draftHints
            .split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let note = draftNote.trimmingCharacters(in: .whitespacesAndNewlines)

        // Preserve createdAt / lastMatchedAt when editing so LRU ranking survives.
        let existing = editingID.flatMap { id in
            state.dictionary.entries.first { $0.id == id }
        }
        let entry = DictionaryEntry(
            id: editingID ?? UUID(),
            term: term,
            pronunciationHints: hints,
            note: note.isEmpty ? nil : note,
            createdAt: existing?.createdAt ?? Date(),
            lastMatchedAt: existing?.lastMatchedAt
        )
        _ = state.upsertDictionaryEntry(entry)
        showingAddDialog = false
    }

    // MARK: Import / Export

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a dictionary JSON file to import."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                try state.dictionary.importJSON(data)
                state.dictionaryTick &+= 1
            } catch {
                Log.app.warning("Dictionary import failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func exportToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "voicetyping-dictionary.json"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try state.dictionary.exportJSON()
                try data.write(to: url, options: .atomic)
            } catch {
                Log.app.warning("Dictionary export failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Profiles tab

private struct ProfilesTab: View {
    @ObservedObject var state: AppState

    @State private var showingEditor = false
    @State private var editingID: UUID?
    @State private var draftName: String = ""
    @State private var draftBundleID: String = ""
    @State private var draftSnippet: String = ""
    @State private var draftEnabled: Bool = true
    @State private var pendingDeleteIDs: Set<UUID> = []
    @State private var selection: Set<UUID> = []

    private var profiles: [ContextProfile] { state.profiles.profiles }

    private var selectedProfile: ContextProfile? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return profiles.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 14) {
            SectionCard(title: "Per-App Context Profiles") {
                Text("Pick an app and add a system prompt snippet. When that app is frontmost at dictation time, the snippet is appended to the refiner's base prompt — before your vocabulary glossary — so the LLM adapts its style (casual for chat, terse for editors, etc). The refiner must be on; profiles never force it back on.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(LG.textDim)
                    .fixedSize(horizontal: false, vertical: true)

                Table(profiles, selection: $selection) {
                    TableColumn("App") { profile in
                        HStack(spacing: 8) {
                            Image(nsImage: ProfilesTab.icon(for: profile.bundleID))
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 18, height: 18)
                            Text(profile.name)
                                .font(.body)
                                .foregroundStyle(profile.enabled ? .primary : .secondary)
                        }
                    }
                    .width(min: 140, ideal: 180)

                    TableColumn("Snippet") { profile in
                        Text(profile.systemPromptSnippet)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .width(min: 180, ideal: 280)

                    TableColumn("Enabled") { profile in
                        Toggle("", isOn: Binding(
                            get: { profile.enabled },
                            set: { toggleEnabled(profile, to: $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    .width(70)
                }
                .id(state.profilesTick)
                .frame(minHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if ids.count == 1, let id = ids.first,
                       let profile = profiles.first(where: { $0.id == id }) {
                        Button("Edit…") { beginEdit(profile) }
                    }
                    if !ids.isEmpty {
                        Button("Delete", role: .destructive) {
                            pendingDeleteIDs = ids
                        }
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let profile = profiles.first(where: { $0.id == id }) {
                        beginEdit(profile)
                    }
                }

                HStack(spacing: 8) {
                    Button { pickAppFromDisk() } label: {
                        Label("Add…", systemImage: "plus")
                    }

                    Button { addFrontmostApp() } label: {
                        Label("Add frontmost app", systemImage: "rectangle.inset.filled.and.person.filled")
                    }

                    Button {
                        if let p = selectedProfile { beginEdit(p) }
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .disabled(selection.count != 1)

                    Button(role: .destructive) {
                        pendingDeleteIDs = selection
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(selection.isEmpty)

                    Divider().frame(height: 16)

                    Button { importFromFile() } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }

                    Button { exportToFile() } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(profiles.isEmpty)

                    Spacer()

                    Text(String(format: "%d / %d profiles", profiles.count, ContextProfileStore.softCap))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LG.textFaint)
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            editorSheet
        }
        .alert(deleteAlertTitle,
               isPresented: .init(
                   get: { !pendingDeleteIDs.isEmpty },
                   set: { if !$0 { pendingDeleteIDs = [] } }
               ),
               presenting: pendingDeleteIDs.isEmpty ? nil : pendingDeleteIDs) { ids in
            Button("Delete", role: .destructive) {
                for id in ids { state.removeProfile(id: id) }
                selection.subtract(ids)
                pendingDeleteIDs = []
            }
            Button("Cancel", role: .cancel) { pendingDeleteIDs = [] }
        } message: { _ in
            Text("Removes the profile locally; the app itself is untouched.")
        }
    }

    private var deleteAlertTitle: String {
        pendingDeleteIDs.count > 1
            ? "Delete \(pendingDeleteIDs.count) profiles?"
            : "Delete this profile?"
    }

    // MARK: Editor sheet

    private var editorSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: ProfilesTab.icon(for: draftBundleID))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(editingID == nil ? "New Profile" : "Edit Profile")
                        .font(.headline)
                    Text(draftName.isEmpty ? "(unnamed)" : draftName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            LabeledField(title: "System prompt snippet") {
                TextEditor(text: $draftSnippet)
                    .font(.system(size: 13))
                    .frame(minHeight: 120, maxHeight: 220)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(white: 0, opacity: 0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                    )
            }

            LabeledField(title: "Display name") {
                TextField("e.g. Slack", text: $draftName)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle("Enabled", isOn: $draftEnabled)

            Text("Appended to the refiner's base system prompt. Keep it short and imperative — e.g. \"Prefer casual tone; allow contractions and informal phrasing.\"")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Matches bundle \(draftBundleID.isEmpty ? "(none)" : draftBundleID)")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { showingEditor = false }
                    .keyboardShortcut(.cancelAction)
                Button(editingID == nil ? "Add" : "Save") { commitEdit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        draftBundleID.trimmingCharacters(in: .whitespaces).isEmpty ||
                        draftSnippet.trimmingCharacters(in: .whitespaces).isEmpty
                    )
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    // MARK: Actions

    private func toggleEnabled(_ profile: ContextProfile, to newValue: Bool) {
        var p = profile
        p.enabled = newValue
        _ = state.upsertProfile(p)
    }

    private func beginEdit(_ profile: ContextProfile) {
        draftName = profile.name
        draftBundleID = profile.bundleID
        draftSnippet = profile.systemPromptSnippet
        draftEnabled = profile.enabled
        editingID = profile.id
        showingEditor = true
    }

    private func beginDraftForApp(url: URL) {
        let bundle = Bundle(url: url)
        guard let bid = bundle?.bundleIdentifier else {
            Log.app.warning("Add profile: no bundle identifier at \(url.path, privacy: .public)")
            return
        }
        // If a profile already exists for this bundleID, open it rather than
        // duplicating — upsert dedups by bundleID but editing the existing one
        // preserves id/createdAt and is less surprising to the user.
        if let existing = profiles.first(where: { $0.bundleID == bid }) {
            beginEdit(existing)
            return
        }
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
        draftName = name
        draftBundleID = bid
        draftSnippet = ""
        draftEnabled = true
        editingID = nil
        showingEditor = true
    }

    private func pickAppFromDisk() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Pick an app to create a context profile for."
        if panel.runModal() == .OK, let url = panel.url {
            beginDraftForApp(url: url)
        }
    }

    private func addFrontmostApp() {
        // Frontmost is "us" while the Settings window is key; walk through
        // running apps and grab the first non-VoiceTyping regular app ahead of
        // us in activation order. Same heuristic the dictation pipeline uses
        // at stopRecording.
        let ours = Bundle.main.bundleIdentifier
        guard let front = NSWorkspace.shared.runningApplications.first(where: {
            $0.activationPolicy == .regular && $0.bundleIdentifier != ours
        }), let url = front.bundleURL else {
            Log.app.warning("Add frontmost app: no eligible running app found")
            return
        }
        beginDraftForApp(url: url)
    }

    private func commitEdit() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bid = draftBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = draftSnippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bid.isEmpty, !snippet.isEmpty else { return }

        let existing = editingID.flatMap { id in profiles.first(where: { $0.id == id }) }
        let profile = ContextProfile(
            id: editingID ?? UUID(),
            name: name.isEmpty ? bid : name,
            bundleID: bid,
            systemPromptSnippet: snippet,
            enabled: draftEnabled,
            createdAt: existing?.createdAt ?? Date()
        )
        _ = state.upsertProfile(profile)
        showingEditor = false
    }

    // MARK: Import / Export

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a profiles JSON file to import."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                try state.profiles.importJSON(data)
                state.profilesTick &+= 1
            } catch {
                Log.app.warning("Profiles import failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func exportToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "voicetyping-profiles.json"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try state.profiles.exportJSON()
                try data.write(to: url, options: .atomic)
            } catch {
                Log.app.warning("Profiles export failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Helpers

    /// Live-resolve an app icon by bundle ID. If the bundle isn't installed,
    /// return the generic application icon so the row still has something to
    /// anchor the label against.
    static func icon(for bundleID: String) -> NSImage {
        if !bundleID.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }
}
