import Foundation

/// Reads Claude Code JSONL transcript files in real time and feeds reasoning
/// entries (thinking, tool_use, tool_result, text) into a ``ReasoningOverlayDataSource``.
///
/// Uses `DispatchSource.makeFileSystemObjectSource(.write)` to watch for
/// appends. I/O happens on a background serial queue; model updates are
/// dispatched to the main queue via the data source's thread-safe methods.
@objc class ReasoningTranscriptReader: NSObject {

    // MARK: - Constants

    /// On initial load, seek to this many bytes before EOF to avoid reading
    /// the entire transcript of a long session.
    private static let initialSeekBack: UInt64 = 256 * 1024

    // MARK: - State

    private var fileHandle: FileHandle?
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var byteOffset: UInt64 = 0
    private weak var dataSource: ReasoningOverlayDataSource?
    private let ioQueue = DispatchQueue(label: "com.aiterm.ReasoningTranscriptReader", qos: .utility)
    private var isWatching = false
    private var monitoredURL: URL?
    private var sessionId: String = ""

    deinit {
        stopWatching()
    }

    // MARK: - Public API

    /// Begin watching a JSONL transcript file and feeding entries into the data source.
    @objc func startWatching(transcriptURL: URL, sessionId: String, dataSource: ReasoningOverlayDataSource) {
        stopWatching()
        self.dataSource = dataSource
        self.monitoredURL = transcriptURL
        self.sessionId = sessionId

        // Ensure session exists in data source
        dataSource.addSession(id: sessionId, label: sessionId)

        ioQueue.async { [weak self] in
            self?.openAndWatch(url: transcriptURL, retriesLeft: 5)
        }
    }

    /// Stop watching and release resources.
    @objc func stopWatching() {
        dispatchSource?.cancel()
        dispatchSource = nil
        try? fileHandle?.close()
        fileHandle = nil
        isWatching = false
        monitoredURL = nil
    }

    // MARK: - Transcript discovery

    /// Locate the JSONL transcript file for a given Claude session ID.
    @objc class func findTranscript(sessionId: String) -> URL? {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let filename = "\(sessionId).jsonl"

        for projectDir in projectDirs {
            let candidate = projectDir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - File watching internals

    private func openAndWatch(url: URL, retriesLeft: Int) {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            if retriesLeft > 0 {
                ioQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.openAndWatch(url: url, retriesLeft: retriesLeft - 1)
                }
            } else {
                NSLog("AiTerm: ReasoningTranscriptReader could not open \(url.path) after retries")
            }
            return
        }

        self.fileHandle = handle

        // Seek to near the end for initial load
        let fileSize = handle.seekToEndOfFile()
        if fileSize > Self.initialSeekBack {
            let seekPos = fileSize - Self.initialSeekBack
            handle.seek(toFileOffset: seekPos)
            if let partial = readUntilNewline(handle: handle) {
                byteOffset = seekPos + UInt64(partial.count)
            } else {
                byteOffset = seekPos
            }
        } else {
            handle.seek(toFileOffset: 0)
            byteOffset = 0
        }

        // Parse whatever is already available
        processNewBytes()

        // Set up file system event monitoring (instant, no latency like FSEvents)
        let fd = handle.fileDescriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: ioQueue
        )
        source.setEventHandler { [weak self] in
            self?.processNewBytes()
        }
        source.setCancelHandler { [weak handle] in
            try? handle?.close()
        }
        source.resume()
        self.dispatchSource = source
        self.isWatching = true
        NSLog("AiTerm: Watching transcript at \(url.path)")
    }

    /// Read bytes from the current offset to the last complete newline,
    /// parse each line as JSON, and emit entries.
    private func processNewBytes() {
        guard let handle = fileHandle else { return }

        handle.seek(toFileOffset: byteOffset)
        let data = handle.readDataToEndOfFile()
        if data.isEmpty { return }

        // Only process up to the last complete newline
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            return
        }
        let usableCount = data.distance(from: data.startIndex, to: lastNewline) + 1
        let usableData = data.prefix(usableCount)
        byteOffset += UInt64(usableCount)

        guard let text = String(data: usableData, encoding: .utf8) else { return }

        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            parseLine(trimmed)
        }
    }

    // MARK: - JSONL line parsing

    private func parseLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let entryType = json["type"] as? String ?? ""
        let agentName = json["agentName"] as? String

        switch entryType {
        case "assistant":
            parseAssistantEntry(json, agentName: agentName)
        case "user":
            parseUserEntry(json, agentName: agentName)
        default:
            break
        }
    }

    private func parseAssistantEntry(_ json: [String: Any], agentName: String?) {
        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return }

        for block in content {
            guard let blockType = block["type"] as? String else { continue }

            switch blockType {
            case "thinking":
                if let thinking = block["thinking"] as? String, !thinking.isEmpty {
                    if let agentName = agentName {
                        dataSource?.addSubagent(id: agentName, name: agentName, sessionId: sessionId)
                        dataSource?.appendSubagentThinking(thinking, subagentId: agentName, sessionId: sessionId)
                    } else {
                        dataSource?.appendThinking(thinking, sessionId: sessionId)
                    }
                }

            case "tool_use":
                let toolName = block["name"] as? String ?? "tool"
                var args = ""
                if let input = block["input"] as? [String: Any] {
                    args = summarizeToolInput(toolName: toolName, input: input)
                }
                if let agentName = agentName {
                    dataSource?.addSubagent(id: agentName, name: agentName, sessionId: sessionId)
                    dataSource?.appendSubagentToolCall(name: toolName, args: args,
                                                       subagentId: agentName, sessionId: sessionId)
                } else {
                    dataSource?.appendToolCall(name: toolName, args: args, sessionId: sessionId)
                }

            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    // Text blocks are displayed as thinking (assistant reasoning visible to user)
                    if let agentName = agentName {
                        dataSource?.addSubagent(id: agentName, name: agentName, sessionId: sessionId)
                        dataSource?.appendSubagentThinking(text, subagentId: agentName, sessionId: sessionId)
                    } else {
                        dataSource?.appendThinking(text, sessionId: sessionId)
                    }
                }

            default:
                break
            }
        }
    }

    private func parseUserEntry(_ json: [String: Any], agentName: String?) {
        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return }

        for block in content {
            guard let blockType = block["type"] as? String, blockType == "tool_result" else { continue }

            var resultText: String
            if let text = block["content"] as? String {
                resultText = text
            } else if let contentArray = block["content"] as? [[String: Any]] {
                resultText = contentArray.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else {
                resultText = "(result)"
            }
            // Truncate long results
            if resultText.count > 500 {
                resultText = String(resultText.prefix(497)) + "..."
            }
            dataSource?.appendToolResult(summary: String(resultText.prefix(100)),
                                         detail: resultText,
                                         sessionId: sessionId)
        }
    }

    // MARK: - Helpers

    private func summarizeToolInput(toolName: String, input: [String: Any]) -> String {
        switch toolName {
        case "Read":
            return (input["file_path"] as? String).map { shortenPath($0) } ?? ""
        case "Write":
            return (input["file_path"] as? String).map { shortenPath($0) } ?? ""
        case "Edit":
            return (input["file_path"] as? String).map { shortenPath($0) } ?? ""
        case "Bash":
            if let cmd = input["command"] as? String {
                return cmd.count > 80 ? String(cmd.prefix(77)) + "..." : cmd
            }
            return ""
        case "Grep":
            return (input["pattern"] as? String) ?? ""
        case "Glob":
            return (input["pattern"] as? String) ?? ""
        case "Skill":
            return (input["skill"] as? String) ?? ""
        case "Agent":
            return (input["description"] as? String).map {
                $0.count > 60 ? String($0.prefix(57)) + "..." : $0
            } ?? ""
        default:
            for (_, value) in input {
                if let s = value as? String, !s.isEmpty {
                    return s.count > 80 ? String(s.prefix(77)) + "..." : s
                }
            }
            return ""
        }
    }

    private func shortenPath(_ path: String) -> String {
        let components = (path as NSString).pathComponents
        if components.count <= 2 { return path }
        return components.suffix(2).joined(separator: "/")
    }

    private func readUntilNewline(handle: FileHandle) -> Data? {
        var accumulated = Data()
        while true {
            let chunk = handle.readData(ofLength: 1024)
            if chunk.isEmpty { return accumulated.isEmpty ? nil : accumulated }
            if let nlIndex = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                let distance = chunk.distance(from: chunk.startIndex, to: nlIndex) + 1
                accumulated.append(chunk.prefix(distance))
                return accumulated
            }
            accumulated.append(chunk)
            if accumulated.count > 1024 * 64 {
                return accumulated
            }
        }
    }
}
