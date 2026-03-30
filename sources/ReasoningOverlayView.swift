import SwiftUI
import AppKit

// MARK: - Data Models

enum ReasoningEntryKind: Equatable {
    case thinking(String)
    case toolCall(name: String, args: String, icon: String)
    case toolResult(summary: String, detail: String)
}

class ReasoningEntry: ObservableObject, Identifiable {
    let id = UUID()
    let kind: ReasoningEntryKind
    let timestamp: Date

    init(kind: ReasoningEntryKind, timestamp: Date = Date()) {
        self.kind = kind
        self.timestamp = timestamp
    }

    var isThinking: Bool {
        if case .thinking = kind { return true }
        return false
    }
    var isToolCall: Bool {
        if case .toolCall = kind { return true }
        return false
    }
}

class ReasoningSession: ObservableObject, Identifiable {
    let id: String
    @Published var label: String
    @Published var entries: [ReasoningEntry] = []
    @Published var subagents: [ReasoningSubagent] = []

    init(id: String, label: String) {
        self.id = id
        self.label = label
    }

    var toolCallCount: Int {
        entries.filter { $0.isToolCall }.count
    }

    var lastThinkingLines: [String] {
        let thinkingEntries = entries.compactMap { entry -> String? in
            if case .thinking(let text) = entry.kind { return text }
            return nil
        }
        let allLines = thinkingEntries.flatMap { $0.components(separatedBy: "\n") }
        return Array(allLines.suffix(3))
    }
}

class ReasoningSubagent: ObservableObject, Identifiable {
    let id: String
    @Published var name: String
    @Published var entries: [ReasoningEntry] = []

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

@objc class ReasoningOverlayDataSource: NSObject, ObservableObject {
    @Published var sessions: [ReasoningSession] = []
    @Published var activeSessionId: String?
    @Published var isDarkMode: Bool = true

    var activeSession: ReasoningSession? {
        guard let activeId = activeSessionId else { return sessions.first }
        return sessions.first(where: { $0.id == activeId }) ?? sessions.first
    }

    @objc func addSession(id: String, label: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.sessions.contains(where: { $0.id == id }) {
                self.sessions.append(ReasoningSession(id: id, label: label))
            }
            if self.activeSessionId == nil {
                self.activeSessionId = id
            }
        }
    }

    @objc func appendThinking(_ text: String, sessionId: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let session = self.sessions.first(where: { $0.id == sessionId }) ?? {
                let s = ReasoningSession(id: sessionId, label: sessionId)
                self.sessions.append(s)
                if self.activeSessionId == nil { self.activeSessionId = sessionId }
                return s
            }()
            session.entries.append(ReasoningEntry(kind: .thinking(text)))
        }
    }

    @objc func appendToolCall(name: String, args: String, sessionId: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let session = self.sessions.first(where: { $0.id == sessionId }) else { return }
            let icon = ReasoningOverlayDataSource.iconForTool(name)
            session.entries.append(ReasoningEntry(kind: .toolCall(name: name, args: args, icon: icon)))
        }
    }

    @objc func appendToolResult(summary: String, detail: String, sessionId: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let session = self.sessions.first(where: { $0.id == sessionId }) else { return }
            session.entries.append(ReasoningEntry(kind: .toolResult(summary: summary, detail: detail)))
        }
    }

    @objc func addSubagent(id: String, name: String, sessionId: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let session = self.sessions.first(where: { $0.id == sessionId }) else { return }
            if !session.subagents.contains(where: { $0.id == id }) {
                session.subagents.append(ReasoningSubagent(id: id, name: name))
            }
        }
    }

    @objc func appendSubagentThinking(_ text: String, subagentId: String, sessionId: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let session = self.sessions.first(where: { $0.id == sessionId }),
                  let subagent = session.subagents.first(where: { $0.id == subagentId }) else { return }
            subagent.entries.append(ReasoningEntry(kind: .thinking(text)))
        }
    }

    @objc func appendSubagentToolCall(name: String, args: String, subagentId: String, sessionId: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let session = self.sessions.first(where: { $0.id == sessionId }),
                  let subagent = session.subagents.first(where: { $0.id == subagentId }) else { return }
            let icon = ReasoningOverlayDataSource.iconForTool(name)
            subagent.entries.append(ReasoningEntry(kind: .toolCall(name: name, args: args, icon: icon)))
        }
    }

    @objc func clearSession(_ sessionId: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sessions.first(where: { $0.id == sessionId })?.entries.removeAll()
            self.sessions.first(where: { $0.id == sessionId })?.subagents.removeAll()
        }
    }

    @objc func clearAll() {
        DispatchQueue.main.async { [weak self] in
            self?.sessions.removeAll()
            self?.activeSessionId = nil
        }
    }

    @objc func setTerminalBackgroundLuminance(_ luminance: CGFloat) {
        DispatchQueue.main.async { [weak self] in
            self?.isDarkMode = luminance < 0.5
        }
    }

    static func iconForTool(_ toolName: String) -> String {
        let lower = toolName.lowercased()
        if lower.contains("bash") || lower.contains("terminal") || lower.contains("exec") || lower.contains("command") {
            return "terminal"
        } else if lower.contains("read") || lower.contains("file") || lower.contains("cat") {
            return "doc.text"
        } else if lower.contains("search") || lower.contains("grep") || lower.contains("find") || lower.contains("glob") {
            return "magnifyingglass"
        } else if lower.contains("edit") || lower.contains("write") || lower.contains("patch") || lower.contains("replace") {
            return "pencil"
        } else if lower.contains("web") || lower.contains("fetch") || lower.contains("url") || lower.contains("http") {
            return "globe"
        } else if lower.contains("git") || lower.contains("branch") || lower.contains("diff") {
            return "arrow.triangle.branch"
        } else if lower.contains("agent") || lower.contains("task") || lower.contains("spawn") {
            return "person.2"
        }
        return "gear"
    }
}

// MARK: - Reasoning Overlay View

struct ReasoningOverlayView: View {
    @ObservedObject var dataSource: ReasoningOverlayDataSource
    @State private var isExpanded = true
    @State private var isAtBottom = true
    @State private var selectedSubagentId: String?
    @State private var expandedResultIds: Set<UUID> = []

    private var panelColors: PanelColors {
        dataSource.isDarkMode ? .dark : .light
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            if isExpanded {
                expandedContent
            } else {
                condensedContent
            }
        }
        .background(Color(red: 0x1C/255, green: 0x21/255, blue: 0x2A/255))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: -2)
        .frame(maxWidth: .infinity, alignment: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reasoning overlay panel")
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: DS.Spacing.lg) {
            Image(systemName: "brain")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DS.Colors.accentPurple)

            Text("Reasoning")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(panelColors.textPrimary)

            if dataSource.sessions.count >= 2 {
                sessionPicker
            }

            Spacer()

            Button(action: {
                NSLog("AiTerm: Chevron tapped! isExpanded was \(isExpanded), toggling to \(!isExpanded)")
                isExpanded.toggle()
            }) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(panelColors.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .background(panelColors.hoverBG)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse panel" : "Expand panel")
        }
        .padding(.horizontal, DS.Spacing.xl)
        .padding(.vertical, DS.Spacing.lg)
        .background(panelColors.headerBG)
        .overlay(
            Rectangle().fill(panelColors.border).frame(height: 1),
            alignment: .bottom
        )
    }

    private var sessionPicker: some View {
        Picker("", selection: Binding(
            get: { dataSource.activeSessionId ?? "" },
            set: { dataSource.activeSessionId = $0 }
        )) {
            ForEach(dataSource.sessions) { session in
                Text(session.label).tag(session.id)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: 120)
        .accessibilityLabel("Session picker")
    }

    // MARK: - Condensed Mode

    private var condensedContent: some View {
        Group {
            if let session = dataSource.activeSession {
                Button(action: { isExpanded = true }) {
                    HStack(spacing: DS.Spacing.lg) {
                        VStack(alignment: .leading, spacing: 2) {
                            let lines = session.lastThinkingLines
                            if lines.isEmpty {
                                Text("No reasoning yet")
                                    .font(.system(size: 11))
                                    .foregroundColor(panelColors.textTertiary)
                                    .italic()
                            } else {
                                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 11))
                                        .foregroundColor(panelColors.textSecondary)
                                        .italic()
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                        if session.toolCallCount > 0 {
                            Text("\(session.toolCallCount)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(panelColors.textPrimary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(DS.Colors.accentBlue.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, DS.Spacing.xl)
                    .padding(.vertical, DS.Spacing.lg)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Expand reasoning, \(session.toolCallCount) tool calls")
            }
        }
    }

    // MARK: - Minimal Pill

    var minimalPill: some View {
        let session = dataSource.activeSession
        let toolCount = session?.toolCallCount ?? 0
        return Button(action: { isExpanded = true }) {
            HStack(spacing: DS.Spacing.md) {
                Image(systemName: "brain")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.accentPurple)
                Text("Thinking\u{2026}")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(panelColors.textPrimary)
                if toolCount > 0 {
                    Text("\(toolCount) tool calls")
                        .font(.system(size: 10))
                        .foregroundColor(panelColors.textSecondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(panelColors.textTertiary)
            }
            .padding(.horizontal, DS.Spacing.xl)
            .padding(.vertical, DS.Spacing.md)
            .background(panelColors.headerBG)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Expand reasoning panel")
    }

    // MARK: - Expanded Mode

    private var expandedContent: some View {
        VStack(spacing: 0) {
            // Subagent tabs
            if let session = dataSource.activeSession, !session.subagents.isEmpty {
                subagentTabs(session: session)
            }

            // Entries list
            ZStack(alignment: .bottom) {
                entriesList
                if !isAtBottom {
                    jumpToLatestPill
                }
            }
        }
    }

    private func subagentTabs(session: ReasoningSession) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.sm) {
                subagentTab(label: "Main", id: nil)
                ForEach(session.subagents) { sub in
                    subagentTab(label: sub.name, id: sub.id)
                }
            }
            .padding(.horizontal, DS.Spacing.xl)
            .padding(.vertical, DS.Spacing.md)
        }
        .background(panelColors.headerBG.opacity(0.5))
        .overlay(
            Rectangle().fill(panelColors.border).frame(height: 1),
            alignment: .bottom
        )
    }

    private func subagentTab(label: String, id: String?) -> some View {
        let isSelected = (selectedSubagentId == id)
        return Button(action: { selectedSubagentId = id }) {
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? panelColors.textPrimary : panelColors.textSecondary)
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSelected ? panelColors.activeBG : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) tab\(isSelected ? ", selected" : "")")
    }

    private var entriesList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: DS.Spacing.sm) {
                    let entries = currentEntries
                    ForEach(entries) { entry in
                        entryCard(entry)
                            .id(entry.id)
                    }
                    // Invisible anchor for scroll tracking
                    Color.clear.frame(height: 1).id("scroll-bottom")
                }
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.lg)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ScrollOffsetKey.self,
                            value: geo.frame(in: .named("reasoning-scroll")).maxY
                        )
                    }
                )
            }
            .coordinateSpace(name: "reasoning-scroll")
            .onPreferenceChange(ScrollOffsetKey.self) { maxY in
                // If the bottom of content is within a reasonable threshold of the visible area,
                // consider us "at bottom"
                isAtBottom = maxY < 600
            }
            .onChange(of: currentEntries.count) { _ in
                if isAtBottom {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        proxy.scrollTo("scroll-bottom", anchor: .bottom)
                    }
                }
            }
            .onChange(of: selectedSubagentId) { _ in
                // Reset scroll when switching subagent tabs
                isAtBottom = true
                proxy.scrollTo("scroll-bottom", anchor: .bottom)
            }
        }
        .accessibilityLabel("Reasoning entries")
    }

    private var currentEntries: [ReasoningEntry] {
        guard let session = dataSource.activeSession else { return [] }
        if let subId = selectedSubagentId,
           let sub = session.subagents.first(where: { $0.id == subId }) {
            return sub.entries
        }
        return session.entries
    }

    private var jumpToLatestPill: some View {
        Button(action: {
            isAtBottom = true
            // The onChange handler will handle scrolling
        }) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 9, weight: .bold))
                Text("Jump to latest")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(panelColors.textPrimary)
            .padding(.horizontal, DS.Spacing.xl)
            .padding(.vertical, DS.Spacing.md)
            .background(
                Capsule()
                    .fill(panelColors.pillBG)
                    .shadow(color: Color.black.opacity(0.3), radius: 4, y: 2)
            )
        }
        .buttonStyle(.plain)
        .padding(.bottom, DS.Spacing.lg)
        .accessibilityLabel("Jump to latest entry")
    }

    // MARK: - Entry Cards

    @ViewBuilder
    private func entryCard(_ entry: ReasoningEntry) -> some View {
        switch entry.kind {
        case .thinking(let text):
            thinkingCard(text: text)
        case .toolCall(let name, let args, let icon):
            toolCallCard(name: name, args: args, icon: icon)
        case .toolResult(let summary, let detail):
            toolResultCard(entry: entry, summary: summary, detail: detail)
        }
    }

    private func thinkingCard(text: String) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.lg) {
            Rectangle()
                .fill(panelColors.thinkingAccent)
                .frame(width: 2)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(panelColors.textSecondary)
                .italic()
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(panelColors.cardBG)
        )
        .accessibilityLabel("Thinking: \(text)")
    }

    private func toolCallCard(name: String, args: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.accentBlue)
                    .frame(width: 16, height: 16)
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(panelColors.textPrimary)
                Spacer()
            }
            if !args.isEmpty {
                Text(args)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(panelColors.textTertiary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(panelColors.cardBG)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(DS.Colors.accentBlue.opacity(0.2), lineWidth: 1)
                )
        )
        .accessibilityLabel("Tool call: \(name), arguments: \(args)")
    }

    private func toolResultCard(entry: ReasoningEntry, summary: String, detail: String) -> some View {
        let isResultExpanded = expandedResultIds.contains(entry.id)
        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Button(action: {
                if isResultExpanded {
                    expandedResultIds.remove(entry.id)
                } else {
                    expandedResultIds.insert(entry.id)
                }
            }) {
                HStack(spacing: DS.Spacing.md) {
                    Image(systemName: isResultExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(panelColors.textTertiary)
                        .frame(width: 12)
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.accentGreen)
                    Text(summary)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(panelColors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isResultExpanded && !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(panelColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, DS.Spacing.xxl)
            }
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(panelColors.cardBG.opacity(0.5))
        )
        .accessibilityLabel("Tool result: \(summary)")
    }

    // MARK: - Helpers

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

// MARK: - Scroll Offset Tracking

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Panel Color Tokens

struct PanelColors {
    let background: Color
    let headerBG: Color
    let cardBG: Color
    let pillBG: Color
    let activeBG: Color
    let hoverBG: Color
    let border: Color
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let thinkingAccent: Color

    static let dark = PanelColors(
        background: Color(red: 0x1C/255, green: 0x21/255, blue: 0x2A/255).opacity(0.95),
        headerBG: Color(red: 0x16/255, green: 0x1A/255, blue: 0x22/255),
        cardBG: Color.white.opacity(0.05),
        pillBG: Color(red: 0x2A/255, green: 0x30/255, blue: 0x3C/255),
        activeBG: DS.Colors.activeBG,
        hoverBG: DS.Colors.hoverBG,
        border: DS.Colors.border,
        textPrimary: DS.Colors.textPrimary,
        textSecondary: DS.Colors.textSecondary,
        textTertiary: DS.Colors.textTertiary,
        thinkingAccent: DS.Colors.textTertiary.opacity(0.5)
    )

    static let light = PanelColors(
        background: Color(red: 0xF5/255, green: 0xF5/255, blue: 0xF7/255).opacity(0.95),
        headerBG: Color(red: 0xEB/255, green: 0xEB/255, blue: 0xEF/255),
        cardBG: Color.white.opacity(0.8),
        pillBG: Color(red: 0xE0/255, green: 0xE0/255, blue: 0xE5/255),
        activeBG: Color.black.opacity(0.08),
        hoverBG: Color.black.opacity(0.04),
        border: Color.black.opacity(0.1),
        textPrimary: Color(red: 0x1A/255, green: 0x1A/255, blue: 0x1A/255),
        textSecondary: Color(red: 0x55/255, green: 0x55/255, blue: 0x60/255),
        textTertiary: Color(red: 0x88/255, green: 0x88/255, blue: 0x90/255),
        thinkingAccent: Color(red: 0x88/255, green: 0x88/255, blue: 0x90/255).opacity(0.5)
    )
}
