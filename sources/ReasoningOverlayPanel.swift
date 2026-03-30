import AppKit
import SwiftUI

// MARK: - Constants

private enum OverlayDefaults {
    static let minWidth: CGFloat = 280
    static let maxWidth: CGFloat = 480
    static let minHeight: CGFloat = 200
    static let maxHeight: CGFloat = 600
    static let margin: CGFloat = 16
    static let widthFraction: CGFloat = 0.35
    static let heightFraction: CGFloat = 0.60
    static let cornerRadius: CGFloat = 10
    static let fadeDelay: TimeInterval = 5.0
    static let fadedAlpha: CGFloat = 0.7
}

// MARK: - Reasoning Overlay Hosting View

/// An in-window overlay that displays Claude Code's reasoning.
/// Added as a subview of iTermRootTerminalView (same pattern as VTSidebarHostingView).
/// SwiftUI buttons work because the view is part of the key window's view hierarchy.
@objc class ReasoningOverlayHostingView: NSView {

    // MARK: - Properties

    @objc let dataSource = ReasoningOverlayDataSource()
    @objc private(set) var isOverlayVisible: Bool = false

    private var hostingView: NSHostingView<ReasoningOverlayView>?
    private var visualEffectView: NSVisualEffectView?
    private var fadeTimer: Timer?
    private var dragOrigin: NSPoint?

    // MARK: - Init

    @objc override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: - Setup (follows VTSidebarHostingView pattern)

    private func setup() {
        wantsLayer = true
        // Transparent container — the SwiftUI view handles its own background + corner radius
        layer?.backgroundColor = NSColor.clear.cgColor

        // SwiftUI content (same pattern as VTSidebarHostingView line 24-33)
        let overlayView = ReasoningOverlayView(dataSource: dataSource)
        let hosting = NSHostingView(rootView: overlayView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        hostingView = hosting

        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Start hidden
        isHidden = true

        // Bottom-right anchoring via autoresizingMask (for the parent iTermRootTerminalView)
        autoresizingMask = [.minXMargin, .maxYMargin]
    }

    // MARK: - Public API

    @objc func toggle() {
        if isOverlayVisible { hideOverlay() } else { showOverlay() }
    }

    @objc func showOverlay() {
        isHidden = false
        isOverlayVisible = true
        alphaValue = 1.0
        repositionInSuperview()
        resetFadeTimer()
    }

    @objc func hideOverlay() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        isHidden = true
        isOverlayVisible = false
    }

    @objc func contentDidUpdate() {
        guard isOverlayVisible else { return }
        // Unfade if faded
        if alphaValue < 1.0 {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                alphaValue = 1.0
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    self.animator().alphaValue = 1.0
                }
            }
        }
        resetFadeTimer()
    }

    @objc func setTerminalBackgroundLuminance(_ luminance: CGFloat) {
        dataSource.setTerminalBackgroundLuminance(luminance)
        visualEffectView?.material = luminance < 0.5 ? .dark : .light
    }

    /// Recalculate frame based on superview bounds. Call after window resize.
    @objc func repositionInSuperview() {
        guard let sv = superview else { return }
        let bounds = sv.bounds

        // Leave room for title bar + tab bar at top (~40px)
        let titleBarHeight: CGFloat = 40
        let usableHeight = bounds.height - titleBarHeight - OverlayDefaults.margin * 2

        let width = clamp(bounds.width * OverlayDefaults.widthFraction,
                          min: OverlayDefaults.minWidth,
                          max: OverlayDefaults.maxWidth)
        let height = clamp(usableHeight,
                           min: OverlayDefaults.minHeight,
                           max: OverlayDefaults.maxHeight)

        // Bottom-right: x from right edge, y from bottom edge
        let x = bounds.width - width - OverlayDefaults.margin
        let y = OverlayDefaults.margin

        self.frame = NSRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - Auto-fade

    private func resetFadeTimer() {
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: OverlayDefaults.fadeDelay, repeats: false) { [weak self] _ in
            guard let self, self.isOverlayVisible else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                self.alphaValue = OverlayDefaults.fadedAlpha
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    self.animator().alphaValue = OverlayDefaults.fadedAlpha
                }
            }
        }
    }

    // Drag to move is handled via SwiftUI gesture on the header bar (future improvement)

    // MARK: - Helpers

    private func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, min), max)
    }
}
