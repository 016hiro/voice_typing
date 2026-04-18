import AppKit
import SwiftUI

final class CapsuleWindow: NSPanel {

    private let state: AppState
    private let container: NSView
    private var hostingView: NSHostingView<CapsuleView>!
    private var currentLevels: AsyncStream<Float>?
    private var lastContentSize: CGSize = CGSize(width: 260, height: 60)

    init(state: AppState) {
        self.state = state
        let container = NSView()
        self.container = container

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .statusBar
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.isMovable = false
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false

        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor

        self.contentView = container

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
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.hostingView = host
    }

    private func applyContentSize(_ size: CGSize) {
        let w = max(200, min(640, size.width))
        let h = size.height > 0 ? size.height : 60
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

}
