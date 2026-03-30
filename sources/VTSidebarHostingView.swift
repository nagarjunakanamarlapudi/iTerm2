import SwiftUI
import AppKit

/// NSView that hosts the SwiftUI vertical tab sidebar.
/// Drop-in replacement for PSMTabBarControl when tab position is Left.
@objc class VTSidebarHostingView: NSView {
    private var hostingView: NSHostingView<VTVerticalTabSidebar>?
    @objc let dataSource = VTSidebarDataSource()

    @objc override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0x1C/255, green: 0x21/255, blue: 0x2A/255, alpha: 1).cgColor

        let sidebar = VTVerticalTabSidebar(dataSource: dataSource)
        let hosting = NSHostingView(rootView: sidebar)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        hostingView = hosting
    }

    /// Called from Obj-C when tabs change. Pass an array of tab dictionaries.
    @objc func reloadTabs(_ tabData: [[String: Any]]) {
        dataSource.reloadTabs(tabData)
    }

    @objc var sidebarDelegate: VTSidebarDelegate? {
        get { dataSource.delegate }
        set { dataSource.delegate = newValue }
    }
}
