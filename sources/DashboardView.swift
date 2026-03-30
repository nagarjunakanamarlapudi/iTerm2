import SwiftUI
import AppKit

// MARK: - Filter (used in Command Center)

enum DashboardFilter: String, CaseIterable {
    case all = "ALL"
    case needsAttention = "ATTN"
    case claude = "CLAUDE"
    case dead = "DEAD"
    case pinned = "PIN"

    func matches(_ tab: VTTabItem) -> Bool {
        switch self {
        case .all: return true
        case .needsAttention: return tab.isBell || tab.hasPermissionAlert || (tab.isDead && tab.lastExitCode > 0) || tab.isResumable
        case .claude: return tab.isClaude || tab.isResumable
        case .dead: return tab.isDead
        case .pinned: return tab.isPinned
        }
    }
}

// MARK: - Panel Selection

enum DashboardPanel: String {
    case commandCenter = "COMMAND CENTER"
    case history = "HISTORY"
}

// MARK: - Main Dashboard View

struct DashboardView: View {
    @ObservedObject var dataSource: VTSidebarDataSource
    var onSelectTab: (Int) -> Void
    var onSelectAgent: (String, Int) -> Void
    var onResumeSession: (String, String) -> Void
    var onDismiss: () -> Void

    @State private var activePanel: DashboardPanel = .commandCenter
    @State private var searchQuery = ""
    @State private var activeFilter: DashboardFilter = .all
    @State private var collapsedGroupIds: Set<String> = []
    @State private var selectedTabId: Int? = nil
    @StateObject private var globalStats = DashboardGlobalStats()
    @StateObject private var sessionStats = DashboardSessionStats()
    @StateObject private var sessionCatalog = DashboardSessionCatalog()
    @StateObject private var toast = ToastManager()
    @State private var transcriptReader: DashboardTranscriptReader?

    // MARK: - Computed

    private var filteredTabs: [VTTabItem] {
        dataSource.tabs.filter { tab in
            guard activeFilter.matches(tab) else { return false }
            if searchQuery.isEmpty { return true }
            let q = searchQuery
            return tab.title.localizedCaseInsensitiveContains(q)
                || tab.cwd.localizedCaseInsensitiveContains(q)
                || tab.gitBranch.localizedCaseInsensitiveContains(q)
                || tab.agents.contains(where: { $0.name.localizedCaseInsensitiveContains(q) })
        }
    }

    private var groupedSections: [(group: VTTabGroup?, tabs: [VTTabItem])] {
        var out: [(group: VTTabGroup?, tabs: [VTTabItem])] = []
        for g in dataSource.groups {
            let tabs = filteredTabs.filter { $0.groupId == g.id }
            if !tabs.isEmpty { out.append((group: g, tabs: tabs)) }
        }
        let ungrouped = filteredTabs.filter { $0.groupId == nil }
        if !ungrouped.isEmpty { out.append((group: nil, tabs: ungrouped)) }
        return out
    }

    private var attentionCount: Int { dataSource.tabs.filter { DashboardFilter.needsAttention.matches($0) }.count }
    private var claudeCount: Int { dataSource.tabs.filter { DashboardFilter.claude.matches($0) }.count }

    // Aggregate live cost from all active Claude sessions
    private var liveCostTotal: Double {
        sessionStats.estimatedCostUSD
    }

    var body: some View {
        ZStack {
            MC.background()
            VStack(spacing: 0) {
                heroHeader
                panelSelector
                panelContent
            }
            ToastOverlay(manager: toast)
        }
        .onAppear {
            globalStats.reload()
            sessionCatalog.buildCatalog()
        }
        .onChange(of: selectedTabId) { _ in loadStatsForSelected() }
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                // Left: title + hero cost
                VStack(alignment: .leading, spacing: MC.Sp.xs) {
                    Text("MISSION CONTROL")
                        .font(MC.sectionFont())
                        .tracking(3)
                        .foregroundColor(MC.cyan)
                    heroCostDisplay
                    summaryStrip
                }
                Spacer(minLength: MC.Sp.lg)
                // Right: search + close
                VStack(alignment: .trailing, spacing: MC.Sp.sm) {
                    HStack(spacing: MC.Sp.sm) {
                        searchField
                        closeBtn
                    }
                    statusLights
                }
            }
            .padding(.horizontal, MC.Sp.xl)
            .padding(.top, MC.Sp.lg)
            .padding(.bottom, MC.Sp.md)

            // Gradient accent line
            Rectangle().fill(
                LinearGradient(colors: [MC.cyan.opacity(0), MC.cyan.opacity(0.4), MC.violet.opacity(0.4), MC.violet.opacity(0)],
                               startPoint: .leading, endPoint: .trailing)
            ).frame(height: 1)
        }
    }

    // MARK: - Hero Cost (32px, the centerpiece)

    private var heroCostDisplay: some View {
        // computedTodayCost is pre-calculated during catalog build (includes per-day splits)
        let todayCost = max(sessionCatalog.computedTodayCost, globalStats.totalCostToday) + liveCostTotal
        let costStr = MC.formatCost(todayCost)
        let isLoading = sessionCatalog.isLoading
        return HStack(alignment: .firstTextBaseline, spacing: MC.Sp.sm) {
            if isLoading {
                Text("calculating\u{2026}")
                    .font(MC.titleFont())
                    .foregroundColor(MC.textMuted)
            } else {
                Text(costStr)
                    .font(MC.heroFont())
                    .foregroundColor(MC.textHero)
            }
            Text("today")
                .font(MC.labelFont())
                .foregroundColor(MC.textMuted)
        }
    }

    private var summaryStrip: some View {
        let active = dataSource.tabs.filter { $0.isClaude }.count
        let waiting = dataSource.tabs.filter { $0.hasPermissionAlert }.count
        let completed = sessionCatalog.todaySessions.filter { !$0.isActive }.count
        var parts: [String] = []
        if active > 0 { parts.append("\(active) active") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if completed > 0 { parts.append("\(completed) completed today") }
        if parts.isEmpty { parts.append("\(dataSource.tabs.count) terminals") }
        return Text(parts.joined(separator: "  \u{00B7}  "))
            .font(MC.labelFont())
            .foregroundColor(MC.textMuted)
    }

    private var statusLights: some View {
        let ok = dataSource.tabs.count - attentionCount - dataSource.tabs.filter { $0.isDead }.count
        return HStack(spacing: MC.Sp.md) {
            sLight(MC.emerald, "\(ok) OK")
            if attentionCount > 0 { sLight(MC.amber, "\(attentionCount) ATTN") }
            if claudeCount > 0 { sLight(MC.violet, "\(claudeCount) AI") }
        }
        .padding(.horizontal, MC.Sp.md)
        .padding(.vertical, MC.Sp.xs)
        .background(MC.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func sLight(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6).shadow(color: color.opacity(0.5), radius: 3)
            Text(label).font(MC.metaFont()).foregroundColor(color)
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Text(">").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(MC.cyan.opacity(0.5))
            TextField("search\u{2026}", text: $searchQuery)
                .textFieldStyle(.plain).font(MC.bodyFont()).foregroundColor(MC.textPrimary)
                .frame(width: 140)
            if !searchQuery.isEmpty {
                Button(action: { searchQuery = "" }) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(MC.textMuted)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, MC.Sp.sm).padding(.vertical, MC.Sp.xs)
        .background(MC.bgSurface).clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(MC.border))
    }

    private var closeBtn: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                .foregroundColor(MC.textMuted).frame(width: 24, height: 24)
        }.buttonStyle(.plain)
    }

    // MARK: - Panel Selector

    private var panelSelector: some View {
        HStack(spacing: MC.Sp.xs) {
            panelTab(.commandCenter, count: dataSource.tabs.count)
            panelTab(.history, count: sessionCatalog.entries.count)
            Spacer()
        }
        .padding(.horizontal, MC.Sp.xl)
        .padding(.vertical, MC.Sp.sm)
        .background(MC.bgSurface.opacity(0.3))
    }

    private func panelTab(_ panel: DashboardPanel, count: Int) -> some View {
        let isActive = activePanel == panel
        return Button(action: { withAnimation(.easeInOut(duration: 0.2)) { activePanel = panel } }) {
            HStack(spacing: 5) {
                if isActive { Text("\u{25B8}").font(MC.metaFont()).foregroundColor(MC.cyan) }
                Text(panel.rawValue)
                    .font(.system(size: 12, weight: .bold, design: .monospaced)).tracking(1)
                    .foregroundColor(isActive ? MC.textBright : MC.textMuted)
                Text("\(count)").font(MC.metaFont()).foregroundColor(MC.textDim)
            }
            .padding(.horizontal, MC.Sp.md).padding(.vertical, 5)
            .background(isActive ? MC.cyan.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain)
    }

    // MARK: - Panel Content

    @ViewBuilder
    private var panelContent: some View {
        switch activePanel {
        case .commandCenter:
            commandCenterContent
        case .history:
            DashboardSessionsView(
                catalog: sessionCatalog,
                onSelectTab: onSelectTab,
                onResumeSession: onResumeSession,
                toast: toast
            )
        }
    }

    // MARK: - Command Center Content

    private var commandCenterContent: some View {
        VStack(spacing: 0) {
            filterStrip
            Divider().background(MC.border)
            activeSessionsGrid
        }
    }

    private var filterStrip: some View {
        HStack(spacing: MC.Sp.xs) {
            filterPill(.all)
            if attentionCount > 0 { filterPill(.needsAttention) }
            if claudeCount > 0 { filterPill(.claude) }
            if dataSource.tabs.contains(where: { $0.isDead }) { filterPill(.dead) }
            if dataSource.tabs.contains(where: { $0.isPinned }) { filterPill(.pinned) }
            Spacer()
            if !searchQuery.isEmpty || activeFilter != .all {
                Text("\(filteredTabs.count)/\(dataSource.tabs.count)")
                    .font(MC.metaFont()).foregroundColor(MC.textDim)
            }
        }
        .padding(.horizontal, MC.Sp.xl).padding(.vertical, MC.Sp.sm)
        .background(MC.bgSurface.opacity(0.3))
    }

    private func filterPill(_ f: DashboardFilter) -> some View {
        let active = activeFilter == f
        let c = filterColor(f)
        return Button(action: { withAnimation(.easeInOut(duration: 0.12)) { activeFilter = f } }) {
            Text(f.rawValue)
                .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1)
                .foregroundColor(active ? c : MC.textMuted)
                .padding(.horizontal, MC.Sp.sm).padding(.vertical, 3)
                .background(active ? c.opacity(0.12) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(active ? c.opacity(0.25) : Color.clear))
        }.buttonStyle(.plain)
    }

    private func filterColor(_ f: DashboardFilter) -> Color {
        switch f {
        case .all: return MC.cyan; case .needsAttention: return MC.amber
        case .claude: return MC.violet; case .dead: return MC.rose; case .pinned: return MC.emerald
        }
    }

    // MARK: - Active Sessions Grid

    private var activeSessionsGrid: some View {
        HStack(spacing: 0) {
            sessionListSide
            if selectedTabId != nil {
                Divider().background(MC.border)
                detailPaneSide
            }
        }
    }

    private var sessionListSide: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MC.Sp.sm, pinnedViews: [.sectionHeaders]) {
                ForEach(Array(groupedSections.indices), id: \.self) { idx in
                    sectionBlock(groupedSections[idx])
                }
                if filteredTabs.isEmpty { emptyBlock }
            }
            .padding(.horizontal, MC.Sp.lg).padding(.vertical, MC.Sp.md)
        }
        .frame(maxWidth: .infinity)
    }

    private func sectionBlock(_ s: (group: VTTabGroup?, tabs: [VTTabItem])) -> some View {
        let collapsed = s.group.map { collapsedGroupIds.contains($0.id) } ?? false
        return Section {
            if !collapsed {
                twoColumnGrid(s.tabs)
            }
        } header: {
            groupHeader(s.group, count: s.tabs.count)
        }
    }

    private func twoColumnGrid(_ tabs: [VTTabItem]) -> some View {
        let hasSplit = selectedTabId != nil
        let pairs = hasSplit ? tabs.map { ($0, nil as VTTabItem?) }
            : stride(from: 0, to: tabs.count, by: 2).map { i in (tabs[i], i+1 < tabs.count ? tabs[i+1] : nil) }
        return VStack(spacing: MC.Sp.sm) {
            ForEach(Array(pairs.indices), id: \.self) { pi in
                HStack(spacing: MC.Sp.sm) {
                    liveCard(pairs[pi].0)
                    if let second = pairs[pi].1 { liveCard(second) }
                    else if !hasSplit { Spacer().frame(maxWidth: .infinity) }
                }
            }
        }
    }

    // MARK: - Live Session Card

    private func liveCard(_ tab: VTTabItem) -> some View {
        let isCurrent = tab.id == dataSource.activeTabId
        let isSel = selectedTabId == tab.id
        let accent = cardAccent(tab)
        let groupC = groupColorFor(tab)

        return Button(action: { selectedTabId = tab.id }) {
            VStack(alignment: .leading, spacing: MC.Sp.xs) {
                cardTitleRow(tab, isCurrent: isCurrent)
                cardMetaRow(tab)
                cardStatusRow(tab)
                if !tab.agents.isEmpty { cardAgentsSummary(tab) }
            }
            .padding(MC.Sp.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSel ? MC.bgElevated : MC.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(cardBorderOverlay(accent: accent, groupColor: groupC, selected: isSel, active: isCurrent))
            .mcCardShadow()
        }
        .buttonStyle(.plain)
        .onTapGesture(count: 2) { onSelectTab(tab.id) }
    }

    private func cardTitleRow(_ tab: VTTabItem, isCurrent: Bool) -> some View {
        HStack(spacing: MC.Sp.sm) {
            Circle().fill(cardAccent(tab)).frame(width: 8, height: 8)
                .shadow(color: cardAccent(tab).opacity(0.5), radius: 3)
            Text(tab.title.isEmpty ? (tab.shortCwd.isEmpty ? "Shell" : tab.shortCwd) : tab.title)
                .font(MC.titleFont())
                .foregroundColor(isCurrent ? MC.textBright : MC.textPrimary)
                .lineLimit(1)
            if isCurrent {
                Text("ACTIVE").font(MC.tinyFont()).foregroundColor(MC.cyan)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(MC.cyan.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Spacer()
            if !tab.gitBranch.isEmpty {
                Text(tab.gitBranch).font(MC.metaFont()).foregroundColor(MC.textDim).lineLimit(1)
            }
        }
    }

    private func cardMetaRow(_ tab: VTTabItem) -> some View {
        HStack(spacing: MC.Sp.sm) {
            if !tab.tildeAbbreviatedCwd.isEmpty {
                Text(tab.tildeAbbreviatedCwd).font(MC.metaFont()).foregroundColor(MC.textMuted).lineLimit(1)
            }
            Spacer()
            cardStatusLabel(tab)
        }
    }

    @ViewBuilder
    private func cardStatusRow(_ tab: VTTabItem) -> some View {
        if tab.hasPermissionAlert || tab.isBell || (tab.hasNewOutput && !tab.isActive) {
            HStack(spacing: MC.Sp.sm) {
                if tab.hasPermissionAlert {
                    HStack(spacing: 3) {
                        Circle().fill(MC.amber).frame(width: 5, height: 5).shadow(color: MC.amber.opacity(0.5), radius: 2)
                        Text("\(tab.permissionCount) perm").font(MC.tinyFont()).foregroundColor(MC.amber)
                    }
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(MC.amber.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 3))
                }
                if tab.isBell && !tab.hasPermissionAlert {
                    Image(systemName: "bell.fill").font(.system(size: 10)).foregroundColor(MC.amber)
                }
                Spacer()
            }
        }
    }

    private func cardAgentsSummary(_ tab: VTTabItem) -> some View {
        let running = tab.agents.filter { $0.status == .running }.count
        let perm = tab.agents.filter { $0.status == .waitingForPermission }.count
        let done = tab.agents.filter { $0.status == .completed }.count
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if perm > 0 { parts.append("\(perm) perm") }
        if done > 0 { parts.append("\(done) done") }
        return Text("\(tab.agents.count) agents: " + parts.joined(separator: ", "))
            .font(MC.tinyFont()).foregroundColor(MC.violet.opacity(0.7))
    }

    @ViewBuilder
    private func cardStatusLabel(_ tab: VTTabItem) -> some View {
        if tab.isDead {
            Text("DEAD \(tab.lastExitCode >= 0 ? "(\(tab.lastExitCode))" : "")")
                .font(MC.tinyFont()).foregroundColor(MC.rose)
        } else if tab.isClaude {
            Text("AI RUNNING").font(MC.tinyFont()).foregroundColor(MC.violet)
        } else if tab.isResumable {
            Text("RESUMABLE").font(MC.tinyFont()).foregroundColor(MC.violet.opacity(0.7))
        } else {
            Text("IDLE").font(MC.tinyFont()).foregroundColor(MC.textDim)
        }
    }

    private func cardAccent(_ tab: VTTabItem) -> Color {
        if tab.hasPermissionAlert || tab.isBell { return MC.amber }
        if tab.isClaude { return MC.violet }
        if tab.isDead { return MC.rose }
        if tab.id == dataSource.activeTabId { return MC.cyan }
        return MC.textDim
    }

    private func cardBorderOverlay(accent: Color, groupColor: Color, selected: Bool, active: Bool) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1).fill(groupColor).frame(width: 3)
            Spacer()
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? MC.cyan.opacity(0.4) : (active ? MC.cyan.opacity(0.2) : Color.clear), lineWidth: active ? 1.5 : 1)
        )
    }

    private func groupColorFor(_ tab: VTTabItem) -> Color {
        guard let gid = tab.groupId, let g = dataSource.groups.first(where: { $0.id == gid }) else { return MC.textDim }
        return g.color
    }

    // MARK: - Group Header

    private func groupHeader(_ group: VTTabGroup?, count: Int) -> some View {
        let collapsed = group.map { collapsedGroupIds.contains($0.id) } ?? false
        let color = group?.color ?? MC.textDim
        return Button(action: {
            guard let g = group else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                if collapsedGroupIds.contains(g.id) { collapsedGroupIds.remove(g.id) }
                else { collapsedGroupIds.insert(g.id) }
            }
        }) {
            HStack(spacing: MC.Sp.sm) {
                RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 3, height: 14)
                if group != nil {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .bold)).foregroundColor(MC.textMuted).frame(width: 10)
                }
                Text((group?.name ?? "Ungrouped").uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.5)
                    .foregroundColor(group != nil ? MC.textPrimary : MC.textMuted)
                Text("\(count)").font(MC.metaFont()).foregroundColor(MC.textDim)
                Rectangle().fill(MC.borderSubtle).frame(height: 1)
            }
            .padding(.vertical, MC.Sp.xs).padding(.horizontal, MC.Sp.xs)
            .background(MC.bgBase.opacity(0.9))
        }.buttonStyle(.plain)
    }

    // MARK: - Detail Pane

    @ViewBuilder
    private var detailPaneSide: some View {
        if let tabId = selectedTabId, let tab = dataSource.tabs.first(where: { $0.id == tabId }) {
            ScrollView {
                VStack(alignment: .leading, spacing: MC.Sp.lg) {
                    detailHeader(tab)
                    if tab.isClaude || tab.isResumable { sessionVitals }
                    if tab.isClaude { toolUsageBars }
                    if !tab.agents.isEmpty { agentsList(tab) }
                    if tab.isClaude && !sessionStats.recentActivity.isEmpty { activityTimeline }
                    detailActions(tab)
                    Spacer()
                }
                .padding(MC.Sp.lg)
            }
            .frame(minWidth: 300, maxWidth: 420)
            .background(MC.bgSurface)
        }
    }

    private func detailHeader(_ tab: VTTabItem) -> some View {
        VStack(alignment: .leading, spacing: MC.Sp.xs) {
            Text(tab.title.isEmpty ? (tab.shortCwd.isEmpty ? "Shell" : tab.shortCwd) : tab.title)
                .font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundColor(MC.textBright)
            if !tab.tildeAbbreviatedCwd.isEmpty {
                Text(tab.tildeAbbreviatedCwd).font(MC.labelFont()).foregroundColor(MC.textMuted)
            }
            HStack(spacing: MC.Sp.sm) {
                if !tab.gitBranch.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                        Text(tab.gitBranch).font(MC.labelFont())
                    }.foregroundColor(MC.textMuted)
                }
                cardStatusLabel(tab)
            }
        }
    }

    private var sessionVitals: some View {
        VStack(alignment: .leading, spacing: MC.Sp.sm) {
            sectionLabel("SESSION VITALS")
            vitalRow("Duration", sessionStats.durationString)
            vitalRow("Tokens", "\(MC.formatTokens(sessionStats.inputTokens)) in / \(MC.formatTokens(sessionStats.outputTokens)) out")
            vitalRow("Cost", sessionStats.costString)
            vitalRow("Context", sessionStats.contextFillString + " of " + (sessionStats.model.contains("opus") ? "1M" : "200k"))
            ContextFillBar(fillPercent: sessionStats.contextFillPercent)
                .padding(.vertical, MC.Sp.xs)
            vitalRow("Turns", "\(sessionStats.turnCount)")
            vitalRow("Model", sessionStats.model.replacingOccurrences(of: "claude-", with: ""))
        }
    }

    private func vitalRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(MC.labelFont()).foregroundColor(MC.textMuted).frame(width: 70, alignment: .leading)
            Text(value).font(MC.bodyFont()).foregroundColor(MC.textPrimary)
        }
    }

    private var toolUsageBars: some View {
        let sorted = sessionStats.toolCounts.sorted { $0.value > $1.value }
        let maxVal = sorted.first?.value ?? 1
        return VStack(alignment: .leading, spacing: MC.Sp.xs) {
            sectionLabel("TOOL USAGE")
            ForEach(sorted.prefix(8), id: \.key) { tool, count in
                toolBar(tool, count: count, max: maxVal)
            }
        }
    }

    private func toolBar(_ name: String, count: Int, max: Int) -> some View {
        HStack(spacing: MC.Sp.sm) {
            Text(name).font(MC.metaFont()).foregroundColor(MC.textMuted)
                .frame(width: 55, alignment: .trailing)
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 2)
                    .fill(MC.cyan.opacity(0.5))
                    .frame(width: geo.size.width * CGFloat(count) / CGFloat(Swift.max(max, 1)))
            }.frame(height: 10)
            Text("\(count)").font(MC.metaFont()).foregroundColor(MC.textPrimary).frame(width: 28, alignment: .trailing)
        }.frame(height: 14)
    }

    private func agentsList(_ tab: VTTabItem) -> some View {
        VStack(alignment: .leading, spacing: MC.Sp.xs) {
            sectionLabel("AGENTS")
            ForEach(tab.agents, id: \.id) { agent in
                Button(action: { onSelectAgent(agent.name, tab.id) }) {
                    HStack(spacing: MC.Sp.sm) {
                        Circle().fill(agentColor(agent.status)).frame(width: 6, height: 6)
                            .shadow(color: agentColor(agent.status).opacity(0.4), radius: 2)
                        Text(agent.name).font(MC.bodyFont()).foregroundColor(MC.textPrimary).lineLimit(1)
                        Spacer()
                        agentBadge(agent)
                    }
                    .padding(.vertical, 3).padding(.horizontal, MC.Sp.xs)
                }.buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func agentBadge(_ agent: VTAgentItem) -> some View {
        let c = agentColor(agent.status)
        switch agent.status {
        case .running: Text("RUN").font(MC.tinyFont()).foregroundColor(c)
        case .waitingForPermission:
            let tool = agent.pendingTool.components(separatedBy: " ").first ?? ""
            Text(tool.isEmpty ? "PERM" : tool.uppercased())
                .font(MC.tinyFont()).foregroundColor(c)
                .padding(.horizontal, 4).padding(.vertical, 1).background(c.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 2))
        case .completed: Text("DONE").font(MC.tinyFont()).foregroundColor(c)
        case .errored: Text("FAIL").font(MC.tinyFont()).foregroundColor(c)
        case .idle: Text("IDLE").font(MC.tinyFont()).foregroundColor(MC.textDim)
        }
    }

    private func agentColor(_ s: VTAgentItem.AgentStatus) -> Color {
        switch s {
        case .running: return MC.cyan; case .waitingForPermission: return MC.amber
        case .completed: return MC.emerald; case .errored: return MC.rose; case .idle: return MC.textDim
        }
    }

    private var activityTimeline: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionLabel("RECENT ACTIVITY")
            ForEach(sessionStats.recentActivity.suffix(8)) { entry in
                HStack(spacing: MC.Sp.sm) {
                    Text(entry.timeString).font(MC.metaFont()).foregroundColor(MC.textDim).frame(width: 55, alignment: .leading)
                    Text(entry.summary).font(MC.metaFont())
                        .foregroundColor(entry.isPermission ? MC.amber : MC.textMuted).lineLimit(1)
                }
            }
        }
    }

    private func detailActions(_ tab: VTTabItem) -> some View {
        HStack(spacing: MC.Sp.sm) {
            actionBtn("Switch to Tab", MC.cyan) { onSelectTab(tab.id) }
            if tab.isResumable { actionBtn("Resume", MC.violet) { onSelectTab(tab.id) } }
        }.padding(.top, MC.Sp.sm)
    }

    private func actionBtn(_ label: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(MC.bodyFont()).foregroundColor(color)
                .padding(.horizontal, MC.Sp.md).padding(.vertical, MC.Sp.sm)
                .background(color.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.25)))
        }.buttonStyle(.plain)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(MC.sectionFont()).tracking(1.5).foregroundColor(MC.textDim).padding(.bottom, 2)
    }

    private var emptyBlock: some View {
        VStack(spacing: MC.Sp.sm) {
            Text("_").font(.system(size: 28, weight: .light, design: .monospaced)).foregroundColor(MC.textDim)
            Text("NO MATCHING TERMINALS").font(MC.sectionFont()).tracking(2).foregroundColor(MC.textMuted)
        }.frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    // MARK: - Stats Loading

    private func loadStatsForSelected() {
        transcriptReader?.stopWatching()
        sessionStats.reset()
        guard let tabId = selectedTabId,
              let tab = dataSource.tabs.first(where: { $0.id == tabId }),
              let sid = tab.claudeSessionId,
              let url = DashboardTranscriptReader.findTranscript(sessionId: sid) else { return }
        let reader = DashboardTranscriptReader()
        reader.startWatching(transcriptURL: url, sessionId: sid, stats: sessionStats)
        transcriptReader = reader
    }
}
