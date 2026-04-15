import AppKit
import SwiftUI

final class CapsuleWindow: NSPanel {

    private let state: AppState
    private let effectView: NSVisualEffectView
    private var hostingView: NSHostingView<CapsuleView>!
    private var currentLevels: AsyncStream<Float>?
    private var lastContentSize: CGSize = CGSize(width: 220, height: 56)

    init(state: AppState) {
        self.state = state
        let effect = NSVisualEffectView()
        self.effectView = effect

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .statusBar
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.isMovable = false
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        // .hudWindow material ignores layer.cornerRadius cleanly — use a
        // stretchable rounded mask image so the blur is shaped to a true capsule.
        effect.maskImage = Self.capsuleMaskImage(radius: 28)

        self.contentView = effect

        buildHostingView()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Public show/hide

    func show(levels: AsyncStream<Float>?) {
        self.currentLevels = levels
        buildHostingView()

        state.capsuleVisible = true
        // Start from a reduced scale + alpha, then spring in.
        self.alphaValue = 0.0
        positionBottomCenter(size: lastContentSize)
        self.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
            self.animator().alphaValue = 1.0
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.orderOut(nil)
                self?.state.capsuleVisible = false
            }
        })
    }

    // MARK: - Layout

    private func buildHostingView() {
        if let old = hostingView {
            old.removeFromSuperview()
        }
        let host = NSHostingView(rootView: CapsuleView(state: state, levels: currentLevels, onSizeChange: { [weak self] size in
            self?.applyContentSize(size)
        }))
        host.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            host.topAnchor.constraint(equalTo: effectView.topAnchor),
            host.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])
        self.hostingView = host
    }

    private func applyContentSize(_ size: CGSize) {
        let w = max(160, min(560, size.width))
        let h = size.height > 0 ? size.height : 56
        let newSize = CGSize(width: w, height: h)
        if abs(newSize.width - lastContentSize.width) < 0.5 &&
           abs(newSize.height - lastContentSize.height) < 0.5 {
            return
        }
        lastContentSize = newSize
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.7, 0.3, 1.0)
            let origin = originForBottomCenter(size: newSize)
            self.animator().setFrame(NSRect(origin: origin, size: newSize), display: true)
        }
    }

    private func positionBottomCenter(size: CGSize) {
        let origin = originForBottomCenter(size: size)
        self.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func originForBottomCenter(size: CGSize) -> CGPoint {
        let frame = NSScreen.main?.visibleFrame ?? .zero
        let x = frame.midX - size.width / 2
        let y = frame.minY + 48
        return CGPoint(x: x, y: y)
    }

    private static func capsuleMaskImage(radius: CGFloat) -> NSImage {
        let edge = ceil(radius * 2 + 1)
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
