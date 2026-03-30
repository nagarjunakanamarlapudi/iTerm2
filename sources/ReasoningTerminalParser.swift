import Foundation

/// Parses the visible terminal content of a Claude Code session to detect
/// thinking state and tool invocations in real time.
///
/// The parser works against the `compactLineDump` representation where spaces
/// are replaced with dots (`.`). It scans for Claude Code UI patterns such as
/// `.Thinking`, tool-call banners, and agent prompts.
@objc class ReasoningTerminalParser: NSObject {

    // MARK: - State tracking across parse calls

    /// Whether the session appeared to be in a thinking state the last time
    /// ``parseSession(_:into:)`` was called.
    private var wasThinking: Bool = false

    /// Accumulated thinking text from the terminal.
    private var accumulatedThinking: String = ""

    /// Tool calls seen in the previous parse — avoids re-emitting the same tool.
    private var lastSeenToolSignatures: Set<String> = []

    /// The session ID currently being tracked.
    private var currentSessionId: String = ""

    // MARK: - Regex patterns (compiled once)

    // Claude Code renders "  Thinking" or spinner variants "⠋ Thinking..."
    private static let thinkingPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"[.⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]+Thinking"#, options: [])
    }()

    // Tool call banner: "⎿ Read(file_path)" — dots replace leading spaces
    private static let toolCallPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"[.]+[⎿⏎].*?([A-Z][a-zA-Z]+)\("#, options: [])
    }()

    // Tool use line: "● Read file_path" or "● Bash command"
    private static let toolUseLinePattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"[.●]*([A-Z][a-zA-Z]+)\s"#, options: [])
    }()

    // Agent/subagent header: "Agent agent-name"
    private static let agentPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"Agent\s+([\w-]+)"#, options: [])
    }()

    // MARK: - Public API

    /// Parse the visible terminal content and update the data source.
    /// Call this periodically from vtReloadSidebar.
    @objc func parseSession(_ session: PTYSession,
                            sessionId: String,
                            into dataSource: ReasoningOverlayDataSource) {
        guard let screen = session.screen else { return }
        let dump: String = screen.compactLineDump() ?? ""
        if dump.isEmpty { return }

        currentSessionId = sessionId
        let lines = dump.components(separatedBy: "\n")
        parseDump(lines: lines, dataSource: dataSource)
    }

    /// Parse compactLineDump lines. Exposed for testability.
    func parseDump(lines: [String], dataSource: ReasoningOverlayDataSource) {
        let isCurrentlyThinking = detectThinking(in: lines)
        let toolCalls = detectToolCalls(in: lines)

        // Ensure session exists in data source
        dataSource.addSession(id: currentSessionId, label: currentSessionId)

        // Update thinking state
        if isCurrentlyThinking {
            let thinkingText = extractThinkingText(from: lines)
            if !thinkingText.isEmpty {
                accumulatedThinking = thinkingText
            }
        }

        // Transition: was thinking -> stopped => finalize into an entry
        if wasThinking && !isCurrentlyThinking {
            let finalText = accumulatedThinking.isEmpty ? "Thinking completed" : accumulatedThinking
            let agentName = detectAgent(in: lines)
            if let agentName = agentName {
                dataSource.appendSubagentThinking(finalText, subagentId: agentName, sessionId: currentSessionId)
            } else {
                dataSource.appendThinking(finalText, sessionId: currentSessionId)
            }
            accumulatedThinking = ""
        }

        wasThinking = isCurrentlyThinking

        // Emit new tool calls (avoid duplicates within the same screen)
        var currentToolSignatures = Set<String>()
        for tool in toolCalls {
            let sig = "\(tool.name):\(tool.args)"
            currentToolSignatures.insert(sig)
            if !lastSeenToolSignatures.contains(sig) {
                let agentName = detectAgent(in: lines)
                if let agentName = agentName {
                    dataSource.appendSubagentToolCall(name: tool.name, args: tool.args,
                                                      subagentId: agentName, sessionId: currentSessionId)
                } else {
                    dataSource.appendToolCall(name: tool.name, args: tool.args, sessionId: currentSessionId)
                }
            }
        }
        lastSeenToolSignatures = currentToolSignatures
    }

    // MARK: - Detection helpers

    private struct DetectedTool {
        let name: String
        let args: String
    }

    private func detectThinking(in lines: [String]) -> Bool {
        guard let pattern = Self.thinkingPattern else { return false }
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if pattern.firstMatch(in: line, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    private func detectToolCalls(in lines: [String]) -> [DetectedTool] {
        var tools: [DetectedTool] = []
        let patterns: [NSRegularExpression?] = [Self.toolCallPattern, Self.toolUseLinePattern]

        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            for pattern in patterns {
                guard let pattern else { continue }
                if let match = pattern.firstMatch(in: line, options: [], range: range),
                   match.numberOfRanges >= 2,
                   let nameRange = Range(match.range(at: 1), in: line) {
                    let toolName = String(line[nameRange])
                    if isKnownTool(toolName) {
                        // Extract args from the rest of the line after the tool name
                        let readable = line.replacingOccurrences(of: ".", with: " ")
                            .trimmingCharacters(in: .whitespaces)
                        let argsStart = readable.range(of: toolName + "(")
                        let args: String
                        if let argsStart = argsStart {
                            let afterParen = readable[argsStart.upperBound...]
                            if let closeParen = afterParen.firstIndex(of: ")") {
                                args = String(afterParen[..<closeParen])
                            } else {
                                args = String(afterParen.prefix(60))
                            }
                        } else {
                            args = readable
                        }
                        tools.append(DetectedTool(name: toolName, args: args))
                        break
                    }
                }
            }
        }
        return tools
    }

    private func detectAgent(in lines: [String]) -> String? {
        guard let pattern = Self.agentPattern else { return nil }
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if let match = pattern.firstMatch(in: line, options: [], range: range),
               match.numberOfRanges >= 2,
               let nameRange = Range(match.range(at: 1), in: line) {
                return String(line[nameRange])
            }
        }
        return nil
    }

    private func extractThinkingText(from lines: [String]) -> String {
        var capturing = false
        var collected: [String] = []

        for line in lines {
            if let pattern = Self.thinkingPattern {
                let range = NSRange(line.startIndex..., in: line)
                if pattern.firstMatch(in: line, options: [], range: range) != nil {
                    capturing = true
                    continue
                }
            }
            if capturing {
                let readable = line.replacingOccurrences(of: ".", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                if readable.isEmpty {
                    if !collected.isEmpty { collected.append("") }
                } else if readable.hasPrefix("⎿") || readable.hasPrefix("●") ||
                            readable.hasPrefix(">") || readable.hasPrefix("$") {
                    break
                } else {
                    collected.append(readable)
                }
            }
        }
        return collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tool name validation

    private static let knownTools: Set<String> = [
        "Read", "Edit", "Write", "Bash", "Grep", "Glob",
        "TodoRead", "TodoWrite", "Agent", "WebFetch",
        "Skill", "ToolSearch", "NotebookEdit",
        "MultiEdit", "Search", "Replace", "Task",
        "EnterWorktree", "ExitWorktree",
        "ListFiles", "ReadImage", "SendMessage",
        "TaskCreate", "TaskUpdate", "LSP",
    ]

    private func isKnownTool(_ name: String) -> Bool {
        Self.knownTools.contains(name)
    }
}
