import Foundation

// MARK: - Data Tier

enum SessionDataTier: String {
    case rich        // has transcript + meta + facets
    case meta        // has meta, possibly facets
    case transcript  // has transcript file only
    case historyOnly // only appears in history.jsonl
}

// MARK: - Catalog Entry

struct SessionCatalogEntry: Identifiable {
    let id: String  // session UUID
    var project: String  // short name (last path component)
    var projectPath: String
    var firstPrompt: String
    var startTime: Date?
    var durationMinutes: Int?
    var model: String?
    var gitBranch: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheCreationTokens: Int?
    var estimatedCostUSD: Double?
    var dailyCosts: [String: Double]?  // "2026-03-27" → cost that day
    var toolCounts: [String: Int]?
    var linesAdded: Int?
    var linesRemoved: Int?
    var gitCommits: Int?
    var filesModified: Int?
    var languages: [String: Int]?
    var assistantMessageCount: Int?
    var userMessageCount: Int?
    var summary: String?
    var goal: String?
    var outcome: String?
    var sessionType: String?
    var isActive: Bool = false
    var activePid: Int?
    var linkedTabId: Int?
    var hasTranscript: Bool = false
    var hasSubagents: Bool = false
    var transcriptURL: URL?
    var dataTier: SessionDataTier = .historyOnly

    var costString: String {
        guard let c = estimatedCostUSD, c > 0 else { return "" }
        if c < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", c)
    }

    var durationString: String {
        guard let m = durationMinutes else { return "" }
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m)m"
    }

    var tokenString: String {
        let total = (inputTokens ?? 0) + (outputTokens ?? 0)
        if total == 0 { return "" }
        if total > 1000 { return String(format: "%.1fk", Double(total) / 1000.0) }
        return "\(total)"
    }

    var timeLabel: String {
        guard let t = startTime else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(t) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: t)
        }
        if cal.isDateInYesterday(t) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"; return "Yesterday " + f.string(from: t)
        }
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f.string(from: t)
    }

    var tildeAbbreviatedProjectPath: String {
        let home = NSHomeDirectory()
        if projectPath.hasPrefix(home) {
            return "~" + projectPath.dropFirst(home.count)
        }
        return projectPath
    }
}

// MARK: - Session Catalog

/// Merges session data from history.jsonl, session-meta, facets, transcript listings,
/// and active session files into a unified catalog for the Mission Control SESSIONS tab.
@objc class DashboardSessionCatalog: NSObject, ObservableObject {

    @Published var entries: [SessionCatalogEntry] = []
    @Published var isLoading: Bool = false
    @Published var computedTodayCost: Double = 0

    private let fm = FileManager.default
    private let homeDir: URL = FileManager.default.homeDirectoryForCurrentUser
    private let buildQueue = DispatchQueue(label: "com.aiterm.SessionCatalog", qos: .utility)

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Time-Grouped Accessors

    var todaySessions: [SessionCatalogEntry] {
        entries.filter { $0.startTime.map { Calendar.current.isDateInToday($0) } ?? false }
    }
    var yesterdaySessions: [SessionCatalogEntry] {
        entries.filter { $0.startTime.map { Calendar.current.isDateInYesterday($0) } ?? false }
    }
    var thisWeekSessions: [SessionCatalogEntry] {
        let cal = Calendar.current
        guard let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start else { return [] }
        return entries.filter { entry in
            guard let t = entry.startTime else { return false }
            return t >= weekStart && !cal.isDateInToday(t) && !cal.isDateInYesterday(t)
        }
    }
    var olderSessions: [SessionCatalogEntry] {
        let cal = Calendar.current
        guard let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start else {
            return entries.filter { $0.startTime == nil }
        }
        return entries.filter { ($0.startTime ?? .distantPast) < weekStart }
    }

    // MARK: - Aggregates

    var totalCost: Double { entries.compactMap(\.estimatedCostUSD).reduce(0, +) }
    var totalCostAllTime: Double { entries.compactMap(\.estimatedCostUSD).reduce(0, +) }
    var totalMessageCount: Int { entries.compactMap(\.assistantMessageCount).reduce(0, +) }

    var projectBreakdown: [(project: String, count: Int, cost: Double)] {
        var map: [String: (count: Int, cost: Double)] = [:]
        for e in entries where !e.project.isEmpty {
            let prev = map[e.project] ?? (count: 0, cost: 0)
            map[e.project] = (count: prev.count + 1, cost: prev.cost + (e.estimatedCostUSD ?? 0))
        }
        return map.map { (project: $0.key, count: $0.value.count, cost: $0.value.cost) }
            .sorted { $0.count > $1.count }
    }

    var toolBreakdown: [(tool: String, count: Int)] {
        var map: [String: Int] = [:]
        for e in entries {
            for (tool, count) in (e.toolCounts ?? [:]) { map[tool, default: 0] += count }
        }
        return map.map { (tool: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }

    /// Aggregate daily costs across sessions, optionally filtered by project.
    /// Uses per-day splits from transcripts when available, falls back to start-date assignment.
    func aggregateDailyCosts(project: String? = nil) -> [(date: Date, cost: Double)] {
        var dayCostMap: [String: Double] = [:]
        let source = project.map { p in entries.filter { $0.project == p } } ?? entries

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"

        for entry in source {
            if let daily = entry.dailyCosts, !daily.isEmpty {
                for (dateStr, cost) in daily {
                    dayCostMap[dateStr, default: 0] += cost
                }
            } else if let startTime = entry.startTime, let cost = entry.estimatedCostUSD {
                let dateStr = dateFmt.string(from: startTime)
                dayCostMap[dateStr, default: 0] += cost
            }
        }

        return dayCostMap.compactMap { dateStr, cost in
            guard let date = dateFmt.date(from: dateStr) else { return nil }
            return (date: date, cost: cost)
        }.sorted { $0.date < $1.date }
    }

    // MARK: - Build Catalog

    @objc func buildCatalog() {
        DispatchQueue.main.async { self.isLoading = true }

        buildQueue.async { [weak self] in
            guard let self else { return }
            var catalog: [String: SessionCatalogEntry] = [:]

            // Phase 1: Fast load (~100ms) — show sessions immediately
            self.loadHistory(into: &catalog)
            self.loadSessionMeta(into: &catalog)
            self.loadFacets(into: &catalog)
            self.loadTranscriptListings(into: &catalog)
            self.loadActiveSessions(into: &catalog)

            let keys = Array(catalog.keys)
            for key in keys {
                if let entry = catalog[key] {
                    catalog[key]?.dataTier = self.computeTier(entry)
                }
            }

            let sorted = catalog.values.sorted {
                ($0.startTime ?? .distantPast) > ($1.startTime ?? .distantPast)
            }

            // Publish immediately with session-meta costs (underestimate, but instant)
            DispatchQueue.main.async { [weak self] in
                self?.entries = sorted
                self?.isLoading = false
            }

            // Phase 2: Background cost scanning (~3-5s) — update costs progressively
            self.batchScanTranscriptCosts(catalog: &catalog)

            let costSorted = catalog.values.sorted {
                ($0.startTime ?? .distantPast) > ($1.startTime ?? .distantPast)
            }

            let todayKey: String = {
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
            }()
            let todayCost = costSorted.reduce(0.0) { sum, entry in
                sum + (entry.dailyCosts?[todayKey] ?? 0)
            }

            // Publish again with accurate costs
            DispatchQueue.main.async { [weak self] in
                self?.entries = costSorted
                self?.computedTodayCost = todayCost
            }
        }
    }

    // MARK: - Search

    func search(_ query: String) -> [SessionCatalogEntry] {
        if query.isEmpty { return entries }
        let q = query.lowercased()
        return entries.filter { e in
            e.firstPrompt.lowercased().contains(q)
                || e.project.lowercased().contains(q)
                || (e.summary?.lowercased().contains(q) ?? false)
                || (e.goal?.lowercased().contains(q) ?? false)
                || (e.gitBranch?.lowercased().contains(q) ?? false)
                || e.id.lowercased().contains(q)
        }
    }

    // MARK: - Source 1: history.jsonl

    private func loadHistory(into catalog: inout [String: SessionCatalogEntry]) {
        let path = homeDir.appendingPathComponent(".claude/history.jsonl")
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8) else { return }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let ld = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: ld) as? [String: Any],
                  let sid = json["sessionId"] as? String else { continue }

            if catalog[sid] != nil { continue }  // first prompt per session

            let display = json["display"] as? String ?? ""
            let projectPath = json["project"] as? String ?? ""
            let project = Self.shortProjectName(projectPath)
            var startTime: Date?
            if let ts = json["timestamp"] as? Double {
                startTime = Date(timeIntervalSince1970: ts / 1000.0)
            }

            catalog[sid] = SessionCatalogEntry(
                id: sid, project: project, projectPath: projectPath,
                firstPrompt: display, startTime: startTime
            )
        }
    }

    // MARK: - Source 2: session-meta

    private func loadSessionMeta(into catalog: inout [String: SessionCatalogEntry]) {
        let metaDir = homeDir.appendingPathComponent(".claude/usage-data/session-meta")
        guard let files = try? fm.contentsOfDirectory(
            at: metaDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }

        for file in files {
            guard file.pathExtension == "json",
                  let data = try? Data(contentsOf: file),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let sid = j["session_id"] as? String ?? file.deletingPathExtension().lastPathComponent
            let projectPath = j["project_path"] as? String ?? ""
            let project = Self.shortProjectName(projectPath)
            let firstPrompt = j["first_prompt"] as? String ?? ""
            let durationMin = j["duration_minutes"] as? Int
            let inputTok = j["input_tokens"] as? Int
            let outputTok = j["output_tokens"] as? Int
            let toolCounts = j["tool_counts"] as? [String: Int]
            let linesAdd = j["lines_added"] as? Int
            let linesRem = j["lines_removed"] as? Int
            let commits = j["git_commits"] as? Int
            let filesMod = j["files_modified"] as? Int
            let languages = j["languages"] as? [String: Int]
            let assistantCount = j["assistant_message_count"] as? Int
            let userCount = j["user_message_count"] as? Int

            var startTime: Date?
            if let iso = j["start_time"] as? String { startTime = Self.parseISO8601(iso) }

            // Estimate cost from session-meta tokens (no cache data available)
            var cost: Double?
            if let inp = inputTok, let outp = outputTok {
                cost = ModelPricing.estimateCost(input: inp, output: outp, model: "opus")
            }

            if var existing = catalog[sid] {
                if !projectPath.isEmpty { existing.projectPath = projectPath; existing.project = project }
                if !firstPrompt.isEmpty && existing.firstPrompt.isEmpty { existing.firstPrompt = firstPrompt }
                if let t = startTime { existing.startTime = t }
                existing.durationMinutes = durationMin
                existing.inputTokens = inputTok
                existing.outputTokens = outputTok
                existing.estimatedCostUSD = cost
                existing.toolCounts = toolCounts
                existing.linesAdded = linesAdd
                existing.linesRemoved = linesRem
                existing.gitCommits = commits
                existing.filesModified = filesMod
                existing.languages = languages
                existing.assistantMessageCount = assistantCount
                existing.userMessageCount = userCount
                catalog[sid] = existing
            } else {
                var entry = SessionCatalogEntry(
                    id: sid, project: project, projectPath: projectPath,
                    firstPrompt: firstPrompt, startTime: startTime
                )
                entry.durationMinutes = durationMin
                entry.inputTokens = inputTok; entry.outputTokens = outputTok
                entry.estimatedCostUSD = cost; entry.toolCounts = toolCounts
                entry.linesAdded = linesAdd; entry.linesRemoved = linesRem
                entry.gitCommits = commits; entry.filesModified = filesMod
                entry.languages = languages
                entry.assistantMessageCount = assistantCount; entry.userMessageCount = userCount
                catalog[sid] = entry
            }
        }
    }

    // MARK: - Source 3: facets

    private func loadFacets(into catalog: inout [String: SessionCatalogEntry]) {
        let facetsDir = homeDir.appendingPathComponent(".claude/usage-data/facets")
        guard let files = try? fm.contentsOfDirectory(
            at: facetsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }

        for file in files {
            guard file.pathExtension == "json",
                  let data = try? Data(contentsOf: file),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let sid = j["session_id"] as? String ?? file.deletingPathExtension().lastPathComponent
            let summary = j["brief_summary"] as? String
            let goal = j["underlying_goal"] as? String
            let outcome = j["outcome"] as? String
            let sessionType = j["session_type"] as? String

            if var existing = catalog[sid] {
                existing.summary = summary; existing.goal = goal
                existing.outcome = outcome; existing.sessionType = sessionType
                catalog[sid] = existing
            } else {
                var entry = SessionCatalogEntry(
                    id: sid, project: "", projectPath: "",
                    firstPrompt: goal ?? summary ?? ""
                )
                entry.summary = summary; entry.goal = goal
                entry.outcome = outcome; entry.sessionType = sessionType
                catalog[sid] = entry
            }
        }
    }

    // MARK: - Source 4: Transcript directory listing

    private func loadTranscriptListings(into catalog: inout [String: SessionCatalogEntry]) {
        let projectsDir = homeDir.appendingPathComponent(".claude/projects")
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return }

        for projDir in projectDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let contents = try? fm.contentsOfDirectory(
                at: projDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }

            for item in contents {
                let name = item.lastPathComponent
                if name.hasSuffix(".jsonl") {
                    let sid = String(name.dropLast(6))
                    guard Self.isValidUUID(sid) else { continue }

                    if var existing = catalog[sid] {
                        existing.hasTranscript = true; existing.transcriptURL = item
                        catalog[sid] = existing
                    } else {
                        var entry = SessionCatalogEntry(
                            id: sid, project: Self.shortProjectName(projDir.lastPathComponent),
                            projectPath: "", firstPrompt: ""
                        )
                        entry.hasTranscript = true; entry.transcriptURL = item
                        catalog[sid] = entry
                    }
                }

                // Check for subagents directory
                var itemIsDir: ObjCBool = false
                if fm.fileExists(atPath: item.path, isDirectory: &itemIsDir), itemIsDir.boolValue {
                    let sid = item.lastPathComponent
                    guard Self.isValidUUID(sid) else { continue }
                    let subDir = item.appendingPathComponent("subagents")
                    if fm.fileExists(atPath: subDir.path) {
                        if var existing = catalog[sid] { existing.hasSubagents = true; catalog[sid] = existing }
                    }
                }
            }
        }
    }

    // MARK: - Source 5: Active sessions

    private func loadActiveSessions(into catalog: inout [String: SessionCatalogEntry]) {
        let sessionsDir = homeDir.appendingPathComponent(".claude/sessions")
        guard let files = try? fm.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }

        for file in files {
            guard file.pathExtension == "json",
                  let data = try? Data(contentsOf: file),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = j["sessionId"] as? String else { continue }

            let pid = j["pid"] as? Int
            let cwd = j["cwd"] as? String ?? ""
            var startTime: Date?
            if let ts = j["startedAt"] as? Double { startTime = Date(timeIntervalSince1970: ts / 1000.0) }

            let isRunning = pid.map { kill(Int32($0), 0) == 0 } ?? false

            if var existing = catalog[sid] {
                existing.isActive = isRunning; existing.activePid = pid
                if existing.projectPath.isEmpty && !cwd.isEmpty {
                    existing.projectPath = cwd; existing.project = Self.shortProjectName(cwd)
                }
                if let t = startTime, existing.startTime == nil { existing.startTime = t }
                catalog[sid] = existing
            } else {
                var entry = SessionCatalogEntry(
                    id: sid, project: Self.shortProjectName(cwd),
                    projectPath: cwd, firstPrompt: ""
                )
                entry.isActive = isRunning; entry.activePid = pid; entry.startTime = startTime
                catalog[sid] = entry
            }
        }
    }

    // MARK: - Compute Tier

    private func computeTier(_ entry: SessionCatalogEntry) -> SessionDataTier {
        let hasMeta = entry.inputTokens != nil || entry.durationMinutes != nil
        let hasFacets = entry.summary != nil || entry.goal != nil
        if entry.hasTranscript && hasMeta { return .rich }
        if hasMeta || hasFacets { return .meta }
        if entry.hasTranscript { return .transcript }
        return .historyOnly
    }

    // MARK: - Transcript Cost Scanning (with disk cache)

    private var costCacheURL: URL {
        homeDir.appendingPathComponent(".claude/aiterm-cost-cache.json")
    }

    private func loadCostCache() -> [String: [String: Any]] {
        guard let data = try? Data(contentsOf: costCacheURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            return [:]
        }
        return json
    }

    private func saveCostCache(_ cache: [String: [String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: cache, options: []) else { return }
        try? data.write(to: costCacheURL, options: .atomic)
    }

    /// Scan all catalog entries with transcripts and compute accurate costs.
    /// Uses a disk cache keyed by (sessionId, fileSize) to avoid re-scanning unchanged transcripts.
    private func batchScanTranscriptCosts(catalog: inout [String: SessionCatalogEntry]) {
        var cache = loadCostCache()
        var cacheHits = 0
        var cacheMisses = 0

        let keys = Array(catalog.keys)
        for key in keys {
            guard let entry = catalog[key],
                  entry.hasTranscript,
                  let url = entry.transcriptURL else { continue }

            // Check cache: keyed by sessionId, validated by file size
            let fileSize = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let cacheKey = key
            if let cached = cache[cacheKey],
               (cached["fileSize"] as? Int) == fileSize,
               let cost = cached["cost"] as? Double {
                // Cache hit — apply cached values
                catalog[key]?.inputTokens = cached["input"] as? Int
                catalog[key]?.outputTokens = cached["output"] as? Int
                catalog[key]?.cacheReadTokens = cached["cacheRead"] as? Int
                catalog[key]?.cacheCreationTokens = cached["cacheCreate"] as? Int
                catalog[key]?.estimatedCostUSD = cost
                if let model = cached["model"] as? String, !model.isEmpty {
                    catalog[key]?.model = model
                }
                if let daily = cached["dailyCosts"] as? [String: Double], !daily.isEmpty {
                    catalog[key]?.dailyCosts = daily
                }
                cacheHits += 1
                continue
            }

            // Cache miss — scan transcript
            let result = scanTranscriptForCost(url)
            if result.input > 0 || result.output > 0 {
                catalog[key]?.inputTokens = result.input
                catalog[key]?.outputTokens = result.output
                catalog[key]?.cacheReadTokens = result.cacheRead
                catalog[key]?.cacheCreationTokens = result.cacheCreate
                catalog[key]?.estimatedCostUSD = result.cost
                if !result.model.isEmpty { catalog[key]?.model = result.model }
                if !result.dailyCosts.isEmpty { catalog[key]?.dailyCosts = result.dailyCosts }

                // Store in cache
                var entry: [String: Any] = [
                    "fileSize": fileSize,
                    "input": result.input,
                    "output": result.output,
                    "cacheRead": result.cacheRead,
                    "cacheCreate": result.cacheCreate,
                    "cost": result.cost,
                    "model": result.model,
                ]
                if !result.dailyCosts.isEmpty { entry["dailyCosts"] = result.dailyCosts }
                cache[cacheKey] = entry
            }
            cacheMisses += 1
        }

        // Persist cache to disk
        if cacheMisses > 0 {
            saveCostCache(cache)
        }
    }

    /// Efficiently scan a JSONL transcript for cost data using chunked reading.
    /// Reads line-by-line via FileHandle to avoid loading 75MB+ files into memory.
    private func scanTranscriptForCost(_ url: URL) -> (input: Int, output: Int, cacheRead: Int, cacheCreate: Int, cost: Double, model: String, dailyCosts: [String: Double]) {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return (0, 0, 0, 0, 0, "", [:]) }
        defer { try? handle.close() }

        var totalInput = 0
        var totalOutput = 0
        var totalCacheRead = 0
        var totalCacheCreate = 0
        var totalCost = 0.0
        var lastModel = ""
        var dailyCosts: [String: Double] = [:]

        let chunkSize = 64 * 1024  // 64KB chunks
        var buffer = Data()

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            buffer.append(chunk)

            // Process complete lines
            while let newlineRange = buffer.range(of: Data([0x0A])) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

                // Fast filter: only parse lines containing "stop_reason"
                guard lineData.count > 50,
                      let lineStr = String(data: lineData, encoding: .utf8),
                      lineStr.contains("\"stop_reason\""),
                      !lineStr.contains("\"stop_reason\":null") else { continue }

                // Parse JSON
                guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let message = json["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { continue }

                let stopReason = message["stop_reason"]
                guard stopReason != nil && !(stopReason is NSNull) else { continue }

                let inp = usage["input_tokens"] as? Int ?? 0
                let outp = usage["output_tokens"] as? Int ?? 0
                let cr = usage["cache_read_input_tokens"] as? Int ?? 0
                let cc = usage["cache_creation_input_tokens"] as? Int ?? 0
                let model = message["model"] as? String ?? ""

                totalInput += inp
                totalOutput += outp
                totalCacheRead += cr
                totalCacheCreate += cc
                let turnCost = ModelPricing.turnCost(model: model, input: inp, output: outp, cacheRead: cr, cacheCreate: cc)
                totalCost += turnCost
                if !model.isEmpty { lastModel = model }

                // Extract date from top-level timestamp for per-day cost
                if let timestamp = json["timestamp"] as? String, timestamp.count >= 10 {
                    let dateKey = String(timestamp.prefix(10))
                    dailyCosts[dateKey, default: 0] += turnCost
                }
            }
        }

        // Process any remaining data in buffer (last line without trailing newline)
        if !buffer.isEmpty,
           let lineStr = String(data: buffer, encoding: .utf8),
           lineStr.contains("\"stop_reason\""),
           !lineStr.contains("\"stop_reason\":null"),
           let json = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any],
           let message = json["message"] as? [String: Any],
           let usage = message["usage"] as? [String: Any] {

            let stopReason = message["stop_reason"]
            if stopReason != nil && !(stopReason is NSNull) {
                let inp = usage["input_tokens"] as? Int ?? 0
                let outp = usage["output_tokens"] as? Int ?? 0
                let cr = usage["cache_read_input_tokens"] as? Int ?? 0
                let cc = usage["cache_creation_input_tokens"] as? Int ?? 0
                let model = message["model"] as? String ?? ""

                totalInput += inp
                totalOutput += outp
                totalCacheRead += cr
                totalCacheCreate += cc
                let turnCost = ModelPricing.turnCost(model: model, input: inp, output: outp, cacheRead: cr, cacheCreate: cc)
                totalCost += turnCost
                if !model.isEmpty { lastModel = model }

                // Extract date from top-level timestamp for per-day cost
                if let timestamp = json["timestamp"] as? String, timestamp.count >= 10 {
                    let dateKey = String(timestamp.prefix(10))
                    dailyCosts[dateKey, default: 0] += turnCost
                }
            }
        }

        return (totalInput, totalOutput, totalCacheRead, totalCacheCreate, totalCost, lastModel, dailyCosts)
    }

    // MARK: - Helpers

    static func shortProjectName(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        // Decode encoded project dirs (e.g., "-Users-nkanamar-personal-iTerm2" → "iTerm2")
        // The encoding replaces "/" with "-", so "-Users-nkanamar-personal-iTerm2" is "/Users/nkanamar/personal/iTerm2"
        if trimmed.hasPrefix("-") && !trimmed.contains("/") {
            let decoded = "/" + trimmed.dropFirst().replacingOccurrences(of: "-", with: "/")
            return (decoded as NSString).lastPathComponent
        }
        return (trimmed as NSString).lastPathComponent
    }

    private static func parseISO8601(_ string: String) -> Date? {
        isoFormatter.date(from: string) ?? isoFormatterBasic.date(from: string)
    }

    private static func isValidUUID(_ string: String) -> Bool {
        string.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
                      options: .regularExpression) != nil
    }
}
