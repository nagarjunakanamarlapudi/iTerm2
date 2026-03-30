import Foundation

// MARK: - Session Stats Model

@objc class DashboardSessionStats: NSObject, ObservableObject {
    @Published var sessionId: String = ""
    @Published var model: String = ""
    @Published var inputTokens: Int = 0
    @Published var outputTokens: Int = 0
    @Published var cacheReadTokens: Int = 0
    @Published var cacheCreateTokens: Int = 0
    @Published var estimatedCostUSD: Double = 0.0
    @Published var contextFillPercent: Double = 0.0      // current/final fill
    @Published var peakContextFillPercent: Double = 0.0  // peak across session
    @Published var turnCount: Int = 0
    @Published var sessionDurationSec: TimeInterval = 0
    @Published var startTime: Date?
    @Published var toolCounts: [String: Int] = [:]
    @Published var filesModified: [String] = []
    @Published var linesAdded: Int = 0
    @Published var linesRemoved: Int = 0
    @Published var recentActivity: [DashboardActivityEntry] = []
    @Published var agentCount: Int = 0
    @Published var gitBranch: String = ""
    @Published var sessionSlug: String = ""
    @Published var costByModel: [String: Double] = [:]
    @Published var tokensByModel: [String: (input: Int, output: Int)] = [:]
    @Published var subagentCostUSD: Double = 0.0

    var totalTokens: Int { inputTokens + outputTokens }

    var costString: String {
        if estimatedCostUSD < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", estimatedCostUSD)
    }

    var tokenString: String {
        if totalTokens > 1000 {
            return String(format: "%.1fk", Double(totalTokens) / 1000.0)
        }
        return "\(totalTokens)"
    }

    var durationString: String {
        let mins = Int(sessionDurationSec / 60)
        let secs = Int(sessionDurationSec) % 60
        if mins > 60 {
            let hours = mins / 60
            let remainMins = mins % 60
            return "\(hours)h \(remainMins)m"
        }
        return "\(mins)m \(secs)s"
    }

    var contextFillString: String {
        return String(format: "%.0f%%", contextFillPercent)
    }

    func reset() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.model = ""
            self.inputTokens = 0
            self.outputTokens = 0
            self.cacheReadTokens = 0
            self.cacheCreateTokens = 0
            self.estimatedCostUSD = 0.0
            self.contextFillPercent = 0.0
            self.peakContextFillPercent = 0.0
            self.turnCount = 0
            self.sessionDurationSec = 0
            self.startTime = nil
            self.toolCounts = [:]
            self.filesModified = []
            self.linesAdded = 0
            self.linesRemoved = 0
            self.recentActivity = []
            self.agentCount = 0
            self.gitBranch = ""
            self.sessionSlug = ""
            self.costByModel = [:]
            self.tokensByModel = [:]
            self.subagentCostUSD = 0.0
        }
    }
}

struct DashboardActivityEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let toolName: String
    let summary: String
    let isPermission: Bool

    var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }
}

// MARK: - Model Pricing (per million tokens, March 2026 Anthropic API)

enum ModelPricing {
    static func costPerMillionInput(_ model: String) -> Double {
        if model.contains("opus") { return 15.0 }
        if model.contains("sonnet") { return 3.0 }
        if model.contains("haiku") { return 0.80 }
        return 3.0
    }
    static func costPerMillionOutput(_ model: String) -> Double {
        if model.contains("opus") { return 75.0 }
        if model.contains("sonnet") { return 15.0 }
        if model.contains("haiku") { return 4.0 }
        return 15.0
    }
    static func costPerMillionCacheRead(_ model: String) -> Double {
        if model.contains("opus") { return 1.50 }
        if model.contains("sonnet") { return 0.30 }
        if model.contains("haiku") { return 0.08 }
        return 0.30
    }
    static func costPerMillionCacheCreate(_ model: String) -> Double {
        if model.contains("opus") { return 18.75 }
        if model.contains("sonnet") { return 3.75 }
        if model.contains("haiku") { return 1.00 }
        return 3.75
    }
    static func maxContext(_ model: String) -> Int {
        if model.contains("1m") || model.contains("opus") { return 1_000_000 }
        return 200_000
    }

    /// Calculate cost for a single turn given all token counts
    static func turnCost(model: String, input: Int, output: Int, cacheRead: Int, cacheCreate: Int) -> Double {
        return (Double(input) * costPerMillionInput(model)
              + Double(output) * costPerMillionOutput(model)
              + Double(cacheRead) * costPerMillionCacheRead(model)
              + Double(cacheCreate) * costPerMillionCacheCreate(model)) / 1_000_000.0
    }

    /// Estimate cost from basic input/output tokens only (no cache data — for session-meta)
    static func estimateCost(input: Int, output: Int, model: String) -> Double {
        return (Double(input) * costPerMillionInput(model)
              + Double(output) * costPerMillionOutput(model)) / 1_000_000.0
    }
}

// MARK: - Transcript Reader

/// Watches a Claude Code JSONL transcript in real-time and updates DashboardSessionStats.
/// Uses DispatchSource for instant file-change notification (same pattern as ReasoningTranscriptReader).
@objc class DashboardTranscriptReader: NSObject {

    private var fileHandle: FileHandle?
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var byteOffset: UInt64 = 0
    private let ioQueue = DispatchQueue(label: "com.aiterm.DashboardTranscriptReader", qos: .utility)
    private var isWatching = false
    private weak var stats: DashboardSessionStats?
    private var seenAgentIds = Set<String>()
    private var seenFiles = Set<String>()

    deinit { stopWatching() }

    // MARK: - Public API

    @objc func startWatching(transcriptURL: URL, sessionId: String, stats: DashboardSessionStats) {
        stopWatching()
        self.stats = stats
        DispatchQueue.main.async { stats.sessionId = sessionId }

        ioQueue.async { [weak self] in
            self?.openAndWatch(url: transcriptURL)
        }
    }

    @objc func stopWatching() {
        dispatchSource?.cancel()
        dispatchSource = nil
        try? fileHandle?.close()
        fileHandle = nil
        isWatching = false
    }

    /// Find transcript for a session ID (same logic as ReasoningTranscriptReader).
    @objc class func findTranscript(sessionId: String) -> URL? {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return nil }

        let filename = "\(sessionId).jsonl"
        for dir in dirs {
            let candidate = dir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Load pre-computed session metadata from usage-data if available.
    @objc class func loadSessionMeta(sessionId: String) -> [String: Any]? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/usage-data/session-meta/\(sessionId).json")
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    // MARK: - File watching

    private func openAndWatch(url: URL) {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return }
        self.fileHandle = handle

        // Read from the beginning to get full stats
        handle.seek(toFileOffset: 0)
        byteOffset = 0
        processNewBytes()

        // Also scan subagent transcripts (they have their own token/cost data)
        scanSubagentTranscripts(mainTranscriptURL: url)

        let fd = handle.fileDescriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend], queue: ioQueue
        )
        source.setEventHandler { [weak self] in self?.processNewBytes() }
        source.setCancelHandler { [weak handle] in try? handle?.close() }
        source.resume()
        self.dispatchSource = source
        self.isWatching = true
    }

    private func processNewBytes() {
        guard let handle = fileHandle else { return }
        handle.seek(toFileOffset: byteOffset)
        let data = handle.readDataToEndOfFile()
        if data.isEmpty { return }

        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let usableCount = data.distance(from: data.startIndex, to: lastNewline) + 1
        let usableData = data.prefix(usableCount)
        byteOffset += UInt64(usableCount)

        guard let text = String(data: usableData, encoding: .utf8) else { return }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parseLine(trimmed) }
        }

        // Update duration
        if let start = stats?.startTime {
            let duration = Date().timeIntervalSince(start)
            DispatchQueue.main.async { [weak self] in
                self?.stats?.sessionDurationSec = duration
            }
        }
    }

    // MARK: - JSONL Parsing

    private func parseLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let entryType = json["type"] as? String ?? ""

        // Capture start time from first entry
        if stats?.startTime == nil, let ts = json["timestamp"] as? String {
            let date = ISO8601DateFormatter().date(from: ts)
            DispatchQueue.main.async { [weak self] in
                self?.stats?.startTime = date
            }
        }

        // Capture git branch and slug
        if let branch = json["gitBranch"] as? String, !branch.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.stats?.gitBranch = branch }
        }
        if let slug = json["slug"] as? String, !slug.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.stats?.sessionSlug = slug }
        }

        // Track subagents
        if let agentId = json["agentId"] as? String, !seenAgentIds.contains(agentId) {
            seenAgentIds.insert(agentId)
            DispatchQueue.main.async { [weak self] in self?.stats?.agentCount = self?.seenAgentIds.count ?? 0 }
        }

        switch entryType {
        case "assistant":
            parseAssistant(json)
        case "system":
            parseSystem(json)
        default:
            break
        }
    }

    private func parseAssistant(_ json: [String: Any]) {
        guard let message = json["message"] as? [String: Any] else { return }

        // Model
        if let model = message["model"] as? String, !model.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.stats?.model = model }
        }

        // Only accumulate tokens from FINAL blocks (stop_reason != null)
        // Streaming blocks have partial counts; the final block has the complete turn total
        let stopReason = message["stop_reason"]
        let isFinalBlock = stopReason != nil && !(stopReason is NSNull)

        if isFinalBlock, let usage = message["usage"] as? [String: Any] {
            let input = usage["input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            let cacheCreate = usage["cache_creation_input_tokens"] as? Int ?? 0

            let model = (message["model"] as? String) ?? ""
            let cost = ModelPricing.turnCost(model: model, input: input, output: output,
                                              cacheRead: cacheRead, cacheCreate: cacheCreate)

            let maxCtx = ModelPricing.maxContext(model)
            let fillPct = maxCtx > 0 ? Double(input + cacheRead) / Double(maxCtx) * 100.0 : 0.0

            DispatchQueue.main.async { [weak self] in
                guard let s = self?.stats else { return }
                // ACCUMULATE across turns (not max — that was the 63% undercount bug)
                s.inputTokens += input
                s.outputTokens += output
                s.cacheReadTokens += cacheRead
                s.cacheCreateTokens += cacheCreate
                s.estimatedCostUSD += cost
                s.contextFillPercent = fillPct  // current/final fill (overwrites each turn)
                s.peakContextFillPercent = max(s.peakContextFillPercent, fillPct)  // peak
                // Per-model breakdown
                s.costByModel[model, default: 0.0] += cost
                let prev = s.tokensByModel[model] ?? (input: 0, output: 0)
                s.tokensByModel[model] = (input: prev.input + input, output: prev.output + output)
            }
        }

        // Tool calls from content blocks
        if let contents = message["content"] as? [[String: Any]] {
            for block in contents {
                let blockType = block["type"] as? String ?? ""
                if blockType == "tool_use" {
                    parseToolUse(block, timestamp: json["timestamp"] as? String)
                }
            }
        }
    }

    private func parseToolUse(_ block: [String: Any], timestamp: String?) {
        let toolName = block["name"] as? String ?? "Unknown"
        let input = block["input"] as? [String: Any] ?? [:]

        // Increment tool count
        DispatchQueue.main.async { [weak self] in
            guard let s = self?.stats else { return }
            s.toolCounts[toolName, default: 0] += 1
        }

        // Extract file paths and line changes
        var summary = toolName
        if let filePath = input["file_path"] as? String ?? input["path"] as? String {
            let shortPath = (filePath as NSString).lastPathComponent
            summary = "\(toolName) \(shortPath)"

            if (toolName == "Edit" || toolName == "Write") && !seenFiles.contains(filePath) {
                seenFiles.insert(filePath)
                DispatchQueue.main.async { [weak self] in
                    self?.stats?.filesModified.append(shortPath)
                }
            }
        } else if let command = input["command"] as? String {
            let shortCmd = String(command.prefix(50))
            summary = "\(toolName): \(shortCmd)"
        } else if let pattern = input["pattern"] as? String {
            summary = "\(toolName) \(pattern)"
        }

        // Add to activity timeline (keep last 20)
        let date: Date
        if let ts = timestamp { date = ISO8601DateFormatter().date(from: ts) ?? Date() }
        else { date = Date() }

        let entry = DashboardActivityEntry(
            timestamp: date, toolName: toolName, summary: summary, isPermission: false
        )
        DispatchQueue.main.async { [weak self] in
            guard let s = self?.stats else { return }
            s.recentActivity.append(entry)
            if s.recentActivity.count > 20 {
                s.recentActivity.removeFirst(s.recentActivity.count - 20)
            }
        }
    }

    private func parseSystem(_ json: [String: Any]) {
        let subtype = json["subtype"] as? String ?? ""
        if subtype == "turn_duration" {
            DispatchQueue.main.async { [weak self] in
                self?.stats?.turnCount += 1
            }
        }
    }

    // MARK: - Subagent Transcript Scanning

    /// Scan subagent JSONL files and accumulate their token usage / cost into the session stats.
    /// Subagents are in <session-dir>/subagents/agent-*.jsonl — each has its own model and usage.
    private func scanSubagentTranscripts(mainTranscriptURL: URL) {
        // Derive session dir: same name as transcript file minus .jsonl extension
        let sessionId = mainTranscriptURL.deletingPathExtension().lastPathComponent
        let sessionDir = mainTranscriptURL.deletingLastPathComponent().appendingPathComponent(sessionId)
        let subagentDir = sessionDir.appendingPathComponent("subagents")

        guard FileManager.default.fileExists(atPath: subagentDir.path),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: subagentDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
              ) else { return }

        let jsonlFiles = files.filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("agent-") }
        var subCost = 0.0

        for file in jsonlFiles {
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) else { continue }

            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let lineData = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      json["type"] as? String == "assistant",
                      let message = json["message"] as? [String: Any] else { continue }

                // Only final blocks (stop_reason present and not null)
                let stopReason = message["stop_reason"]
                guard stopReason != nil && !(stopReason is NSNull) else { continue }

                guard let usage = message["usage"] as? [String: Any] else { continue }
                let input = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                let cacheCreate = usage["cache_creation_input_tokens"] as? Int ?? 0
                let model = message["model"] as? String ?? ""

                let cost = ModelPricing.turnCost(model: model, input: input, output: output,
                                                  cacheRead: cacheRead, cacheCreate: cacheCreate)
                subCost += cost

                DispatchQueue.main.async { [weak self] in
                    guard let s = self?.stats else { return }
                    s.inputTokens += input
                    s.outputTokens += output
                    s.cacheReadTokens += cacheRead
                    s.cacheCreateTokens += cacheCreate
                    s.estimatedCostUSD += cost
                    s.costByModel[model, default: 0.0] += cost
                    let prev = s.tokensByModel[model] ?? (input: 0, output: 0)
                    s.tokensByModel[model] = (input: prev.input + input, output: prev.output + output)
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.stats?.subagentCostUSD = subCost
        }
    }
}

// MARK: - Global Stats Reader

/// Reads aggregate stats from ~/.claude/stats-cache.json
@objc class DashboardGlobalStats: NSObject, ObservableObject {
    @Published var totalCostToday: Double = 0.0
    @Published var totalTokensToday: Int = 0
    @Published var totalSessionsToday: Int = 0
    @Published var totalCommitsToday: Int = 0

    var costTodayString: String {
        if totalCostToday < 0.01 { return "$0.00" }
        return String(format: "$%.2f", totalCostToday)
    }

    var tokensTodayString: String {
        if totalTokensToday > 1000 {
            return String(format: "%.0fk", Double(totalTokensToday) / 1000.0)
        }
        return "\(totalTokensToday)"
    }

    @objc func reload() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.loadFromStatsCache()
            self?.loadFromLiveSessions()
        }
    }

    private func loadFromStatsCache() {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/stats-cache.json")
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let today = ISO8601DateFormatter().string(from: Date()).prefix(10)  // "2026-03-26"

        // Daily activity
        if let daily = json["dailyActivity"] as? [[String: Any]] {
            if let todayEntry = daily.first(where: { ($0["date"] as? String)?.hasPrefix(String(today)) == true }) {
                let sessions = todayEntry["sessionCount"] as? Int ?? 0
                let tokens = todayEntry["toolCallCount"] as? Int ?? 0  // approximate
                DispatchQueue.main.async { [weak self] in
                    self?.totalSessionsToday = sessions
                }
                _ = tokens  // used below in live session aggregation
            }
        }

        // Model usage for cost
        if let modelUsage = json["modelUsage"] as? [String: [String: Any]] {
            var totalCost = 0.0
            for (_, usage) in modelUsage {
                totalCost += usage["costUSD"] as? Double ?? 0.0
            }
            // Note: this is cumulative, not today-only. For today, we use live sessions.
        }
    }

    private func loadFromLiveSessions() {
        // Sum cost/tokens across all active session-meta files for today
        let metaDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/usage-data/session-meta")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: metaDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }

        var costSum = 0.0
        var tokenSum = 0
        var commitSum = 0
        let todayStr = ISO8601DateFormatter().string(from: Date()).prefix(10)

        for file in files.suffix(50) {  // Check last 50 sessions
            guard let data = try? Data(contentsOf: file),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            // Check if session is from today
            if let timestamps = meta["user_message_timestamps"] as? [String],
               let first = timestamps.first, first.hasPrefix(String(todayStr)) {
                let input = meta["input_tokens"] as? Int ?? 0
                let output = meta["output_tokens"] as? Int ?? 0
                tokenSum += input + output
                commitSum += meta["git_commits"] as? Int ?? 0

                // Estimate cost using actual model pricing
                // session-meta only has input/output tokens (no cache breakdown)
                let model = meta["model"] as? String ?? "opus"
                costSum += ModelPricing.estimateCost(input: input, output: output, model: model)
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.totalCostToday = costSum
            self?.totalTokensToday = tokenSum
            self?.totalCommitsToday = commitSum
        }
    }
}
