import SwiftUI

// MARK: - Design Tokens (mirrors DashboardView.swift Dash enum)

private enum ADash {
    static let bgBase = Color(red: 0x0C/255, green: 0x0E/255, blue: 0x14/255)
    static let bgSurface = Color(red: 0x12/255, green: 0x15/255, blue: 0x1E/255)
    static let bgCard = Color(red: 0x18/255, green: 0x1C/255, blue: 0x27/255)

    static let textBright = Color(red: 0xF0/255, green: 0xF4/255, blue: 0xFC/255)
    static let textPrimary = Color(red: 0xC8/255, green: 0xCE/255, blue: 0xDA/255)
    static let textMuted = Color(red: 0x6B/255, green: 0x73/255, blue: 0x86/255)
    static let textDim = Color(red: 0x40/255, green: 0x46/255, blue: 0x56/255)

    static let cyan = Color(red: 0x22/255, green: 0xD3/255, blue: 0xEE/255)
    static let violet = Color(red: 0xA7/255, green: 0x8B/255, blue: 0xFA/255)
    static let emerald = Color(red: 0x34/255, green: 0xD3/255, blue: 0x99/255)
    static let rose = Color(red: 0xFB/255, green: 0x71/255, blue: 0x85/255)
    static let amber = Color(red: 0xFB/255, green: 0xBF/255, blue: 0x24/255)

    static let border = Color.white.opacity(0.06)
    static let borderSubtle = Color.white.opacity(0.03)
}

// MARK: - Period Selector

private enum AnalyticsPeriod: String, CaseIterable {
    case week = "7d"
    case month = "30d"
    case all = "All"

    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .all: return nil
        }
    }
}

// MARK: - Stats Cache Model

private struct StatsCacheData {
    var dailyActivity: [DailyActivityEntry] = []
    var modelUsage: [String: ModelUsageEntry] = [:]
    var hourCounts: [Int: Int] = [:]
    var totalSessions: Int = 0
    var totalMessages: Int = 0
    var longestSession: LongestSessionEntry?

    struct DailyActivityEntry {
        let date: String
        let messageCount: Int
        let sessionCount: Int
        let toolCallCount: Int
    }

    struct ModelUsageEntry {
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadInputTokens: Int
        let cacheCreationInputTokens: Int
        let costUSD: Double
    }

    struct LongestSessionEntry {
        let sessionId: String
        let duration: Int       // seconds
        let messageCount: Int
    }
}

// MARK: - Main View

struct DashboardAnalyticsView: View {
    @ObservedObject var catalog: DashboardSessionCatalog
    @State private var period: AnalyticsPeriod = .month
    @State private var statsCache: StatsCacheData? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                periodHeader
                dailyCostChart
                middleRow
                bottomRow
                recordsCard
            }
            .padding(20)
        }
        .background(ADash.bgBase)
        .onAppear { loadStatsCache() }
    }

    // MARK: - Period Header

    private var periodHeader: some View {
        HStack {
            Text("Period:")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(ADash.textMuted)
            ForEach(AnalyticsPeriod.allCases, id: \.self) { p in
                periodButton(p)
            }
            Spacer()
            Text("Total: " + totalCostLabel)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(ADash.textBright)
        }
    }

    private func periodButton(_ p: AnalyticsPeriod) -> some View {
        let active = period == p
        return Button(action: { period = p }) {
            Text(p.rawValue)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(active ? ADash.cyan : ADash.textMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(active ? ADash.cyan.opacity(0.12) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(active ? ADash.cyan.opacity(0.25) : Color.clear))
        }.buttonStyle(.plain)
    }

    /// Accurate total cost computed from stats-cache (includes cache tokens which dominate cost).
    /// For sub-periods, pro-rates based on the fraction of sessions in that period.
    private var totalCostLabel: String {
        guard let cache = statsCache, !cache.modelUsage.isEmpty else {
            let cost = filteredEntries.compactMap(\.estimatedCostUSD).reduce(0, +)
            return cost < 0.01 ? "$0.00" : String(format: "$%.2f", cost)
        }

        // Compute ALL-TIME cost from stats-cache (accurate, includes cache tokens)
        let allTimeCost = cache.modelUsage.reduce(0.0) { sum, entry in
            let (name, usage) = entry
            return sum + ModelPricing.turnCost(
                model: name, input: usage.inputTokens, output: usage.outputTokens,
                cacheRead: usage.cacheReadInputTokens, cacheCreate: usage.cacheCreationInputTokens
            )
        }

        if period == .all {
            return "$" + String(format: "%.2f", allTimeCost)
        }

        // For sub-periods: pro-rate based on sessions in period vs total sessions
        let totalSessions = max(cache.totalSessions, catalog.entries.count, 1)
        let periodSessions = filteredEntries.count
        let ratio = Double(periodSessions) / Double(totalSessions)
        let estimated = allTimeCost * ratio
        return "~$" + String(format: "%.2f", estimated)
    }

    // MARK: - Filtered Entries

    private var filteredEntries: [SessionCatalogEntry] {
        guard let days = period.days else { return catalog.entries }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return catalog.entries.filter { ($0.startTime ?? .distantPast) >= cutoff }
    }

    // MARK: - Daily Cost Chart

    private var dailyCostChart: some View {
        analyticsCard(title: "DAILY COST") {
            dailyCostCanvas
        }
    }

    private var dailyCostCanvas: some View {
        let buckets = dailyCostBuckets()
        let maxVal = buckets.map(\.cost).max() ?? 1.0
        let clamped = max(maxVal, 0.01)

        return VStack(spacing: 0) {
            Canvas { ctx, size in
                drawDailyCostBars(ctx: ctx, size: size, buckets: buckets, maxVal: clamped)
            }
            .frame(height: 120)

            // X-axis labels
            dailyCostXAxis(buckets: buckets)
        }
    }

    private func dailyCostXAxis(buckets: [DailyCostBucket]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(buckets.indices), id: \.self) { i in
                Text(buckets[i].label)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(ADash.textDim)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 2)
    }

    private func drawDailyCostBars(ctx: GraphicsContext, size: CGSize, buckets: [DailyCostBucket], maxVal: Double) {
        let count = buckets.count
        guard count > 0 else { return }

        drawGridLines(ctx: ctx, size: size, divisions: 4)
        drawYAxisLabels(ctx: ctx, size: size, maxVal: maxVal, divisions: 4, prefix: "$")

        let chartLeft: CGFloat = 40
        let chartWidth = size.width - chartLeft - 8
        let gap: CGFloat = 2
        let barWidth = chartWidth / CGFloat(count) - gap

        for i in 0..<count {
            let fraction = CGFloat(buckets[i].cost / maxVal)
            let barH = fraction * (size.height - 4)
            let x = chartLeft + (chartWidth / CGFloat(count)) * CGFloat(i) + gap / 2
            let y = size.height - barH
            let rect = CGRect(x: x, y: y, width: max(barWidth, 2), height: barH)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(ADash.cyan.opacity(0.7)))
            ctx.fill(
                Path(roundedRect: CGRect(x: x, y: y, width: max(barWidth, 2), height: min(barH, 3)), cornerRadius: 1),
                with: .color(ADash.cyan)
            )
        }
    }

    // MARK: - Middle Row (Model Breakdown + Time of Day)

    private var middleRow: some View {
        HStack(alignment: .top, spacing: 12) {
            modelBreakdownCard
            timeOfDayCard
        }
    }

    // MARK: - Model Breakdown

    private var modelBreakdownCard: some View {
        analyticsCard(title: "MODEL BREAKDOWN") {
            modelBreakdownContent
        }
    }

    private var modelBreakdownContent: some View {
        let models = computeModelBreakdown()
        let maxCost = models.first?.cost ?? 1.0
        let totalCost = models.map(\.cost).reduce(0, +)
        let clamped = max(maxCost, 0.01)
        let clampedTotal = max(totalCost, 0.01)

        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(models.prefix(6).enumerated()), id: \.offset) { idx, entry in
                modelRow(entry: entry, maxCost: clamped, totalCost: clampedTotal, idx: idx)
            }
            if models.isEmpty {
                Text("No model data")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(ADash.textDim)
            }
        }
    }

    private func modelRow(entry: ModelBreakdownEntry, maxCost: Double, totalCost: Double, idx: Int) -> some View {
        let pct = Int(entry.cost / totalCost * 100.0)
        let colors: [Color] = [ADash.cyan, ADash.violet, ADash.emerald, ADash.amber, ADash.rose]
        let barColor = colors[idx % colors.count]

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.shortName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(ADash.textPrimary)
                    .frame(width: 90, alignment: .leading)
                    .lineLimit(1)
                Text("\(pct)%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(ADash.textMuted)
                Spacer()
            }
            modelBarRow(entry: entry, maxCost: maxCost, barColor: barColor)
        }
    }

    private func modelBarRow(entry: ModelBreakdownEntry, maxCost: Double, barColor: Color) -> some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                let frac = CGFloat(entry.cost / maxCost)
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor.opacity(0.6))
                    .frame(width: geo.size.width * frac)
            }
            .frame(height: 8)
            Text(String(format: "$%.2f", entry.cost))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(ADash.textBright)
                .frame(width: 60, alignment: .trailing)
        }
    }

    // MARK: - Time of Day

    private var timeOfDayCard: some View {
        analyticsCard(title: "TIME OF DAY") {
            timeOfDayCanvas
        }
    }

    private var timeOfDayCanvas: some View {
        let hours = hourCountsData()
        let maxVal = hours.values.max() ?? 1

        return VStack(spacing: 0) {
            Canvas { ctx, size in
                drawHourBars(ctx: ctx, size: size, hours: hours, maxVal: max(maxVal, 1))
            }
            .frame(height: 100)

            hourXAxis
        }
    }

    private var hourXAxis: some View {
        HStack(spacing: 0) {
            ForEach([0, 3, 6, 9, 12, 15, 18, 21], id: \.self) { h in
                Text("\(h)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(ADash.textDim)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 2)
    }

    private func drawHourBars(ctx: GraphicsContext, size: CGSize, hours: [Int: Int], maxVal: Int) {
        let barWidth = size.width / 24.0 - 2
        let effectiveWidth = max(barWidth, 2)

        drawGridLines(ctx: ctx, size: size, divisions: 3)

        for h in 0..<24 {
            let count = hours[h] ?? 0
            let fraction = CGFloat(count) / CGFloat(maxVal)
            let barH = fraction * (size.height - 4)
            let x = (size.width / 24.0) * CGFloat(h) + 1
            let y = size.height - barH
            let rect = CGRect(x: x, y: y, width: effectiveWidth, height: barH)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(ADash.violet.opacity(0.6)))
            ctx.fill(
                Path(roundedRect: CGRect(x: x, y: y, width: effectiveWidth, height: min(barH, 2)), cornerRadius: 1),
                with: .color(ADash.violet)
            )
        }
    }

    // MARK: - Bottom Row (Top Projects + Tool Usage)

    private var bottomRow: some View {
        HStack(alignment: .top, spacing: 12) {
            topProjectsCard
            toolUsageCard
        }
    }

    // MARK: - Top Projects

    private var topProjectsCard: some View {
        analyticsCard(title: "TOP PROJECTS") {
            topProjectsContent
        }
    }

    private var topProjectsContent: some View {
        let projects = filteredProjectBreakdown()
        let maxCount = projects.first?.count ?? 1

        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(projects.prefix(8).enumerated()), id: \.offset) { _, entry in
                projectRow(name: entry.project, count: entry.count, maxCount: max(maxCount, 1))
            }
            if projects.isEmpty {
                Text("No project data")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(ADash.textDim)
            }
        }
    }

    private func projectRow(name: String, count: Int, maxCount: Int) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(ADash.textPrimary)
                .frame(width: 80, alignment: .leading)
                .lineLimit(1)
            GeometryReader { geo in
                let frac = CGFloat(count) / CGFloat(maxCount)
                RoundedRectangle(cornerRadius: 2)
                    .fill(ADash.emerald.opacity(0.5))
                    .frame(width: geo.size.width * frac)
            }
            .frame(height: 8)
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(ADash.textBright)
                .frame(width: 35, alignment: .trailing)
        }
        .frame(height: 16)
    }

    // MARK: - Tool Usage

    private var toolUsageCard: some View {
        analyticsCard(title: "TOOL USAGE") {
            toolUsageContent
        }
    }

    private var toolUsageContent: some View {
        let tools = filteredToolBreakdown()
        let maxCount = tools.first?.count ?? 1

        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(tools.prefix(8).enumerated()), id: \.offset) { _, entry in
                toolRow(name: entry.tool, count: entry.count, maxCount: max(maxCount, 1))
            }
            if tools.isEmpty {
                Text("No tool data")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(ADash.textDim)
            }
        }
    }

    private func toolRow(name: String, count: Int, maxCount: Int) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(ADash.textPrimary)
                .frame(width: 60, alignment: .leading)
                .lineLimit(1)
            GeometryReader { geo in
                let frac = CGFloat(count) / CGFloat(maxCount)
                RoundedRectangle(cornerRadius: 2)
                    .fill(ADash.cyan.opacity(0.5))
                    .frame(width: geo.size.width * frac)
            }
            .frame(height: 8)
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(ADash.textBright)
                .frame(width: 40, alignment: .trailing)
        }
        .frame(height: 16)
    }

    // MARK: - Records Card

    private var recordsCard: some View {
        analyticsCard(title: "RECORDS") {
            recordsContent
        }
    }

    private var recordsContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            recordRow(label: "Longest Session", value: longestSessionString, detail: longestSessionDetail)
            recordRow(label: "Most Expensive", value: mostExpensiveString, detail: mostExpensiveDetail)
            recordRow(label: "Total Sessions", value: totalSessionsString, detail: totalSessionsDetail)
        }
    }

    private func recordRow(label: String, value: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(ADash.textMuted)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(ADash.textBright)
                .frame(width: 80, alignment: .leading)
            Text(detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(ADash.textDim)
                .lineLimit(1)
            Spacer()
        }
    }

    // MARK: - Card Container

    private func analyticsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundColor(ADash.textDim)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ADash.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(ADash.borderSubtle))
    }

    // MARK: - Shared Canvas Helpers

    private func drawGridLines(ctx: GraphicsContext, size: CGSize, divisions: Int) {
        for i in 0...divisions {
            let y = size.height * CGFloat(i) / CGFloat(divisions)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(path, with: .color(ADash.borderSubtle), lineWidth: 0.5)
        }
    }

    private func drawYAxisLabels(ctx: GraphicsContext, size: CGSize, maxVal: Double, divisions: Int, prefix: String) {
        for i in 0...divisions {
            let y = size.height * CGFloat(divisions - i) / CGFloat(divisions)
            let val = maxVal * Double(i) / Double(divisions)
            let label = prefix + String(format: "%.0f", val)
            ctx.draw(
                Text(label)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(ADash.textDim),
                at: CGPoint(x: 22, y: y),
                anchor: .leading
            )
        }
    }

    // MARK: - Data Computation

    private struct DailyCostBucket {
        let date: Date
        let label: String
        let cost: Double
    }

    private func dailyCostBuckets() -> [DailyCostBucket] {
        let cal = Calendar.current
        let dayCount: Int
        switch period {
        case .week: dayCount = 7
        case .month: dayCount = 30
        case .all: dayCount = 60
        }

        // Compute all-time cost from stats-cache for proportional distribution
        let allTimeCost: Double
        let allTimeMessages: Int
        if let cache = statsCache, !cache.modelUsage.isEmpty {
            allTimeCost = cache.modelUsage.reduce(0.0) { sum, entry in
                let (name, usage) = entry
                return sum + ModelPricing.turnCost(
                    model: name, input: usage.inputTokens, output: usage.outputTokens,
                    cacheRead: usage.cacheReadInputTokens, cacheCreate: usage.cacheCreationInputTokens
                )
            }
            allTimeMessages = cache.totalMessages
        } else {
            allTimeCost = 0
            allTimeMessages = 0
        }

        // Build a map of date → messageCount from stats-cache dailyActivity
        var dailyMessages: [String: Int] = [:]
        if let cache = statsCache {
            for entry in cache.dailyActivity {
                dailyMessages[entry.date] = entry.messageCount
            }
        }

        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "EEE"
        let shortFmt = DateFormatter()
        shortFmt.dateFormat = "M/d"
        let isoFmt = DateFormatter()
        isoFmt.dateFormat = "yyyy-MM-dd"

        var buckets: [DailyCostBucket] = []
        for i in stride(from: dayCount - 1, through: 0, by: -1) {
            guard let date = cal.date(byAdding: .day, value: -i, to: Date()) else { continue }
            let dateKey = isoFmt.string(from: date)

            // Proportional cost: (messages on this day / total messages) × total cost
            let dayMsgs = dailyMessages[dateKey] ?? 0
            let cost: Double
            if allTimeMessages > 0 && dayMsgs > 0 {
                cost = allTimeCost * Double(dayMsgs) / Double(allTimeMessages)
            } else {
                // Fallback: use catalog session costs for dates without stats-cache data
                let startOfDay = cal.startOfDay(for: date)
                let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) ?? date
                cost = catalog.entries
                    .filter { ($0.startTime ?? .distantPast) >= startOfDay && ($0.startTime ?? .distantPast) < endOfDay }
                    .compactMap(\.estimatedCostUSD)
                    .reduce(0, +)
            }

            let label = dayCount <= 7 ? dayFmt.string(from: date) : shortFmt.string(from: date)
            buckets.append(DailyCostBucket(date: date, label: label, cost: cost))
        }
        return buckets
    }

    private struct ModelBreakdownEntry {
        let name: String
        let shortName: String
        let cost: Double
        let inputTokens: Int
        let outputTokens: Int
    }

    private func computeModelBreakdown() -> [ModelBreakdownEntry] {
        // Prefer stats-cache modelUsage if available (covers all-time data)
        if let cache = statsCache, !cache.modelUsage.isEmpty {
            return cache.modelUsage.map { name, usage in
                let short = name
                    .replacingOccurrences(of: "claude-", with: "")
                    .replacingOccurrences(of: "anthropic/", with: "")
                // Compute real cost from ALL token fields (costUSD is always 0 in stats-cache)
                let realCost = ModelPricing.turnCost(
                    model: name,
                    input: usage.inputTokens,
                    output: usage.outputTokens,
                    cacheRead: usage.cacheReadInputTokens,
                    cacheCreate: usage.cacheCreationInputTokens
                )
                return ModelBreakdownEntry(
                    name: name,
                    shortName: short,
                    cost: realCost,
                    inputTokens: usage.inputTokens,
                    outputTokens: usage.outputTokens
                )
            }
            .sorted { $0.cost > $1.cost }
        }

        // Fallback: aggregate from catalog entries
        var map: [String: (cost: Double, input: Int, output: Int)] = [:]
        for e in filteredEntries {
            let model = e.model ?? "unknown"
            let prev = map[model] ?? (cost: 0, input: 0, output: 0)
            map[model] = (
                cost: prev.cost + (e.estimatedCostUSD ?? 0),
                input: prev.input + (e.inputTokens ?? 0),
                output: prev.output + (e.outputTokens ?? 0)
            )
        }
        return map.map { name, data in
            let short = name
                .replacingOccurrences(of: "claude-", with: "")
                .replacingOccurrences(of: "anthropic/", with: "")
            return ModelBreakdownEntry(name: name, shortName: short, cost: data.cost,
                                       inputTokens: data.input, outputTokens: data.output)
        }
        .sorted { $0.cost > $1.cost }
    }

    private func hourCountsData() -> [Int: Int] {
        // Prefer stats-cache hourCounts
        if let cache = statsCache, !cache.hourCounts.isEmpty {
            return cache.hourCounts
        }

        // Fallback: compute from catalog entries
        var counts: [Int: Int] = [:]
        for e in filteredEntries {
            guard let t = e.startTime else { continue }
            let hour = Calendar.current.component(.hour, from: t)
            counts[hour, default: 0] += 1
        }
        return counts
    }

    private func filteredProjectBreakdown() -> [(project: String, count: Int, cost: Double)] {
        var map: [String: (count: Int, cost: Double)] = [:]
        for e in filteredEntries where !e.project.isEmpty {
            let prev = map[e.project] ?? (count: 0, cost: 0)
            map[e.project] = (count: prev.count + 1, cost: prev.cost + (e.estimatedCostUSD ?? 0))
        }
        return map.map { (project: $0.key, count: $0.value.count, cost: $0.value.cost) }
            .sorted { $0.count > $1.count }
    }

    private func filteredToolBreakdown() -> [(tool: String, count: Int)] {
        var map: [String: Int] = [:]
        for e in filteredEntries {
            for (tool, count) in (e.toolCounts ?? [:]) {
                map[tool, default: 0] += count
            }
        }
        return map.map { (tool: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }

    // MARK: - Records Data

    private var longestSessionString: String {
        if let cache = statsCache, let longest = cache.longestSession {
            let hours = longest.duration / 3600
            let mins = (longest.duration % 3600) / 60
            return "\(hours)h \(mins)m"
        }
        let longest = filteredEntries.max(by: { ($0.durationMinutes ?? 0) < ($1.durationMinutes ?? 0) })
        guard let mins = longest?.durationMinutes, mins > 0 else { return "--" }
        if mins >= 60 { return "\(mins / 60)h \(mins % 60)m" }
        return "\(mins)m"
    }

    private var longestSessionDetail: String {
        if let cache = statsCache, let longest = cache.longestSession {
            return "\(longest.messageCount) messages"
        }
        let longest = filteredEntries.max(by: { ($0.durationMinutes ?? 0) < ($1.durationMinutes ?? 0) })
        let prompt = longest?.firstPrompt ?? ""
        if prompt.isEmpty { return "" }
        let truncated = prompt.prefix(40)
        return "\u{201C}\(truncated)\u{2026}\u{201D}"
    }

    private var mostExpensiveString: String {
        let most = filteredEntries.max(by: { ($0.estimatedCostUSD ?? 0) < ($1.estimatedCostUSD ?? 0) })
        guard let cost = most?.estimatedCostUSD, cost > 0 else { return "--" }
        return String(format: "$%.2f", cost)
    }

    private var mostExpensiveDetail: String {
        let most = filteredEntries.max(by: { ($0.estimatedCostUSD ?? 0) < ($1.estimatedCostUSD ?? 0) })
        let prompt = most?.firstPrompt ?? ""
        if prompt.isEmpty { return "" }
        let truncated = prompt.prefix(40)
        return "\u{201C}\(truncated)\u{2026}\u{201D}"
    }

    private var totalSessionsString: String {
        if let cache = statsCache, cache.totalSessions > 0 {
            return "\(cache.totalSessions)"
        }
        return "\(filteredEntries.count)"
    }

    private var totalSessionsDetail: String {
        let projects = Set(filteredEntries.compactMap { $0.project.isEmpty ? nil : $0.project })
        return "across \(projects.count) projects"
    }

    // MARK: - Stats Cache Loading

    private func loadStatsCache() {
        DispatchQueue.global(qos: .utility).async {
            let path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/stats-cache.json")
            guard let data = try? Data(contentsOf: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            var result = StatsCacheData()
            parseDailyActivity(from: json, into: &result)
            parseModelUsage(from: json, into: &result)
            parseHourCounts(from: json, into: &result)
            parseLongestSession(from: json, into: &result)

            result.totalSessions = json["totalSessions"] as? Int ?? 0
            result.totalMessages = json["totalMessages"] as? Int ?? 0

            DispatchQueue.main.async {
                self.statsCache = result
            }
        }
    }

    private func parseDailyActivity(from json: [String: Any], into result: inout StatsCacheData) {
        guard let daily = json["dailyActivity"] as? [[String: Any]] else { return }
        result.dailyActivity = daily.compactMap { entry in
            guard let date = entry["date"] as? String else { return nil }
            return StatsCacheData.DailyActivityEntry(
                date: date,
                messageCount: entry["messageCount"] as? Int ?? 0,
                sessionCount: entry["sessionCount"] as? Int ?? 0,
                toolCallCount: entry["toolCallCount"] as? Int ?? 0
            )
        }
    }

    private func parseModelUsage(from json: [String: Any], into result: inout StatsCacheData) {
        guard let models = json["modelUsage"] as? [String: [String: Any]] else { return }
        for (name, usage) in models {
            result.modelUsage[name] = StatsCacheData.ModelUsageEntry(
                inputTokens: usage["inputTokens"] as? Int ?? 0,
                outputTokens: usage["outputTokens"] as? Int ?? 0,
                cacheReadInputTokens: usage["cacheReadInputTokens"] as? Int ?? 0,
                cacheCreationInputTokens: usage["cacheCreationInputTokens"] as? Int ?? 0,
                costUSD: usage["costUSD"] as? Double ?? 0.0
            )
        }
    }

    private func parseHourCounts(from json: [String: Any], into result: inout StatsCacheData) {
        guard let hours = json["hourCounts"] as? [String: Any] else { return }
        for (key, val) in hours {
            if let h = Int(key), let count = val as? Int {
                result.hourCounts[h] = count
            }
        }
    }

    private func parseLongestSession(from json: [String: Any], into result: inout StatsCacheData) {
        guard let longest = json["longestSession"] as? [String: Any] else { return }
        result.longestSession = StatsCacheData.LongestSessionEntry(
            sessionId: longest["sessionId"] as? String ?? "",
            duration: longest["duration"] as? Int ?? 0,
            messageCount: longest["messageCount"] as? Int ?? 0
        )
    }
}
