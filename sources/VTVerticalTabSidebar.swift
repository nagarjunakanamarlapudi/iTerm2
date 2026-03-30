import SwiftUI
import AppKit

// MARK: - Design Tokens

enum DS {
    enum Colors {
        static let sidebarBG = Color(red: 0x1C/255, green: 0x21/255, blue: 0x2A/255)
        static let textPrimary = Color(red: 0xE6/255, green: 0xEB/255, blue: 0xF1/255)
        static let textSecondary = Color(red: 0x8B/255, green: 0x94/255, blue: 0x9E/255)
        static let textTertiary = Color(red: 0x84/255, green: 0x8D/255, blue: 0x97/255) // bumped for WCAG AA
        static let accentBlue = Color(red: 0x58/255, green: 0xA6/255, blue: 0xFF/255)
        static let accentGreen = Color(red: 0x3F/255, green: 0xB9/255, blue: 0x50/255)
        static let accentPurple = Color(red: 0xA3/255, green: 0x71/255, blue: 0xF7/255)
        static let accentOrange = Color(red: 0xD2/255, green: 0x9A/255, blue: 0x22/255)
        static let accentRed = Color(red: 0xF8/255, green: 0x53/255, blue: 0x49/255)
        static let accentPink = Color(red: 0xDB/255, green: 0x61/255, blue: 0xA2/255)
        static let hoverBG = Color.white.opacity(0.06)
        static let activeBG = Color.white.opacity(0.12) // bumped from 0.08
        static let border = Color.white.opacity(0.08)
        static let closeHover = Color.white.opacity(0.15)
    }
    enum Spacing {
        static let xs: CGFloat = 2
        static let sm: CGFloat = 4
        static let md: CGFloat = 6
        static let lg: CGFloat = 8
        static let xl: CGFloat = 12
        static let xxl: CGFloat = 16
    }

    static let groupColors: [(String, Color)] = [
        ("blue", Colors.accentBlue), ("green", Colors.accentGreen),
        ("purple", Colors.accentPurple), ("orange", Colors.accentOrange),
        ("red", Colors.accentRed), ("pink", Colors.accentPink),
    ]
    static func colorFor(_ name: String) -> Color {
        groupColors.first(where: { $0.0 == name })?.1 ?? Colors.accentBlue
    }
}

// MARK: - Data Models

@objc class VTTabItem: NSObject, ObservableObject, Identifiable {
    let id: Int
    @Published var title: String
    @Published var isActive: Bool
    @Published var icon: NSImage?
    @Published var isBell: Bool
    @Published var groupId: String?
    @Published var cwd: String = ""  // Full path from session.currentLocalWorkingDirectory
    @Published var gitBranch: String = ""
    /// Last path component only — used by sidebar for compact display
    var shortCwd: String { (cwd as NSString).lastPathComponent }
    /// Tilde-abbreviated path — used by dashboard
    var tildeAbbreviatedCwd: String {
        let home = NSHomeDirectory()
        if cwd.hasPrefix(home) {
            return "~" + cwd.dropFirst(home.count)
        }
        return cwd
    }
    @Published var isClaude: Bool = false
    @Published var hasNewOutput: Bool = false
    @Published var isDead: Bool = false
    @Published var lastExitCode: Int = -1
    @Published var isPinned: Bool = false
    @Published var agents: [VTAgentItem] = []
    @Published var agentsCollapsed: Bool = false
    @Published var claudeSessionId: String?  // Non-nil when Claude ran (even after exit)
    /// Claude exited but session is resumable
    var isResumable: Bool { !isClaude && claudeSessionId != nil && !isDead }

    init(id: Int, title: String, isActive: Bool = false, icon: NSImage? = nil, isBell: Bool = false, groupId: String? = nil) {
        self.id = id; self.title = title; self.isActive = isActive
        self.icon = icon; self.isBell = isBell; self.groupId = groupId
    }
    var permissionCount: Int {
        agents.filter { $0.status == .waitingForPermission }.count
    }
    var hasPermissionAlert: Bool { permissionCount > 0 }

    override var hash: Int { id }
    override func isEqual(_ object: Any?) -> Bool { (object as? VTTabItem)?.id == id }
}

class VTAgentItem: ObservableObject, Identifiable {
    let id: String
    @Published var name: String
    @Published var role: String
    @Published var status: AgentStatus
    @Published var pendingTool: String = ""
    @Published var permissionTimestamp: Date?
    enum AgentStatus: String { case running, waitingForPermission, idle, completed, errored }
    var isActive: Bool { status == .running || status == .waitingForPermission }
    init(name: String, role: String = "agent", status: AgentStatus = .running) {
        self.id = name; self.name = name; self.role = role; self.status = status
    }
}

class VTTabGroup: ObservableObject, Identifiable {
    let id: String
    @Published var name: String
    @Published var colorName: String
    @Published var isCollapsed: Bool
    var color: Color { DS.colorFor(colorName) }
    init(id: String = UUID().uuidString, name: String, colorName: String = "blue", isCollapsed: Bool = false) {
        self.id = id; self.name = name; self.colorName = colorName; self.isCollapsed = isCollapsed
    }
}

// MARK: - Delegate

@objc protocol VTSidebarDelegate: AnyObject {
    @objc func sidebarDidSelectTab(uniqueId: Int)
    @objc func sidebarDidCloseTab(uniqueId: Int)
    @objc func sidebarDidRequestNewTab()
    @objc func sidebarDidReorderTab(uniqueId: Int, toIndex: Int)
    @objc func sidebarTitleForTab(uniqueId: Int) -> String
    @objc func sidebarDidSelectAgent(name: String, inTab uniqueId: Int)
    @objc func sidebarDidMoveTab(uniqueId: Int, toGroupId: String?)
    @objc func sidebarDidUpdateGroups(_ groups: [[String: Any]])
    @objc func sidebarDidRenameTab(uniqueId: Int, newName: String)
}

// MARK: - Data Source

@objc class VTSidebarDataSource: NSObject, ObservableObject {
    @Published var tabs: [VTTabItem] = []
    @Published var groups: [VTTabGroup] = []
    @Published var activeTabId: Int = -1
    @Published var recentTabOrder: [Int] = []
    @objc weak var delegate: VTSidebarDelegate?

    @objc func reloadTabs(_ tabData: [[String: Any]]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var newTabs: [VTTabItem] = []
            for data in tabData {
                guard let uid = data["uniqueId"] as? Int,
                      let title = data["title"] as? String else { continue }
                let isActive = (data["isActive"] as? Bool) ?? false
                let isBell = (data["isBell"] as? Bool) ?? false
                let icon = data["icon"] as? NSImage
                let cwd = (data["cwd"] as? String) ?? ""
                let gitBranch = (data["gitBranch"] as? String) ?? ""
                let isClaude = (data["isClaude"] as? Bool) ?? false
                let hasNewOutput = (data["hasNewOutput"] as? Bool) ?? false
                let isDead = (data["isDead"] as? Bool) ?? false
                let lastExitCode = (data["lastExitCode"] as? Int) ?? -1

                let isPinned = (data["isPinned"] as? Bool) ?? false
                let dataGroupId = data["groupId"] as? String

                let claudeSessionId = data["claudeSessionId"] as? String

                if let existing = self.tabs.first(where: { $0.id == uid }) {
                    existing.title = title; existing.isActive = isActive
                    existing.icon = icon; existing.isBell = isBell
                    existing.cwd = cwd; existing.gitBranch = gitBranch; existing.isClaude = isClaude
                    existing.hasNewOutput = hasNewOutput; existing.isDead = isDead
                    existing.lastExitCode = lastExitCode; existing.isPinned = isPinned
                    existing.claudeSessionId = claudeSessionId
                    // Preserve user-assigned groupId; only set from data if not yet assigned
                    if existing.groupId == nil && dataGroupId != nil {
                        existing.groupId = dataGroupId
                    }
                    newTabs.append(existing)
                } else {
                    let item = VTTabItem(id: uid, title: title, isActive: isActive, icon: icon, isBell: isBell, groupId: dataGroupId)
                    item.cwd = cwd; item.gitBranch = gitBranch; item.isClaude = isClaude
                    item.hasNewOutput = hasNewOutput; item.isDead = isDead
                    item.lastExitCode = lastExitCode; item.isPinned = isPinned
                    item.claudeSessionId = claudeSessionId
                    newTabs.append(item)
                }
                if let agentList = data["agents"] as? [[String: String]] {
                    let tab = newTabs.last!
                    tab.agents = agentList.map { d in
                        let agent = VTAgentItem(name: d["name"] ?? "agent", role: d["role"] ?? "agent",
                                    status: VTAgentItem.AgentStatus(rawValue: d["status"] ?? "running") ?? .running)
                        agent.pendingTool = d["pendingTool"] ?? ""
                        if let ts = d["permissionTimestamp"], let ti = Double(ts) {
                            agent.permissionTimestamp = Date(timeIntervalSince1970: ti)
                        }
                        return agent
                    }
                }
                if isActive && self.activeTabId != uid {
                    self.recentTabOrder.removeAll { $0 == uid }
                    self.recentTabOrder.insert(uid, at: 0)
                    self.activeTabId = uid
                }
            }
            self.tabs = newTabs
            let validIds = Set(newTabs.map { $0.id })
            self.recentTabOrder.removeAll { !validIds.contains($0) }
        }
    }

    func tabsForGroup(_ groupId: String) -> [VTTabItem] { tabs.filter { $0.groupId == groupId } }
    var ungroupedTabs: [VTTabItem] { tabs.filter { $0.groupId == nil && !$0.isPinned } }
    var pinnedTabs: [VTTabItem] { tabs.filter { $0.isPinned } }

    func createGroup(name: String, colorName: String = "blue") -> VTTabGroup {
        let g = VTTabGroup(name: name, colorName: colorName); groups.append(g)
        notifyGroupsChanged()
        return g
    }
    func deleteGroup(_ id: String) {
        for t in tabs where t.groupId == id {
            t.groupId = nil
            delegate?.sidebarDidMoveTab(uniqueId: t.id, toGroupId: nil)
        }
        groups.removeAll { $0.id == id }
        notifyGroupsChanged()
    }
    func ungroupAll(_ id: String) {
        for t in tabs where t.groupId == id {
            t.groupId = nil
            delegate?.sidebarDidMoveTab(uniqueId: t.id, toGroupId: nil)
        }
        groups.removeAll { $0.id == id }
        notifyGroupsChanged()
    }
    func moveTab(_ tabId: Int, toGroup gid: String?) {
        tabs.first(where: { $0.id == tabId })?.groupId = gid
        delegate?.sidebarDidMoveTab(uniqueId: tabId, toGroupId: gid)
        cleanupEmptyGroups()
    }
    func cleanupEmptyGroups() {
        let before = groups.count
        groups.removeAll { g in !tabs.contains(where: { $0.groupId == g.id }) }
        if groups.count != before { notifyGroupsChanged() }
    }
    func colorForGroup(_ groupId: String?) -> Color? {
        guard let gid = groupId else { return nil }
        return groups.first(where: { $0.id == gid })?.color
    }
    func togglePin(_ tabId: Int) {
        if let t = tabs.first(where: { $0.id == tabId }) {
            t.isPinned.toggle()
            if t.isPinned && t.groupId != nil {
                t.groupId = nil
                delegate?.sidebarDidMoveTab(uniqueId: tabId, toGroupId: nil)
            }
        }
    }

    /// Serialize current group definitions for persistence.
    @objc func groupsAsDictionaries() -> [[String: Any]] {
        return groups.map { g in
            [
                "id": g.id,
                "name": g.name,
                "colorName": g.colorName,
                "isCollapsed": g.isCollapsed,
            ] as [String: Any]
        }
    }

    /// Restore groups from persisted dictionaries.
    @objc func restoreGroups(_ dicts: [[String: Any]]) {
        var restored: [VTTabGroup] = []
        for d in dicts {
            guard let id = d["id"] as? String,
                  let name = d["name"] as? String else { continue }
            let colorName = (d["colorName"] as? String) ?? "blue"
            let isCollapsed = (d["isCollapsed"] as? Bool) ?? false
            restored.append(VTTabGroup(id: id, name: name, colorName: colorName, isCollapsed: isCollapsed))
        }
        groups = restored
    }

    private func notifyGroupsChanged() {
        delegate?.sidebarDidUpdateGroups(groupsAsDictionaries())
    }
}

// MARK: - Sidebar View

struct VTVerticalTabSidebar: View {
    @ObservedObject var dataSource: VTSidebarDataSource
    @State private var hoveredTabId: Int?
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var showNewGroupSheet = false
    @State private var newGroupName = ""
    @State private var newGroupColor = "blue"
    @State private var focusedAgentKey: String?  // "tabId:agentName"

    var filteredTabs: [VTTabItem] {
        if searchText.isEmpty { return dataSource.tabs }
        return dataSource.tabs.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.cwd.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("TABS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .tracking(0.5)
                Spacer()
                Text("\(dataSource.tabs.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(DS.Colors.hoverBG).clipShape(Capsule())
            }
            .padding(.horizontal, DS.Spacing.xl)
            .padding(.top, DS.Spacing.xl).padding(.bottom, DS.Spacing.lg)

            if isSearching {
                SearchField(text: $searchText)
                    .padding(.horizontal, DS.Spacing.lg).padding(.bottom, DS.Spacing.lg)
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: DS.Spacing.xs) {
                    if isSearching && !searchText.isEmpty {
                        if filteredTabs.isEmpty {
                            emptySearchState
                        } else {
                            ForEach(filteredTabs) { tab in tabRow(tab) }
                        }
                    } else {
                        // Pinned
                        let pinned = dataSource.pinnedTabs
                        if !pinned.isEmpty {
                            pinnedHeader
                            ForEach(pinned) { tab in tabRow(tab) }
                            separator
                        }
                        // Groups
                        ForEach(dataSource.groups) { group in
                            GroupSection(group: group, tabs: dataSource.tabsForGroup(group.id),
                                        activeTabId: dataSource.activeTabId, hoveredTabId: $hoveredTabId,
                                        focusedAgentKey: $focusedAgentKey, dataSource: dataSource,
                                        onSelectTab: { selectTab($0) }, onCloseTab: { dataSource.delegate?.sidebarDidCloseTab(uniqueId: $0) })
                        }
                        // Ungrouped
                        let ungrouped = dataSource.ungroupedTabs
                        if !ungrouped.isEmpty {
                            if !dataSource.groups.isEmpty { separator }
                            ForEach(ungrouped) { tab in tabRow(tab) }
                        }
                    }
                }
                .padding(.horizontal, DS.Spacing.lg)
            }

            Spacer(minLength: 0)
            bottomBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Colors.sidebarBG)
        .overlay(Rectangle().fill(DS.Colors.border).frame(width: 1), alignment: .trailing)
    }

    private func selectTab(_ id: Int) {
        focusedAgentKey = nil
        dataSource.activeTabId = id // optimistic
        dataSource.delegate?.sidebarDidSelectTab(uniqueId: id)
    }

    private var emptySearchState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 24)).foregroundColor(DS.Colors.textTertiary)
            Text("No matching tabs").font(.system(size: 12)).foregroundColor(DS.Colors.textTertiary)
        }.frame(maxWidth: .infinity).padding(.top, 40)
    }

    private var pinnedHeader: some View {
        HStack {
            Image(systemName: "pin.fill").font(.system(size: 9)).foregroundColor(DS.Colors.textTertiary)
            Text("PINNED").font(.system(size: 10, weight: .semibold)).foregroundColor(DS.Colors.textTertiary).tracking(0.5)
            Spacer()
        }.padding(.horizontal, DS.Spacing.xl).padding(.bottom, DS.Spacing.xs)
    }

    private var separator: some View {
        Rectangle().fill(DS.Colors.border).frame(height: 1)
            .padding(.horizontal, DS.Spacing.xl).padding(.vertical, DS.Spacing.sm)
    }

    @ViewBuilder
    private func tabRow(_ tab: VTTabItem) -> some View {
        TabRowView(
            tab: tab,
            isActive: tab.id == dataSource.activeTabId,
            isHovered: hoveredTabId == tab.id,
            groups: dataSource.groups,
            onSelect: { selectTab(tab.id) },
            onClose: { dataSource.delegate?.sidebarDidCloseTab(uniqueId: tab.id) },
            onMoveToGroup: { dataSource.moveTab(tab.id, toGroup: $0) },
            onTogglePin: { dataSource.togglePin(tab.id) },
            onCreateGroupWithTab: {
                let g = dataSource.createGroup(name: "New Group")
                dataSource.moveTab(tab.id, toGroup: g.id)
            },
            onRename: { dataSource.delegate?.sidebarDidRenameTab(uniqueId: tab.id, newName: $0) },
            groupColor: dataSource.colorForGroup(tab.groupId)
        )
        .onHover { h in hoveredTabId = h ? tab.id : nil }
        .onDrag { NSItemProvider(object: "\(tab.id)" as NSString) }
        .onDrop(of: [.text], delegate: TabDropDelegate(targetTabId: tab.id, dataSource: dataSource))

        // Agent rows nested under Claude tabs
        if tab.isClaude && !tab.agentsCollapsed && tab.agents.contains(where: { $0.isActive }) {
            VStack(spacing: 0) {
                ForEach(tab.agents) { agent in
                    AgentRowView(agent: agent, isFocused: focusedAgentKey == "\(tab.id):\(agent.name)") {
                        focusedAgentKey = "\(tab.id):\(agent.name)"
                        dataSource.delegate?.sidebarDidSelectAgent(name: agent.name, inTab: tab.id)
                    }
                }
            }
            .padding(.leading, 20)
            .overlay(
                Rectangle().fill(DS.Colors.accentPurple.opacity(0.3)).frame(width: 2),
                alignment: .leading
            )
        }
    }

    private var bottomBar: some View {
        HStack(spacing: DS.Spacing.lg) {
            Button(action: { dataSource.delegate?.sidebarDidRequestNewTab() }) {
                Image(systemName: "plus").font(.system(size: 14, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 28, height: 28).background(DS.Colors.hoverBG)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain)

            Button(action: { showNewGroupSheet = true }) {
                Image(systemName: "folder.badge.plus").font(.system(size: 13))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showNewGroupSheet) {
                NewGroupPopover(name: $newGroupName, colorName: $newGroupColor,
                    onCreate: {
                        if !newGroupName.isEmpty {
                            _ = dataSource.createGroup(name: newGroupName, colorName: newGroupColor)
                            newGroupName = ""; newGroupColor = "blue"; showNewGroupSheet = false
                        }
                    }, onCancel: { showNewGroupSheet = false })
            }

            Spacer()

            Button(action: { isSearching.toggle() }) {
                Image(systemName: "magnifyingglass").font(.system(size: 13))
                    .foregroundColor(isSearching ? DS.Colors.accentBlue : DS.Colors.textSecondary)
                    .frame(width: 28, height: 28)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Spacing.xl).padding(.vertical, DS.Spacing.xl)
        .overlay(Rectangle().fill(DS.Colors.border).frame(height: 1), alignment: .top)
    }
}

// MARK: - Group Section

struct GroupSection: View {
    @ObservedObject var group: VTTabGroup
    let tabs: [VTTabItem]
    let activeTabId: Int
    @Binding var hoveredTabId: Int?
    @Binding var focusedAgentKey: String?
    @ObservedObject var dataSource: VTSidebarDataSource
    let onSelectTab: (Int) -> Void
    let onCloseTab: (Int) -> Void
    @State private var isHeaderHovered = false
    @State private var showRename = false
    @State private var editName = ""

    private func groupChanged() {
        dataSource.delegate?.sidebarDidUpdateGroups(dataSource.groupsAsDictionaries())
    }

    var body: some View {
        VStack(spacing: DS.Spacing.xs) {
            // Group header
            HStack(spacing: DS.Spacing.md) {
                Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundColor(DS.Colors.textTertiary).frame(width: 12)
                Circle().fill(group.color).frame(width: 8, height: 8)
                if showRename {
                    TextField("Group name", text: $editName, onCommit: { group.name = editName; showRename = false; groupChanged() })
                        .textFieldStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                } else {
                    Text(group.name).font(.system(size: 12, weight: .semibold)).foregroundColor(DS.Colors.textSecondary)
                }
                Spacer()
                if group.isCollapsed {
                    let groupPermCount = tabs.reduce(0) { $0 + $1.permissionCount }
                    if groupPermCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 8)).foregroundColor(DS.Colors.accentOrange)
                            Text("\(groupPermCount)").font(.system(size: 9, weight: .medium))
                                .foregroundColor(DS.Colors.accentOrange)
                        }
                    }
                }
                Text("\(tabs.count)").font(.system(size: 10, weight: .medium)).foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 5).padding(.vertical, 1).background(DS.Colors.hoverBG).clipShape(Capsule())
            }
            .padding(.horizontal, DS.Spacing.sm).padding(.vertical, DS.Spacing.md)
            .background(RoundedRectangle(cornerRadius: 6).fill(isHeaderHovered ? DS.Colors.hoverBG : Color.clear))
            .contentShape(Rectangle())
            .onTapGesture { group.isCollapsed.toggle(); groupChanged() }
            .onHover { isHeaderHovered = $0 }
            .onDrop(of: [.text], delegate: GroupDropDelegate(groupId: group.id, dataSource: dataSource))
            .contextMenu {
                Button("Rename Group") { editName = group.name; showRename = true }
                Menu("Color") {
                    ForEach(DS.groupColors, id: \.0) { name, color in
                        Button(action: { group.colorName = name; groupChanged() }) {
                            HStack { Circle().fill(color).frame(width: 10, height: 10); Text(name.capitalized)
                                if group.colorName == name { Image(systemName: "checkmark") } }
                        }
                    }
                }
                Divider()
                Button("Ungroup Tabs") { dataSource.ungroupAll(group.id) }
                Button("Close Group") {
                    for t in tabs { dataSource.delegate?.sidebarDidCloseTab(uniqueId: t.id) }
                    dataSource.deleteGroup(group.id)
                }
            }

            if !group.isCollapsed {
                ForEach(tabs) { tab in
                    TabRowView(tab: tab, isActive: tab.id == activeTabId, isHovered: hoveredTabId == tab.id,
                               groups: dataSource.groups, onSelect: { onSelectTab(tab.id) },
                               onClose: { onCloseTab(tab.id) },
                               onMoveToGroup: { dataSource.moveTab(tab.id, toGroup: $0) },
                               onTogglePin: { dataSource.togglePin(tab.id) },
                               onCreateGroupWithTab: {
                                   let g = dataSource.createGroup(name: "New Group")
                                   dataSource.moveTab(tab.id, toGroup: g.id)
                               },
                               onRename: { dataSource.delegate?.sidebarDidRenameTab(uniqueId: tab.id, newName: $0) },
                               groupColor: group.color, indented: true)
                    .onHover { h in hoveredTabId = h ? tab.id : nil }
                    .onDrag { NSItemProvider(object: "\(tab.id)" as NSString) }
                    .onDrop(of: [.text], delegate: TabDropDelegate(targetTabId: tab.id, dataSource: dataSource))

                    // Agents in grouped tabs
                    if tab.isClaude && !tab.agentsCollapsed && tab.agents.contains(where: { $0.isActive }) {
                        VStack(spacing: 0) {
                            ForEach(tab.agents) { agent in
                                AgentRowView(agent: agent, isFocused: focusedAgentKey == "\(tab.id):\(agent.name)") {
                                    focusedAgentKey = "\(tab.id):\(agent.name)"
                                    dataSource.delegate?.sidebarDidSelectAgent(name: agent.name, inTab: tab.id)
                                }
                            }
                        }
                        .padding(.leading, 32)
                        .overlay(Rectangle().fill(DS.Colors.accentPurple.opacity(0.3)).frame(width: 2), alignment: .leading)
                    }
                }
            }
        }
    }
}

// MARK: - Tab Row

struct TabRowView: View {
    @ObservedObject var tab: VTTabItem
    let isActive: Bool
    let isHovered: Bool
    let groups: [VTTabGroup]
    let onSelect: () -> Void
    let onClose: () -> Void
    let onMoveToGroup: (String?) -> Void
    let onTogglePin: () -> Void
    let onCreateGroupWithTab: () -> Void
    var onRename: ((String) -> Void)? = nil
    var groupColor: Color? = nil  // colored stripe for grouped tabs
    var indented: Bool = false

    @State private var closeHovered = false
    @State private var isPressed = false
    @State private var isRenaming = false
    @State private var editName = ""

    var body: some View {
        HStack(spacing: DS.Spacing.lg) {
            // Active indicator / group color stripe
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isActive ? DS.Colors.accentBlue : (groupColor ?? Color.clear))
                .frame(width: 3, height: isActive ? 24 : 16)
                .opacity(isActive ? 1 : 0.6)

            // Icon
            Group {
                if tab.isClaude {
                    Image(systemName: "sparkles").foregroundColor(DS.Colors.accentPurple)
                        .padding(2).background(DS.Colors.accentPurple.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else if tab.isDead {
                    Image(systemName: "xmark.circle").foregroundColor(DS.Colors.accentRed)
                } else {
                    Image(systemName: "terminal")
                        .foregroundColor(isActive ? DS.Colors.accentBlue : DS.Colors.textTertiary)
                }
            }.font(.system(size: 12)).frame(width: 16, height: 16)

            // Title + subtitle
            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField("Tab name", text: $editName, onCommit: {
                        if !editName.isEmpty { onRename?(editName) }
                        isRenaming = false
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                } else {
                    Text(tab.title.isEmpty ? (tab.shortCwd.isEmpty ? "Shell" : tab.shortCwd) : tab.title)
                        .font(.system(size: 13))
                        .foregroundColor(isActive ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                // Subtitle: git branch > cwd (on hover/active)
                if !tab.gitBranch.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 8))
                        Text(tab.gitBranch)
                            .font(.system(size: 10))
                    }
                    .foregroundColor(DS.Colors.accentGreen.opacity(0.8))
                    .lineLimit(1)
                } else if !tab.shortCwd.isEmpty && (isActive || isHovered) {
                    Text(tab.shortCwd).font(.system(size: 10)).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                }
            }
            .layoutPriority(1)  // ensure title gets space before badges

            Spacer(minLength: 0)

            // Status indicators (priority: bell > failure > new output)
            if tab.isBell {
                Image(systemName: "bell.fill").font(.system(size: 8)).foregroundColor(DS.Colors.accentOrange)
            } else if tab.lastExitCode > 0 && !isActive {
                Text("✗").font(.system(size: 10, weight: .bold)).foregroundColor(DS.Colors.accentRed)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(DS.Colors.accentRed.opacity(0.15)).clipShape(Capsule())
            } else if tab.hasNewOutput && !isActive {
                Circle().stroke(DS.Colors.accentBlue, lineWidth: 1.5).frame(width: 6, height: 6)
            }

            // Permission alert badge (when agents collapsed)
            if tab.agentsCollapsed && tab.hasPermissionAlert {
                HStack(spacing: 2) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 8)).foregroundColor(DS.Colors.accentOrange)
                    if tab.permissionCount > 1 {
                        Text("\(tab.permissionCount)").font(.system(size: 9, weight: .medium))
                            .foregroundColor(DS.Colors.accentOrange)
                    }
                }
            }

            // Agent count chevron (collapse toggle in tab row)
            if tab.isClaude && tab.agents.contains(where: { $0.isActive }) {
                Button(action: { tab.agentsCollapsed.toggle() }) {
                    HStack(spacing: 2) {
                        Text("\(tab.agents.count)").font(.system(size: 9, weight: .medium))
                        Image(systemName: tab.agentsCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }.foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(DS.Colors.hoverBG).cornerRadius(3)
                }.buttonStyle(.plain)
            }

            // Close button
            if isHovered || isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        .foregroundColor(closeHovered ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                        .frame(width: 18, height: 18)
                        .background(closeHovered ? DS.Colors.closeHover : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }.buttonStyle(.plain).onHover { closeHovered = $0 }
            }
        }
        .padding(.leading, indented ? DS.Spacing.xl : DS.Spacing.sm)
        .padding(.trailing, DS.Spacing.sm).padding(.vertical, DS.Spacing.md)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(isActive ? DS.Colors.activeBG : (isPressed ? DS.Colors.activeBG : (isHovered ? DS.Colors.hoverBG : Color.clear))))
        .animation(.easeInOut(duration: 0.1), value: isHovered)
        .scaleEffect(isPressed ? 0.98 : 1.0)
        .animation(.easeInOut(duration: 0.08), value: isPressed)
        .contentShape(Rectangle())
        .onTapGesture {
            isPressed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { isPressed = false }
            onSelect()
        }
        .contextMenu {
            Button("Rename Tab") { editName = tab.title; isRenaming = true }
            Button("Close Tab") { onClose() }
            Divider()
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { onTogglePin() }
            Divider()
            Button("Add to New Group") { onCreateGroupWithTab() }
            if !groups.isEmpty {
                Menu("Move to Group") {
                    ForEach(groups) { group in
                        Button(action: { onMoveToGroup(group.id) }) {
                            HStack { Circle().fill(group.color).frame(width: 8, height: 8); Text(group.name) }
                        }
                    }
                    if tab.groupId != nil { Divider(); Button("Remove from Group") { onMoveToGroup(nil) } }
                }
            }
        }
    }
}

// MARK: - Agent Row

struct AgentRowView: View {
    @ObservedObject var agent: VTAgentItem
    var isFocused: Bool = false
    let onSelect: () -> Void
    @State private var isHovered = false
    @State private var gearRotation: Double = 0
    @State private var permissionPulse = false

    private var permissionAgeOver60s: Bool {
        guard let ts = agent.permissionTimestamp else { return false }
        return Date().timeIntervalSince(ts) > 60
    }

    var statusIcon: some View {
        Group {
            switch agent.status {
            case .running:
                Image(systemName: "gearshape")
                    .foregroundColor(DS.Colors.accentPurple)
                    .rotationEffect(.degrees(gearRotation))
                    .onAppear {
                        withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                            gearRotation = 360
                        }
                    }
            case .waitingForPermission:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(DS.Colors.accentOrange)
                    .opacity(permissionPulse && permissionAgeOver60s ? 0.7 : 1.0)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                            permissionPulse = true
                        }
                    }
            case .idle:
                Image(systemName: "pause.circle").foregroundColor(DS.Colors.textTertiary)
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundColor(DS.Colors.accentGreen)
            case .errored:
                Image(systemName: "xmark.circle.fill").foregroundColor(DS.Colors.accentRed)
            }
        }.font(.system(size: 10))
    }

    var body: some View {
        HStack(spacing: DS.Spacing.md) {
            // Left accent for focused
            RoundedRectangle(cornerRadius: 1)
                .fill(isFocused ? DS.Colors.accentPurple : Color.clear)
                .frame(width: 3, height: 16)

            Image(systemName: "person.fill").font(.system(size: 9))
                .foregroundColor(isFocused || isHovered ? DS.Colors.accentPurple : DS.Colors.textTertiary)
                .frame(width: 14, height: 14)

            Text(agent.name).font(.system(size: 12, weight: isFocused ? .medium : .regular))
                .foregroundColor(isFocused || isHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 0)
            statusIcon
        }
        .padding(.trailing, DS.Spacing.sm).padding(.vertical, DS.Spacing.sm)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(isFocused ? DS.Colors.accentPurple.opacity(0.12) : (isHovered ? DS.Colors.hoverBG : Color.clear)))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect() }
    }
}

// MARK: - Search Field

struct SearchField: View {
    @Binding var text: String
    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "magnifyingglass").foregroundColor(DS.Colors.textTertiary).font(.system(size: 12))
            TextField("Search tabs...", text: $text).textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(DS.Colors.textPrimary)
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(DS.Colors.textTertiary).font(.system(size: 11))
                }.buttonStyle(.plain)
            }
        }.padding(.horizontal, DS.Spacing.lg).padding(.vertical, DS.Spacing.md).background(DS.Colors.hoverBG).cornerRadius(6)
    }
}

// MARK: - New Group Popover

struct NewGroupPopover: View {
    @Binding var name: String
    @Binding var colorName: String
    let onCreate: () -> Void
    let onCancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Group").font(.system(size: 13, weight: .semibold))
            TextField("Group name", text: $name).textFieldStyle(.roundedBorder).font(.system(size: 12))
            HStack(spacing: 6) {
                ForEach(DS.groupColors, id: \.0) { cName, color in
                    Circle().fill(color).frame(width: 20, height: 20)
                        .overlay(Circle().stroke(Color.white, lineWidth: colorName == cName ? 2 : 0))
                        .onTapGesture { colorName = cName }
                }
            }
            HStack { Button("Cancel", action: onCancel); Spacer()
                Button("Create", action: onCreate).keyboardShortcut(.defaultAction).disabled(name.isEmpty) }
        }.padding().frame(width: 220)
    }
}

// MARK: - Drag & Drop

struct TabDropDelegate: DropDelegate {
    let targetTabId: Int; let dataSource: VTSidebarDataSource
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }
    func performDrop(info: DropInfo) -> Bool {
        guard let item = info.itemProviders(for: [.text]).first else { return false }
        item.loadObject(ofClass: NSString.self) { obj, _ in
            guard let str = obj as? String, let draggedId = Int(str) else { return }
            DispatchQueue.main.async {
                guard let draggedTab = dataSource.tabs.first(where: { $0.id == draggedId }),
                      let targetTab = dataSource.tabs.first(where: { $0.id == targetTabId }) else { return }
                draggedTab.groupId = targetTab.groupId
                if let fromIdx = dataSource.tabs.firstIndex(where: { $0.id == draggedId }),
                   let toIdx = dataSource.tabs.firstIndex(where: { $0.id == targetTabId }), fromIdx != toIdx {
                    dataSource.tabs.move(fromOffsets: IndexSet(integer: fromIdx), toOffset: toIdx > fromIdx ? toIdx + 1 : toIdx)
                }
            }
        }; return true
    }
}

struct GroupDropDelegate: DropDelegate {
    let groupId: String; let dataSource: VTSidebarDataSource
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }
    func performDrop(info: DropInfo) -> Bool {
        guard let item = info.itemProviders(for: [.text]).first else { return false }
        item.loadObject(ofClass: NSString.self) { obj, _ in
            guard let str = obj as? String, let draggedId = Int(str) else { return }
            DispatchQueue.main.async { dataSource.moveTab(draggedId, toGroup: groupId) }
        }; return true
    }
}
