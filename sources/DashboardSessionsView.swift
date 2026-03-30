import SwiftUI
import AppKit

// MARK: - Sort Order

private enum SessionSort: String, CaseIterable {
    case recent = "Recent"
    case cost = "Cost"
    case duration = "Duration"
}

// MARK: - Time Range Filter

private enum TimeRange: String, CaseIterable {
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case all = "All"
}

// MARK: - Project Color Cycling

private let projectAccentColors: [Color] = [
    MC.cyan, MC.emerald, MC.violet, MC.amber, MC.rose
]

private func projectColor(at index: Int) -> Color {
    projectAccentColors[index % projectAccentColors.count]
}

// MARK: - Main View

struct DashboardSessionsView: View {
    @ObservedObject var catalog: DashboardSessionCatalog
    var onSelectTab: (Int) -> Void
    var onResumeSession: (String, String) -> Void
    @ObservedObject var toast: ToastManager

    @State private var searchQuery = ""
    @State private var selectedSessionId: String? = nil
    @State private var sortBy: SessionSort = .cost
    @State private var selectedProjects: Set<String> = []
    @State private var timeRange: TimeRange = .thirtyDays

    var body: some View {
        mainLayout
            .background(MC.bgBase)
    }

    private var mainLayout: some View {
        HStack(spacing: 0) {
            mainScrollArea
            detailDividerAndPane
        }
    }

    private var mainScrollArea: some View {
        Group {
            if catalog.isLoading {
                SkeletonLoadingView()
            } else {
                mainScrollContent
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var mainScrollContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                toolbarSection
                divider(MC.border)
                projectCostHeroSection
                divider(MC.borderSubtle)
                cumulativeCostSection
                divider(MC.borderSubtle)
                analyticsCardsRow
                divider(MC.borderSubtle)
                sessionGroupsContent
            }
        }
    }

    @ViewBuilder
    private var detailDividerAndPane: some View {
        if selectedSessionId != nil {
            Divider().background(MC.border)
            sessionDetailPane
                .transition(.move(edge: .trailing))
        }
    }

    private func divider(_ color: Color) -> some View {
        Rectangle().fill(color).frame(height: 1)
    }
}

// MARK: - Toolbar

private extension DashboardSessionsView {

    var toolbarSection: some View {
        HStack(spacing: MC.Sp.sm) {
            searchField
            Spacer(minLength: MC.Sp.sm)
            sortPicker
            timeRangeButtons
        }
        .padding(.horizontal, MC.Sp.lg)
        .padding(.vertical, MC.Sp.sm)
        .background(MC.bgSurface.opacity(0.5))
    }

    var searchField: some View {
        HStack(spacing: 5) {
            Text(">")
                .font(MC.bodyFont())
                .foregroundColor(MC.cyan.opacity(0.5))
            TextField("search sessions\u{2026}", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(MC.bodyFont())
                .foregroundColor(MC.textPrimary)
                .frame(minWidth: 120, maxWidth: 200)
            if !searchQuery.isEmpty {
                Button(action: { searchQuery = "" }) {
                    Image(systemName: "xmark")
                        .font(MC.tinyFont())
                        .foregroundColor(MC.textMuted)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, MC.Sp.sm)
        .padding(.vertical, MC.Sp.xs)
        .background(MC.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(MC.border))
    }

    var sortPicker: some View {
        HStack(spacing: MC.Sp.xs) {
            Text("Sort")
                .font(MC.metaFont())
                .foregroundColor(MC.textDim)
            Picker("", selection: $sortBy) {
                ForEach(SessionSort.allCases, id: \.self) { s in
                    Text(s.rawValue).font(MC.labelFont()).tag(s)
                }
            }
            .labelsHidden()
            .frame(width: 90)
        }
    }

    var timeRangeButtons: some View {
        HStack(spacing: 2) {
            ForEach(TimeRange.allCases, id: \.self) { range in
                timeRangeButton(range)
            }
        }
    }

    func timeRangeButton(_ range: TimeRange) -> some View {
        let isActive = timeRange == range
        return Button(action: { timeRange = range }) {
            Text(range.rawValue)
                .font(MC.tinyFont())
                .foregroundColor(isActive ? MC.textBright : MC.textDim)
                .padding(.horizontal, MC.Sp.sm)
                .padding(.vertical, MC.Sp.xs)
                .background(isActive ? MC.cyan.opacity(0.15) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isActive ? MC.cyan.opacity(0.3) : MC.borderSubtle)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Data Helpers

private extension DashboardSessionsView {

    var filteredEntries: [SessionCatalogEntry] {
        var result = searchQuery.isEmpty ? catalog.entries : catalog.search(searchQuery)
        if !selectedProjects.isEmpty {
            result = result.filter { selectedProjects.contains($0.project) }
        }
        result = applyTimeRange(result)
        return sortEntries(result)
    }

    /// All entries within the time range, ignoring project filter (for "all" ghost line)
    var allEntriesInTimeRange: [SessionCatalogEntry] {
        var result = searchQuery.isEmpty ? catalog.entries : catalog.search(searchQuery)
        result = applyTimeRange(result)
        return result
    }

    func applyTimeRange(_ entries: [SessionCatalogEntry]) -> [SessionCatalogEntry] {
        switch timeRange {
        case .sevenDays:
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
            return entries.filter { ($0.startTime ?? .distantPast) >= cutoff }
        case .thirtyDays:
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
            return entries.filter { ($0.startTime ?? .distantPast) >= cutoff }
        case .all:
            return entries
        }
    }

    func sortEntries(_ entries: [SessionCatalogEntry]) -> [SessionCatalogEntry] {
        switch sortBy {
        case .recent:
            return entries.sorted { ($0.startTime ?? .distantPast) > ($1.startTime ?? .distantPast) }
        case .cost:
            return entries.sorted { ($0.estimatedCostUSD ?? 0) > ($1.estimatedCostUSD ?? 0) }
        case .duration:
            return entries.sorted { ($0.durationMinutes ?? 0) > ($1.durationMinutes ?? 0) }
        }
    }

    var todayFiltered: [SessionCatalogEntry] {
        filteredEntries.filter { $0.startTime.map { Calendar.current.isDateInToday($0) } ?? false }
    }

    var yesterdayFiltered: [SessionCatalogEntry] {
        filteredEntries.filter { $0.startTime.map { Calendar.current.isDateInYesterday($0) } ?? false }
    }

    var thisWeekFiltered: [SessionCatalogEntry] {
        let cal = Calendar.current
        guard let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start else { return [] }
        return filteredEntries.filter { entry in
            guard let t = entry.startTime else { return false }
            return t >= weekStart && !cal.isDateInToday(t) && !cal.isDateInYesterday(t)
        }
    }

    var olderFiltered: [SessionCatalogEntry] {
        let cal = Calendar.current
        guard let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start else {
            return filteredEntries.filter { $0.startTime == nil }
        }
        return filteredEntries.filter { ($0.startTime ?? .distantPast) < weekStart }
    }

    // MARK: - Breakdowns

    var projectCostBreakdown: [(project: String, cost: Double, count: Int)] {
        var map: [String: (cost: Double, count: Int)] = [:]
        let timeFiltered = applyTimeRange(
            searchQuery.isEmpty ? catalog.entries : catalog.search(searchQuery)
        )
        for e in timeFiltered where !e.project.isEmpty {
            let prev = map[e.project] ?? (cost: 0, count: 0)
            map[e.project] = (cost: prev.cost + (e.estimatedCostUSD ?? 0), count: prev.count + 1)
        }
        return map.map { (project: $0.key, cost: $0.value.cost, count: $0.value.count) }
            .sorted { $0.cost > $1.cost }
    }

    var totalCostInRange: Double {
        projectCostBreakdown.map(\.cost).reduce(0, +)
    }

    var totalSessionsInRange: Int {
        projectCostBreakdown.map(\.count).reduce(0, +)
    }

    var modelBreakdown: [(label: String, cost: Double)] {
        var map: [String: Double] = [:]
        for e in filteredEntries {
            let label = shortModelLabel(e.model)
            map[label, default: 0] += e.estimatedCostUSD ?? 0
        }
        return map.map { (label: $0.key, cost: $0.value) }
            .sorted { $0.cost > $1.cost }
    }

    var topToolsForChart: [(tool: String, count: Int)] {
        var map: [String: Int] = [:]
        for e in filteredEntries {
            for (tool, count) in (e.toolCounts ?? [:]) { map[tool, default: 0] += count }
        }
        return map.map { (tool: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
            .prefix(8).map { $0 }
    }

    // MARK: - Cumulative Cost Data

    func computeCumulativeCost(from entries: [SessionCatalogEntry]) -> [(date: Date, cumCost: Double, dailyCost: Double)] {
        let sorted = entries
            .filter { $0.startTime != nil && ($0.estimatedCostUSD ?? 0) > 0 }
            .sorted { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) }

        guard !sorted.isEmpty else { return [] }

        let cal = Calendar.current
        var daily: [(date: Date, cost: Double)] = []
        var currentDay: Date?
        var dayCost: Double = 0

        for entry in sorted {
            guard let t = entry.startTime else { continue }
            let dayStart = cal.startOfDay(for: t)
            if dayStart != currentDay {
                if let cd = currentDay {
                    daily.append((date: cd, cost: dayCost))
                }
                currentDay = dayStart
                dayCost = entry.estimatedCostUSD ?? 0
            } else {
                dayCost += entry.estimatedCostUSD ?? 0
            }
        }
        if let cd = currentDay {
            daily.append((date: cd, cost: dayCost))
        }

        var result: [(date: Date, cumCost: Double, dailyCost: Double)] = []
        var running: Double = 0
        for point in daily {
            running += point.cost
            result.append((date: point.date, cumCost: running, dailyCost: point.cost))
        }
        return result
    }

    var cumulativeCostDataFiltered: [(date: Date, cumCost: Double, dailyCost: Double)] {
        computeCumulativeCost(from: filteredEntries)
    }

    var cumulativeCostDataAll: [(date: Date, cumCost: Double, dailyCost: Double)] {
        computeCumulativeCost(from: allEntriesInTimeRange)
    }

    // MARK: - Utility

    func shortModelLabel(_ model: String?) -> String {
        guard let m = model, !m.isEmpty else { return "unknown" }
        if m.contains("opus") { return "opus-4-6" }
        if m.contains("sonnet") { return "sonnet" }
        if m.contains("haiku") { return "haiku" }
        return m.replacingOccurrences(of: "claude-", with: "")
    }
}

// MARK: - Section 2: Project Cost Breakdown (Hero)

private extension DashboardSessionsView {

    var projectCostHeroSection: some View {
        ProjectCostHeroView(
            breakdown: projectCostBreakdown,
            totalCost: totalCostInRange,
            selectedProjects: selectedProjects,
            onSelectProject: { proj in
                if selectedProjects.contains(proj) { selectedProjects.remove(proj) }
                else { selectedProjects.insert(proj) }
            },
            onClearProjects: { selectedProjects.removeAll() }
        )
    }
}

// MARK: - Project Cost Hero View (extracted struct)

private struct ProjectCostHeroView: View {
    let breakdown: [(project: String, cost: Double, count: Int)]
    let totalCost: Double
    let selectedProjects: Set<String>
    let onSelectProject: (String) -> Void
    let onClearProjects: () -> Void

    @State private var hoveredProject: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: MC.Sp.md) {
            heroHeader
            barChartContent
            filterChipsRow
        }
        .padding(.horizontal, MC.Sp.lg)
        .padding(.vertical, MC.Sp.md)
        .background(MC.bgSurface.opacity(0.3))
    }

    private var heroHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("PROJECTS BY COST")
                .font(MC.sectionFont())
                .tracking(1.5)
                .foregroundColor(MC.textDim)
            Spacer()
            Text(MC.formatCost(totalCost))
                .font(MC.heroFont())
                .foregroundColor(MC.textHero)
        }
    }

    @ViewBuilder
    private var barChartContent: some View {
        if breakdown.isEmpty {
            emptyProjectState
        } else {
            barChartBars
        }
    }

    private var emptyProjectState: some View {
        Text("No project data available")
            .font(MC.labelFont())
            .foregroundColor(MC.textDim)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, MC.Sp.lg)
    }

    private var barChartBars: some View {
        let maxCost = breakdown.first?.cost ?? 1
        return VStack(alignment: .leading, spacing: MC.Sp.xs) {
            ForEach(Array(breakdown.prefix(8).enumerated()), id: \.offset) { index, item in
                ProjectBarRow(
                    item: item,
                    index: index,
                    maxCost: maxCost,
                    totalCost: totalCost,
                    isSelected: selectedProjects.contains(item.project),
                    isHovered: hoveredProject == item.project,
                    onTap: { onSelectProject(item.project) },
                    onHover: { hovered in
                        hoveredProject = hovered ? item.project : nil
                    }
                )
            }
        }
    }

    private var filterChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MC.Sp.xs) {
                filterChip("All", isSelected: selectedProjects.isEmpty) {
                    onClearProjects()
                }
                ForEach(Array(breakdown.prefix(8).enumerated()), id: \.offset) { index, item in
                    filterChip(item.project, isSelected: selectedProjects.contains(item.project),
                               accentColor: projectColor(at: index)) {
                        onSelectProject(item.project)
                    }
                }
            }
        }
    }

    private func filterChip(_ name: String, isSelected: Bool, accentColor: Color = MC.cyan,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name)
                .font(MC.tinyFont())
                .foregroundColor(isSelected ? MC.textBright : MC.textMuted)
                .padding(.horizontal, MC.Sp.sm)
                .padding(.vertical, 3)
                .background(isSelected ? accentColor.opacity(0.15) : MC.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? accentColor.opacity(0.3) : MC.borderSubtle)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Project Bar Row (extracted for type-checker)

private struct ProjectBarRow: View {
    let item: (project: String, cost: Double, count: Int)
    let index: Int
    let maxCost: Double
    let totalCost: Double
    let isSelected: Bool
    let isHovered: Bool
    let onTap: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        Button(action: onTap) {
            barContent
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
    }

    private var accentColor: Color {
        projectColor(at: index)
    }

    private var barContent: some View {
        HStack(spacing: 0) {
            accentStripe
            barFillArea
            barLabels
        }
        .frame(height: 28)
        .background(isSelected ? MC.bgElevated : MC.bgSurface.opacity(isHovered ? 0.8 : 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? accentColor.opacity(0.4) : MC.borderSubtle)
        )
    }

    private var accentStripe: some View {
        Rectangle()
            .fill(accentColor)
            .frame(width: 3)
    }

    private var barFillArea: some View {
        GeometryReader { geo in
            let fraction = CGFloat(item.cost / Swift.max(maxCost, 0.01))
            let barWidth = geo.size.width * fraction
            Rectangle()
                .fill(accentColor.opacity(isHovered ? 0.25 : 0.12))
                .frame(width: max(barWidth, 2))
        }
    }

    private var barLabels: some View {
        HStack(spacing: MC.Sp.sm) {
            Text(item.project)
                .font(MC.labelFont())
                .foregroundColor(isSelected ? MC.textBright : MC.textPrimary)
                .lineLimit(1)
            Spacer(minLength: MC.Sp.xs)
            if isHovered {
                tooltipBadge
            }
            percentageLabel
            costLabel
        }
        .padding(.horizontal, MC.Sp.sm)
    }

    private var tooltipBadge: some View {
        Text("\(item.count) sessions \u{00B7} avg " + MC.formatCost(item.count > 0 ? item.cost / Double(item.count) : 0))
            .font(MC.tinyFont())
            .foregroundColor(MC.textMuted)
            .padding(.horizontal, MC.Sp.xs)
            .padding(.vertical, 2)
            .background(MC.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var percentageLabel: some View {
        let pct = totalCost > 0 ? (item.cost / totalCost * 100) : 0
        return Text(String(format: "%.0f%%", pct))
            .font(MC.metaFont())
            .foregroundColor(MC.textDim)
            .frame(width: 35, alignment: .trailing)
    }

    private var costLabel: some View {
        Text(MC.formatCost(item.cost))
            .font(MC.bodyFont())
            .foregroundColor(MC.amber)
            .frame(width: 70, alignment: .trailing)
    }
}

// MARK: - Section 3: Cumulative Cost Line Chart

private extension DashboardSessionsView {

    var cumulativeCostSection: some View {
        let filteredData = cumulativeCostDataFiltered
        let allData = cumulativeCostDataAll
        let totalFiltered = filteredData.last?.cumCost ?? 0
        return CumulativeCostLineChart(
            filteredData: filteredData,
            allData: allData,
            totalCost: totalFiltered,
            hasProjectFilter: !selectedProjects.isEmpty
        )
        .padding(.horizontal, MC.Sp.lg)
        .padding(.vertical, MC.Sp.md)
    }
}

// MARK: - Cumulative Cost Line Chart (extracted struct)

private struct CumulativeCostLineChart: View {
    let filteredData: [(date: Date, cumCost: Double, dailyCost: Double)]
    let allData: [(date: Date, cumCost: Double, dailyCost: Double)]
    let totalCost: Double
    let hasProjectFilter: Bool

    @State private var hoveredIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: MC.Sp.xs) {
            chartHeader
            chartArea
        }
        .padding(MC.Sp.md)
        .background(MC.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(MC.borderSubtle))
        .mcCardShadow()
    }

    private var chartHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("CUMULATIVE COST")
                .font(MC.metaFont())
                .tracking(1.5)
                .foregroundColor(MC.textDim)
            Spacer()
            Text(MC.formatCost(totalCost))
                .font(MC.heroFont())
                .foregroundColor(MC.textHero)
        }
    }

    private var chartArea: some View {
        ZStack(alignment: .topLeading) {
            chartCanvas
            chartHitTargets
            chartTooltipOverlay
            chartAxisLabels
        }
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var chartCanvas: some View {
        Canvas { ctx, size in
            let leftMargin: CGFloat = 50
            let bottomMargin: CGFloat = 16
            let drawRect = CGRect(x: leftMargin, y: 0,
                                  width: size.width - leftMargin,
                                  height: size.height - bottomMargin)
            drawGridLines(ctx: ctx, rect: drawRect)
            if hasProjectFilter {
                drawLine(ctx: ctx, data: allData, rect: drawRect, color: MC.textDim.opacity(0.3), fillOpacity: 0.03)
            }
            let lineColor = hasProjectFilter ? MC.amber : MC.cyan
            drawLine(ctx: ctx, data: filteredData, rect: drawRect, color: lineColor, fillOpacity: 0.12)
            drawHoveredPoint(ctx: ctx, rect: drawRect, lineColor: lineColor)
        }
    }

    private func drawGridLines(ctx: GraphicsContext, rect: CGRect) {
        let gridColor = MC.borderSubtle
        for i in 0...3 {
            let y = rect.minY + rect.height * CGFloat(i) / 3.0
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            ctx.stroke(path, with: .color(gridColor), lineWidth: 0.5)
        }
    }

    private func drawLine(ctx: GraphicsContext, data: [(date: Date, cumCost: Double, dailyCost: Double)],
                           rect: CGRect, color: Color, fillOpacity: Double) {
        guard data.count > 1 else { return }
        let maxCost = Swift.max(
            filteredData.map(\.cumCost).max() ?? 1,
            allData.map(\.cumCost).max() ?? 1
        )
        let count = data.count
        let stepX = rect.width / CGFloat(count - 1)

        // Gradient fill
        var fillPath = Path()
        fillPath.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for i in 0..<count {
            let x = rect.minX + CGFloat(i) * stepX
            let y = rect.maxY - CGFloat(data[i].cumCost / maxCost) * (rect.height - 8)
            fillPath.addLine(to: CGPoint(x: x, y: y))
        }
        fillPath.addLine(to: CGPoint(x: rect.minX + CGFloat(count - 1) * stepX, y: rect.maxY))
        fillPath.closeSubpath()

        let gradient = Gradient(colors: [color.opacity(fillOpacity), color.opacity(0.01)])
        ctx.fill(fillPath, with: .linearGradient(gradient,
                                                   startPoint: CGPoint(x: 0, y: rect.minY),
                                                   endPoint: CGPoint(x: 0, y: rect.maxY)))

        // Line
        var linePath = Path()
        for i in 0..<count {
            let x = rect.minX + CGFloat(i) * stepX
            let y = rect.maxY - CGFloat(data[i].cumCost / maxCost) * (rect.height - 8)
            if i == 0 { linePath.move(to: CGPoint(x: x, y: y)) }
            else { linePath.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.stroke(linePath, with: .color(color.opacity(0.8)), lineWidth: 2)
    }

    private func drawHoveredPoint(ctx: GraphicsContext, rect: CGRect, lineColor: Color) {
        guard let idx = hoveredIndex, idx < filteredData.count, filteredData.count > 1 else { return }
        let maxCost = Swift.max(
            filteredData.map(\.cumCost).max() ?? 1,
            allData.map(\.cumCost).max() ?? 1
        )
        let stepX = rect.width / CGFloat(filteredData.count - 1)
        let x = rect.minX + CGFloat(idx) * stepX
        let y = rect.maxY - CGFloat(filteredData[idx].cumCost / maxCost) * (rect.height - 8)

        // Vertical dashed line
        var dashPath = Path()
        dashPath.move(to: CGPoint(x: x, y: rect.minY))
        dashPath.addLine(to: CGPoint(x: x, y: rect.maxY))
        ctx.stroke(dashPath, with: .color(MC.textDim.opacity(0.3)),
                   style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

        // Dot
        let dotRect = CGRect(x: x - 4, y: y - 4, width: 8, height: 8)
        ctx.fill(Path(ellipseIn: dotRect), with: .color(lineColor))
        let glowRect = CGRect(x: x - 8, y: y - 8, width: 16, height: 16)
        ctx.fill(Path(ellipseIn: glowRect), with: .color(lineColor.opacity(0.2)))
    }

    private var chartHitTargets: some View {
        GeometryReader { geo in
            let leftMargin: CGFloat = 50
            let drawWidth = geo.size.width - leftMargin
            let count = filteredData.count
            if count > 1 {
                let stepX = drawWidth / CGFloat(count - 1)
                ZStack {
                    ForEach(0..<count, id: \.self) { i in
                        chartHitTarget(index: i, stepX: stepX, leftMargin: leftMargin, height: geo.size.height)
                    }
                }
            }
        }
    }

    private func chartHitTarget(index i: Int, stepX: CGFloat, leftMargin: CGFloat, height: CGFloat) -> some View {
        let w = max(stepX, 12)
        let x = leftMargin + CGFloat(i) * stepX - w / 2
        return Rectangle()
            .fill(Color.clear)
            .frame(width: w, height: height)
            .contentShape(Rectangle())
            .offset(x: x)
            .onHover { isHovered in hoveredIndex = isHovered ? i : nil }
    }

    @ViewBuilder
    private var chartTooltipOverlay: some View {
        if let idx = hoveredIndex, idx < filteredData.count {
            let point = filteredData[idx]
            let formatter = DateFormatter()
            let _ = formatter.dateFormat = "MMM d"
            let subtitle = "daily: " + MC.formatCost(point.dailyCost)
            ChartTooltip(
                formatter.string(from: point.date),
                value: MC.formatCost(point.cumCost),
                subtitle: subtitle
            )
            .offset(x: tooltipXOffset(idx), y: MC.Sp.xs)
        }
    }

    private func tooltipXOffset(_ idx: Int) -> CGFloat {
        guard filteredData.count > 1 else { return 30 }
        let fraction = CGFloat(idx) / CGFloat(filteredData.count - 1)
        // Keep tooltip from going off-screen
        if fraction > 0.75 { return -60 }
        return 30 + CGFloat(idx) * 4
    }

    private var chartAxisLabels: some View {
        GeometryReader { geo in
            let leftMargin: CGFloat = 50
            let bottomMargin: CGFloat = 16
            let drawHeight = geo.size.height - bottomMargin
            let maxCost = Swift.max(
                filteredData.map(\.cumCost).max() ?? 1,
                allData.map(\.cumCost).max() ?? 1
            )
            // Y-axis labels
            ForEach(0...3, id: \.self) { i in
                let costValue = maxCost * Double(3 - i) / 3.0
                let y = drawHeight * CGFloat(i) / 3.0
                Text(MC.formatCost(costValue))
                    .font(MC.tinyFont())
                    .foregroundColor(MC.textDim)
                    .frame(width: leftMargin - 2, alignment: .trailing)
                    .position(x: (leftMargin - 2) / 2, y: y)
            }
            // X-axis: first and last date
            if let first = filteredData.first, let last = filteredData.last, filteredData.count > 1 {
                let fmt = DateFormatter()
                let _ = fmt.dateFormat = "MMM d"
                Text(fmt.string(from: first.date))
                    .font(MC.tinyFont())
                    .foregroundColor(MC.textDim)
                    .position(x: leftMargin + 20, y: geo.size.height - 4)
                Text(fmt.string(from: last.date))
                    .font(MC.tinyFont())
                    .foregroundColor(MC.textDim)
                    .position(x: geo.size.width - 20, y: geo.size.height - 4)
            }
        }
    }
}

// MARK: - Section 4: Model + Tool Breakdown (2-column)

private extension DashboardSessionsView {

    var analyticsCardsRow: some View {
        HStack(alignment: .top, spacing: MC.Sp.md) {
            ModelBreakdownCardView(models: modelBreakdown)
            ToolBreakdownCardView(tools: topToolsForChart)
        }
        .padding(.horizontal, MC.Sp.lg)
        .padding(.vertical, MC.Sp.md)
    }
}

// MARK: - Model Breakdown Card

private struct ModelBreakdownCardView: View {
    let models: [(label: String, cost: Double)]
    @State private var hoveredIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: MC.Sp.sm) {
            breakdownSectionHeader("MODEL USAGE")
            modelBarsList
        }
        .padding(MC.Sp.md)
        .background(MC.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(MC.borderSubtle))
        .mcCardShadow()
    }

    private var modelBarsList: some View {
        let maxCost = models.first?.cost ?? 1
        return VStack(alignment: .leading, spacing: MC.Sp.xs) {
            ForEach(Array(models.prefix(5).enumerated()), id: \.offset) { index, item in
                modelBarRow(item: item, maxCost: maxCost, index: index)
            }
        }
    }

    private func modelBarRow(item: (label: String, cost: Double), maxCost: Double, index: Int) -> some View {
        let isHovered = hoveredIndex == index
        return HStack(spacing: MC.Sp.sm) {
            Text(item.label)
                .font(MC.metaFont())
                .foregroundColor(MC.textMuted)
                .frame(width: 70, alignment: .trailing)
                .lineLimit(1)
            modelBarFill(cost: item.cost, maxCost: maxCost, isHovered: isHovered)
            Text(MC.formatCost(item.cost))
                .font(MC.metaFont())
                .foregroundColor(isHovered ? MC.textBright : MC.textPrimary)
                .frame(width: 55, alignment: .trailing)
        }
        .frame(height: 14)
        .contentShape(Rectangle())
        .onHover { h in hoveredIndex = h ? index : nil }
    }

    private func modelBarFill(cost: Double, maxCost: Double, isHovered: Bool) -> some View {
        GeometryReader { geo in
            let fraction = CGFloat(cost / Swift.max(maxCost, 0.01))
            let w = geo.size.width * fraction
            RoundedRectangle(cornerRadius: 2)
                .fill(isHovered ? MC.violet : MC.violet.opacity(0.5))
                .frame(width: max(w, 2))
        }
        .frame(height: 10)
    }
}

// MARK: - Tool Breakdown Card

private struct ToolBreakdownCardView: View {
    let tools: [(tool: String, count: Int)]
    @State private var hoveredIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: MC.Sp.sm) {
            breakdownSectionHeader("TOP TOOLS")
            toolBarsList
        }
        .padding(MC.Sp.md)
        .background(MC.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(MC.borderSubtle))
        .mcCardShadow()
    }

    private var toolBarsList: some View {
        let maxCount = tools.first?.count ?? 1
        return VStack(alignment: .leading, spacing: MC.Sp.xs) {
            ForEach(Array(tools.prefix(8).enumerated()), id: \.offset) { index, item in
                toolBarRow(item: item, maxCount: maxCount, index: index)
            }
        }
    }

    private func toolBarRow(item: (tool: String, count: Int), maxCount: Int, index: Int) -> some View {
        let isHovered = hoveredIndex == index
        return HStack(spacing: MC.Sp.sm) {
            Text(item.tool)
                .font(MC.metaFont())
                .foregroundColor(MC.textMuted)
                .frame(width: 55, alignment: .trailing)
                .lineLimit(1)
            toolBarFill(count: item.count, maxCount: maxCount, isHovered: isHovered)
            Text("\(item.count)")
                .font(MC.tinyFont())
                .foregroundColor(isHovered ? MC.textBright : MC.textPrimary)
                .frame(width: 30, alignment: .trailing)
        }
        .frame(height: 14)
        .contentShape(Rectangle())
        .onHover { h in hoveredIndex = h ? index : nil }
    }

    private func toolBarFill(count: Int, maxCount: Int, isHovered: Bool) -> some View {
        GeometryReader { geo in
            let fraction = CGFloat(count) / CGFloat(Swift.max(maxCount, 1))
            let w = geo.size.width * fraction
            RoundedRectangle(cornerRadius: 2)
                .fill(isHovered ? MC.cyan : MC.cyan.opacity(0.4))
                .frame(width: max(w, 2))
        }
        .frame(height: 10)
    }
}

// Shared section header for breakdown cards
private func breakdownSectionHeader(_ title: String) -> some View {
    Text(title)
        .font(MC.metaFont())
        .tracking(1.5)
        .foregroundColor(MC.textDim)
}

// MARK: - Section 5: Session List (flat, sorted by cost/recency)

private extension DashboardSessionsView {

    var sessionGroupsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryBar
            ForEach(filteredEntries) { entry in
                sessionRow(entry)
            }
            if filteredEntries.isEmpty { emptyState }
        }
        .padding(.horizontal, MC.Sp.md)
        .padding(.vertical, MC.Sp.sm)
    }

    /// Lightweight inline summary replacing time group headers
    var summaryBar: some View {
        let today = catalog.todaySessions
        let todayCost = today.compactMap(\.estimatedCostUSD).reduce(0, +)
        let weekEntries = filteredEntries.filter {
            guard let t = $0.startTime else { return false }
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
            return t >= cutoff
        }
        let weekCost = weekEntries.compactMap(\.estimatedCostUSD).reduce(0, +)
        return HStack(spacing: MC.Sp.lg) {
            summaryPill("Today", count: today.count, cost: todayCost)
            summaryPill("7d", count: weekEntries.count, cost: weekCost)
            summaryPill("All", count: filteredEntries.count, cost: filteredEntries.compactMap(\.estimatedCostUSD).reduce(0, +))
            Spacer()
        }
        .padding(.vertical, MC.Sp.sm)
        .padding(.horizontal, MC.Sp.xs)
    }

    func summaryPill(_ label: String, count: Int, cost: Double) -> some View {
        HStack(spacing: MC.Sp.xs) {
            Text(label).font(MC.metaFont()).foregroundColor(MC.textMuted)
            Text("\(count)").font(MC.metaFont()).foregroundColor(MC.textPrimary)
            Text(MC.formatCost(cost)).font(MC.metaFont()).foregroundColor(MC.amber)
        }
        .padding(.horizontal, MC.Sp.sm)
        .padding(.vertical, 3)
        .background(MC.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Session Row (Prompt-First Card)

private extension DashboardSessionsView {

    func sessionRow(_ entry: SessionCatalogEntry) -> some View {
        let isSelected = selectedSessionId == entry.id
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedSessionId = selectedSessionId == entry.id ? nil : entry.id
            }
        }) {
            SessionRowCard(entry: entry, isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Session Row Card (extracted struct)

private struct SessionRowCard: View {
    let entry: SessionCatalogEntry
    let isSelected: Bool
    @State private var isHovered: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: MC.Sp.xs) {
            promptLine
            summaryLine
            metadataLine
            statsLine
            outcomeBadgeLine
        }
        .padding(.horizontal, MC.Sp.md)
        .padding(.vertical, MC.Sp.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(cardBorderOverlay)
        .mcCardShadow()
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { h in isHovered = h }
    }

    // MARK: Line 1: Status dot + prompt + relative time

    private var promptLine: some View {
        HStack(alignment: .top, spacing: MC.Sp.sm) {
            statusDot
            promptText
            Spacer(minLength: MC.Sp.xs)
            relativeTimeLabel
        }
    }

    private var statusDot: some View {
        let c = dotColor
        return Circle().fill(c)
            .frame(width: 8, height: 8)
            .shadow(color: entry.isActive ? c.opacity(0.6) : c.opacity(0.3),
                    radius: entry.isActive ? 4 : 2)
            .padding(.top, 3)
    }

    private var dotColor: Color {
        if entry.isActive { return MC.emerald }
        if entry.hasTranscript { return MC.cyan }
        return MC.textDim
    }

    private var promptText: some View {
        let prompt = entry.firstPrompt
        let truncated = prompt.count > 70 ? String(prompt.prefix(70)) + "\u{2026}" : prompt
        return Group {
            if !truncated.isEmpty {
                Text("\u{201C}" + truncated + "\u{201D}")
                    .font(MC.titleFont())
                    .foregroundColor(MC.textBright)
                    .lineLimit(2)
            } else {
                Text("(no prompt)")
                    .font(MC.titleFont())
                    .foregroundColor(MC.textDim)
                    .italic()
            }
        }
    }

    private var relativeTimeLabel: some View {
        Text(MC.relativeTime(entry.startTime))
            .font(MC.metaFont())
            .foregroundColor(MC.textMuted)
    }

    // MARK: Line 2: AI summary (only if facets exist)

    @ViewBuilder
    private var summaryLine: some View {
        if let summary = entry.summary, !summary.isEmpty {
            Text(summary)
                .font(MC.labelFont())
                .foregroundColor(MC.textSecondary)
                .lineLimit(1)
                .padding(.leading, 20)
        }
    }

    // MARK: Line 3: project, branch, model, duration, COST right-aligned

    private var metadataLine: some View {
        HStack(spacing: MC.Sp.sm) {
            metadataLeadingItems
            Spacer(minLength: 0)
            costLabel
        }
        .padding(.leading, 20)
    }

    private var metadataLeadingItems: some View {
        HStack(spacing: MC.Sp.sm) {
            if !entry.tildeAbbreviatedProjectPath.isEmpty {
                Text(entry.tildeAbbreviatedProjectPath)
                    .font(MC.metaFont())
                    .foregroundColor(MC.textMuted)
                    .lineLimit(1)
            }
            if let branch = entry.gitBranch, !branch.isEmpty {
                Text(branch)
                    .font(MC.metaFont())
                    .foregroundColor(MC.textDim)
                    .lineLimit(1)
            }
            if let model = entry.model, !model.isEmpty {
                modelBadge(model)
            }
            if !entry.durationString.isEmpty {
                Text(entry.durationString)
                    .font(MC.metaFont())
                    .foregroundColor(MC.textDim)
            }
        }
    }

    private func modelBadge(_ model: String) -> some View {
        let short = model
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "-20250514", with: "")
            .replacingOccurrences(of: "-20250301", with: "")
        return Text(short)
            .font(MC.metaFont())
            .foregroundColor(MC.violet.opacity(0.7))
            .lineLimit(1)
    }

    private var costLabel: some View {
        Group {
            if !entry.costString.isEmpty {
                Text(entry.costString)
                    .font(MC.bodyFont())
                    .foregroundColor(MC.amber)
            } else {
                Text("")
                    .font(MC.bodyFont())
            }
        }
        .frame(width: 70, alignment: .trailing)
    }

    // MARK: Line 4: context bar + code changes

    private var statsLine: some View {
        HStack(spacing: MC.Sp.sm) {
            contextBar
            codeChangesLabel
            Spacer()
        }
        .padding(.leading, 20)
    }

    @ViewBuilder
    private var contextBar: some View {
        let input = entry.inputTokens ?? 0
        if input > 0 {
            let pct = min(Double(input) / 1_000_000.0 * 100.0, 100.0)
            HStack(spacing: MC.Sp.xs) {
                ContextFillBar(fillPercent: pct)
                    .frame(width: 100)
                Text("ctx \(Int(pct))%")
                    .font(MC.tinyFont())
                    .foregroundColor(MC.textDim)
            }
        }
    }

    @ViewBuilder
    private var codeChangesLabel: some View {
        let added = entry.linesAdded ?? 0
        let removed = entry.linesRemoved ?? 0
        let files = entry.filesModified ?? 0
        if added > 0 || removed > 0 || files > 0 {
            HStack(spacing: MC.Sp.xs) {
                Text("+\(added)")
                    .font(MC.tinyFont())
                    .foregroundColor(MC.emerald)
                Text("-\(removed)")
                    .font(MC.tinyFont())
                    .foregroundColor(MC.rose)
                if files > 0 {
                    Text("\(files) files")
                        .font(MC.tinyFont())
                        .foregroundColor(MC.textDim)
                }
            }
        }
    }

    // MARK: Line 5: Outcome badge

    @ViewBuilder
    private var outcomeBadgeLine: some View {
        if let outcome = entry.outcome, !outcome.isEmpty {
            let color = MC.outcomeColor(outcome)
            let label = outcome.uppercased().replacingOccurrences(of: "_", with: " ")
            Text(label)
                .font(MC.tinyFont())
                .foregroundColor(color)
                .padding(.horizontal, MC.Sp.sm)
                .padding(.vertical, 2)
                .background(color.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .padding(.leading, 20)
        }
    }

    // MARK: Card chrome

    private var cardBackground: Color {
        if isSelected { return MC.bgElevated }
        if isHovered { return MC.bgSurface.opacity(0.8) }
        return MC.bgSurface
    }

    @ViewBuilder
    private var cardBorderOverlay: some View {
        if entry.isActive {
            RoundedRectangle(cornerRadius: 6)
                .stroke(MC.emerald.opacity(0.4), lineWidth: 1.5)
        } else if isSelected {
            RoundedRectangle(cornerRadius: 6)
                .stroke(MC.cyan.opacity(0.3), lineWidth: 1)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .stroke(MC.borderSubtle)
        }
    }
}

// MARK: - Empty State

private extension DashboardSessionsView {

    var emptyState: some View {
        VStack(spacing: MC.Sp.sm) {
            Text("_")
                .font(MC.heroFont())
                .foregroundColor(MC.textDim)
            Text("NO SESSIONS FOUND")
                .font(MC.labelFont())
                .tracking(2)
                .foregroundColor(MC.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Detail Pane

private extension DashboardSessionsView {

    @ViewBuilder
    var sessionDetailPane: some View {
        if let sid = selectedSessionId,
           let entry = catalog.entries.first(where: { $0.id == sid }) {
            SessionDetailPaneView(
                entry: entry,
                onSelectTab: onSelectTab,
                onResumeSession: onResumeSession,
                toast: toast
            )
            .frame(minWidth: 300, maxWidth: 420)
        }
    }
}

// MARK: - Session Detail Pane (extracted struct)

private struct SessionDetailPaneView: View {
    let entry: SessionCatalogEntry
    var onSelectTab: (Int) -> Void
    var onResumeSession: (String, String) -> Void
    @ObservedObject var toast: ToastManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MC.Sp.lg) {
                detailPromptSection
                minimalDataNote
                detailSummaryCard
                detailOutcomeBadge
                detailVitalsSection
                detailToolUsageSection
                detailCodeChangesSection
                detailActionsSection
                Spacer()
            }
            .padding(MC.Sp.lg)
        }
        .background(MC.bgSurface)
    }
}

// MARK: - Detail: Prompt Section

private extension SessionDetailPaneView {

    var detailPromptSection: some View {
        VStack(alignment: .leading, spacing: MC.Sp.sm) {
            if !entry.firstPrompt.isEmpty {
                ScrollView {
                    Text("\u{201C}" + entry.firstPrompt + "\u{201D}")
                        .font(MC.titleFont())
                        .foregroundColor(MC.textBright)
                }
                .frame(maxHeight: 120)
            }
            detailPromptMeta
        }
    }

    var detailPromptMeta: some View {
        HStack(spacing: MC.Sp.sm) {
            if !entry.project.isEmpty {
                Text(entry.tildeAbbreviatedProjectPath)
                    .font(MC.labelFont())
                    .foregroundColor(MC.textMuted)
            }
            if let branch = entry.gitBranch, !branch.isEmpty {
                Text(branch)
                    .font(MC.labelFont())
                    .foregroundColor(MC.textDim)
            }
            Spacer()
            detailStatusBadge
        }
    }

    @ViewBuilder
    var detailStatusBadge: some View {
        if entry.isActive {
            badgeLabel("ACTIVE", MC.emerald)
        } else if entry.dataTier == .historyOnly {
            badgeLabel("MINIMAL", MC.textDim)
        } else {
            badgeLabel("ENDED", MC.textDim)
        }
    }

    func badgeLabel(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(MC.tinyFont())
            .foregroundColor(color)
            .padding(.horizontal, MC.Sp.sm)
            .padding(.vertical, 2)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

// MARK: - Detail: Minimal Data Note

private extension SessionDetailPaneView {

    @ViewBuilder
    var minimalDataNote: some View {
        if entry.dataTier == .historyOnly {
            HStack(spacing: MC.Sp.sm) {
                Image(systemName: "info.circle")
                    .font(MC.metaFont())
                    .foregroundColor(MC.textDim)
                Text("Limited data available for this session")
                    .font(MC.metaFont())
                    .foregroundColor(MC.textDim)
            }
            .padding(.horizontal, MC.Sp.md)
            .padding(.vertical, MC.Sp.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MC.bgBase)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

// MARK: - Detail: AI Summary Card

private extension SessionDetailPaneView {

    @ViewBuilder
    var detailSummaryCard: some View {
        if let summary = entry.summary, !summary.isEmpty {
            VStack(alignment: .leading, spacing: MC.Sp.xs) {
                detailSectionLabel("SUMMARY")
                Text(summary)
                    .font(MC.labelFont())
                    .foregroundColor(MC.textPrimary)
                    .lineLimit(6)
                    .padding(MC.Sp.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MC.bgBase)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(MC.violet.opacity(0.2), lineWidth: 1)
                    )
            }
        }
    }
}

// MARK: - Detail: Outcome Badge

private extension SessionDetailPaneView {

    @ViewBuilder
    var detailOutcomeBadge: some View {
        if let outcome = entry.outcome, !outcome.isEmpty {
            let color = MC.outcomeColor(outcome)
            VStack(alignment: .leading, spacing: MC.Sp.xs) {
                detailSectionLabel("OUTCOME")
                Text(outcome.uppercased().replacingOccurrences(of: "_", with: " "))
                    .font(MC.metaFont())
                    .foregroundColor(color)
                    .padding(.horizontal, MC.Sp.md)
                    .padding(.vertical, MC.Sp.sm)
                    .background(color.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}

// MARK: - Detail: Vitals

private extension SessionDetailPaneView {

    var detailVitalsSection: some View {
        VStack(alignment: .leading, spacing: MC.Sp.xs) {
            detailSectionLabel("SESSION VITALS")
            vitalRow("Duration", entry.durationString.isEmpty ? "\u{2014}" : entry.durationString)
            vitalRowTokens
            vitalRowCacheBreakdown
            vitalRow("Cost", entry.costString.isEmpty ? "\u{2014}" : entry.costString)
            vitalRowContext
            vitalRowModel
            vitalRowTurns
        }
    }

    var vitalRowTokens: some View {
        let inStr = MC.formatTokens(entry.inputTokens ?? 0)
        let outStr = MC.formatTokens(entry.outputTokens ?? 0)
        let hasData = (entry.inputTokens ?? 0) > 0 || (entry.outputTokens ?? 0) > 0
        let value = hasData ? "\(inStr) in / \(outStr) out" : "\u{2014}"
        return vitalRow("Tokens", value)
    }

    @ViewBuilder
    var vitalRowCacheBreakdown: some View {
        let cr = entry.cacheReadTokens ?? 0
        let cc = entry.cacheCreationTokens ?? 0
        if cr > 0 || cc > 0 {
            let crStr = MC.formatTokens(cr)
            let ccStr = MC.formatTokens(cc)
            vitalRow("Cache", "\(crStr) read / \(ccStr) write")
        }
    }

    var vitalRowContext: some View {
        let input = entry.inputTokens ?? 0
        let pctValue: String
        if input > 0 {
            let pct = min(Double(input) / 1_000_000.0 * 100.0, 100.0)
            pctValue = String(format: "%.0f%%", pct)
        } else {
            pctValue = "\u{2014}"
        }
        return vitalRow("Context", pctValue)
    }

    var vitalRowModel: some View {
        let val: String
        if let model = entry.model, !model.isEmpty {
            val = model
                .replacingOccurrences(of: "claude-", with: "")
                .replacingOccurrences(of: "-20250514", with: "")
                .replacingOccurrences(of: "-20250301", with: "")
        } else {
            val = "\u{2014}"
        }
        return vitalRow("Model", val)
    }

    var vitalRowTurns: some View {
        let assistantCount = entry.assistantMessageCount ?? 0
        let userCount = entry.userMessageCount ?? 0
        let val = (assistantCount + userCount) > 0
            ? "\(userCount) user / \(assistantCount) assistant"
            : "\u{2014}"
        return vitalRow("Turns", val)
    }

    func vitalRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(MC.labelFont())
                .foregroundColor(MC.textMuted)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(MC.labelFont())
                .foregroundColor(MC.textPrimary)
        }
    }
}

// MARK: - Detail: Tool Usage

private extension SessionDetailPaneView {

    @ViewBuilder
    var detailToolUsageSection: some View {
        if let toolCounts = entry.toolCounts, !toolCounts.isEmpty {
            let sorted = toolCounts.sorted { $0.value > $1.value }
            let maxVal = sorted.first?.value ?? 1
            VStack(alignment: .leading, spacing: MC.Sp.xs) {
                detailSectionLabel("TOOL USAGE")
                ForEach(Array(sorted.prefix(10)), id: \.key) { tool, count in
                    detailToolBar(tool, count: count, max: maxVal)
                }
            }
        }
    }

    func detailToolBar(_ name: String, count: Int, max: Int) -> some View {
        HStack(spacing: MC.Sp.sm) {
            Text(name)
                .font(MC.metaFont())
                .foregroundColor(MC.textMuted)
                .frame(width: 60, alignment: .trailing)
                .lineLimit(1)
            GeometryReader { geo in
                let w = geo.size.width * CGFloat(count) / CGFloat(Swift.max(max, 1))
                RoundedRectangle(cornerRadius: 2)
                    .fill(MC.cyan.opacity(0.4))
                    .frame(width: Swift.max(w, 2))
            }
            .frame(height: 10)
            Text("\(count)")
                .font(MC.tinyFont())
                .foregroundColor(MC.textPrimary)
                .frame(width: 30, alignment: .trailing)
        }
        .frame(height: 14)
    }
}

// MARK: - Detail: Code Changes

private extension SessionDetailPaneView {

    @ViewBuilder
    var detailCodeChangesSection: some View {
        let added = entry.linesAdded ?? 0
        let removed = entry.linesRemoved ?? 0
        let files = entry.filesModified ?? 0
        let commits = entry.gitCommits ?? 0
        if added > 0 || removed > 0 || files > 0 {
            VStack(alignment: .leading, spacing: MC.Sp.xs) {
                detailSectionLabel("CODE CHANGES")
                HStack(spacing: MC.Sp.sm) {
                    Text("+\(added)")
                        .font(MC.bodyFont())
                        .foregroundColor(MC.emerald)
                    Text("-\(removed)")
                        .font(MC.bodyFont())
                        .foregroundColor(MC.rose)
                    Text("across \(files) files")
                        .font(MC.labelFont())
                        .foregroundColor(MC.textMuted)
                    if commits > 0 {
                        Text("\u{00B7} \(commits) commits")
                            .font(MC.labelFont())
                            .foregroundColor(MC.textDim)
                    }
                }
            }
        }
    }
}

// MARK: - Detail: Actions

private extension SessionDetailPaneView {

    var detailActionsSection: some View {
        VStack(alignment: .leading, spacing: MC.Sp.sm) {
            HStack(spacing: MC.Sp.sm) {
                primaryActionButton
                copySessionIdButton
            }
        }
        .padding(.top, MC.Sp.sm)
    }

    @ViewBuilder
    var primaryActionButton: some View {
        if entry.isActive, let tabId = entry.linkedTabId {
            actionButton("Switch to Tab", MC.cyan) {
                onSelectTab(tabId)
            }
        } else {
            actionButton("Resume in New Tab", MC.violet) {
                onResumeSession(entry.id, entry.projectPath)
            }
        }
    }

    var copySessionIdButton: some View {
        actionButton("Copy Session ID", MC.textMuted) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.id, forType: .string)
            toast.show("Copied!")
        }
    }

    func actionButton(_ label: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(MC.metaFont())
                .foregroundColor(color)
                .padding(.horizontal, MC.Sp.md)
                .padding(.vertical, MC.Sp.sm)
                .background(color.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(color.opacity(0.25)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Detail Section Label Helper

private extension SessionDetailPaneView {

    func detailSectionLabel(_ text: String) -> some View {
        Text(text)
            .font(MC.metaFont())
            .tracking(1.5)
            .foregroundColor(MC.textDim)
            .padding(.bottom, 2)
    }
}
