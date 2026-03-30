import AppKit
import SwiftUI

// MARK: - Dashboard Hosting View

/// Full-frame primary view that replaces the terminal content area when dashboard mode is active.
/// Added to iTermRootTerminalView via setDashboardView:, toggled via setDashboardMode:.
/// Not an overlay — this IS the content view when active.
@objc class DashboardHostingView: NSView {

    // MARK: - Properties

    @objc weak var sidebarDataSource: VTSidebarDataSource?
    @objc weak var sidebarDelegate: VTSidebarDelegate?
    @objc var onResumeSession: ((NSString, NSString) -> Void)?  // (sessionId, projectPath)

    private var hostingView: NSHostingView<DashboardView>?

    // MARK: - Init

    @objc override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0x0C/255, green: 0x0E/255, blue: 0x14/255, alpha: 1.0).cgColor
        autoresizingMask = [.width, .height]
        isHidden = true
    }

    /// Must be called before entering dashboard mode to provide the data source.
    @objc func configure(dataSource: VTSidebarDataSource, delegate: VTSidebarDelegate?) {
        self.sidebarDataSource = dataSource
        self.sidebarDelegate = delegate

        let dashboardView = DashboardView(
            dataSource: dataSource,
            onSelectTab: { [weak self] tabId in
                self?.sidebarDelegate?.sidebarDidSelectTab(uniqueId: tabId)
                self?.exitDashboard()
            },
            onSelectAgent: { [weak self] agentName, tabId in
                self?.sidebarDelegate?.sidebarDidSelectAgent(name: agentName, inTab: tabId)
                self?.exitDashboard()
            },
            onResumeSession: { [weak self] sessionId, projectPath in
                self?.onResumeSession?(sessionId as NSString, projectPath as NSString)
                self?.exitDashboard()
            },
            onDismiss: { [weak self] in
                self?.exitDashboard()
            }
        )
        let hosting = NSHostingView(rootView: dashboardView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        hostingView = hosting

        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    // MARK: - Exit

    private func exitDashboard() {
        guard let rootView = superview as? NSView else { return }
        // Walk up to find the iTermRootTerminalView and toggle dashboard mode off
        // The setDashboardMode: method on iTermRootTerminalView handles hiding/showing
        if rootView.responds(to: NSSelectorFromString("setDashboardMode:")) {
            rootView.perform(NSSelectorFromString("setDashboardMode:"), with: NSNumber(value: false))
        }
    }

    // MARK: - Key handling

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            exitDashboard()
        } else {
            super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }
}
