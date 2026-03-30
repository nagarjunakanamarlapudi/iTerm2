import Foundation
import AppKit

/// Detects Claude Code processes and team/agent configurations.
/// Monitors ~/.claude/teams/ for agent swarm activity.
@objc class VTClaudeDetector: NSObject {
    struct TeamMember {
        let name: String
        let role: String
        let isRunning: Bool
        let tmuxPaneId: String?
    }

    struct Team {
        let name: String
        let sessionId: String
        let members: [TeamMember]
    }

    /// Check if a process tree rooted at the given PID contains a Claude Code process.
    @objc static func isClaudeProcess(pid: pid_t) -> Bool {
        // Check the process itself (full path: /Users/x/.local/share/claude/versions/X.Y.Z)
        if isClaudeBinary(pid: pid) { return true }
        // Check direct children
        for childPid in childPIDs(of: pid) {
            if isClaudeBinary(pid: childPid) { return true }
            // Check grandchildren (shell → node → claude)
            for grandchild in childPIDs(of: childPid) {
                if isClaudeBinary(pid: grandchild) { return true }
            }
        }
        return false
    }

    @objc static func isClaudeBinary(pid: pid_t) -> Bool {
        let path = processPath(pid: pid)
        if path.isEmpty { return false }
        // Match: .local/share/claude/, /claude (direct), claude-code
        return path.contains("/claude/") || path.hasSuffix("/claude") || path.contains("claude-code")
    }

    /// Scan ~/.claude/teams/ for active team configurations.
    static func detectTeams() -> [Team] {
        let teamsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/teams")
        guard let teamDirs = try? FileManager.default.contentsOfDirectory(
            at: teamsDir, includingPropertiesForKeys: nil
        ) else { return [] }

        var teams: [Team] = []
        for teamDir in teamDirs where teamDir.hasDirectoryPath {
            // Security: verify directory resolves within ~/.claude/ after symlink resolution
            guard isWithinClaudeDir(teamDir) else { continue }
            let configFile = teamDir.appendingPathComponent("config.json")
            guard let data = try? Data(contentsOf: configFile),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let sessionId = (json["leadSessionId"] as? String) ?? (json["sessionId"] as? String) ?? teamDir.lastPathComponent

            let teamName = (json["name"] as? String) ?? teamDir.lastPathComponent
            var members: [TeamMember] = []

            // Read members from config.json
            if let memberList = json["members"] as? [[String: Any]] {
                for m in memberList {
                    let name = (m["name"] as? String) ?? "agent"
                    let role = (m["agentType"] as? String) ?? "agent"
                    let paneId = m["tmuxPaneId"] as? String
                    let isRunning = !(paneId?.isEmpty ?? true)
                    members.append(TeamMember(name: name, role: role, isRunning: isRunning, tmuxPaneId: paneId))
                }
            }

            // Discover agents from inboxes directory — each .json file is an agent's inbox
            let inboxDir = teamDir.appendingPathComponent("inboxes")
            if let inboxFiles = try? FileManager.default.contentsOfDirectory(
                at: inboxDir, includingPropertiesForKeys: nil
            ) {
                for file in inboxFiles where file.lastPathComponent.hasSuffix(".json") {
                    let agentName = file.deletingPathExtension().lastPathComponent
                    // Skip team-lead (already in members) and duplicates
                    if agentName == "team-lead" { continue }
                    if members.contains(where: { $0.name == agentName }) { continue }
                    members.append(TeamMember(name: agentName, role: "agent", isRunning: true, tmuxPaneId: nil))
                }
            }

            teams.append(Team(name: teamName, sessionId: sessionId, members: members))
        }
        return teams
    }

    /// Obj-C bridgeable version of detectTeams — returns array of dictionaries.
    @objc static func detectTeamsAsDict() -> [[String: Any]] {
        let teamsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/teams")
        guard let teamDirs = try? FileManager.default.contentsOfDirectory(at: teamsDir, includingPropertiesForKeys: nil) else { return [] }

        var results: [[String: Any]] = []
        for teamDir in teamDirs where teamDir.hasDirectoryPath {
            // Security: verify directory resolves within ~/.claude/ after symlink resolution
            guard isWithinClaudeDir(teamDir) else { continue }
            let configFile = teamDir.appendingPathComponent("config.json")
            guard let data = try? Data(contentsOf: configFile),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let teamName = (json["name"] as? String) ?? teamDir.lastPathComponent
            let sessionId = (json["leadSessionId"] as? String) ?? ""
            let createdAt = json["createdAt"] as? NSNumber ?? 0

            var members: [[String: Any]] = []
            // Members from config
            if let ml = json["members"] as? [[String: Any]] {
                for m in ml {
                    members.append([
                        "name": m["name"] as? String ?? "agent",
                        "role": m["agentType"] as? String ?? "agent",
                    ])
                }
            }
            // Agents from inbox filenames
            let inboxDir = teamDir.appendingPathComponent("inboxes")
            if let files = try? FileManager.default.contentsOfDirectory(at: inboxDir, includingPropertiesForKeys: nil) {
                for f in files where f.lastPathComponent.hasSuffix(".json") {
                    let name = f.deletingPathExtension().lastPathComponent
                    if name == "team-lead" { continue }
                    if members.contains(where: { ($0["name"] as? String) == name }) { continue }
                    members.append(["name": name, "role": "agent"])
                }
            }

            results.append([
                "name": teamName,
                "sessionId": sessionId,
                "createdAt": createdAt,
                "members": members,
            ])
        }
        return results
    }

    // MARK: - Process Utilities

    private static func processName(pid: pid_t) -> String {
        let name = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXPATHLEN))
        defer { name.deallocate() }
        proc_name(pid, name, UInt32(MAXPATHLEN))
        return String(cString: name)
    }

    private static func processPath(pid: pid_t) -> String {
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXPATHLEN))
        defer { buf.deallocate() }
        let len = proc_pidpath(pid, buf, UInt32(MAXPATHLEN))
        guard len > 0 else { return "" }
        return String(cString: buf)
    }

    /// Get the --agent-name from a Claude process's command line args.
    @objc static func agentName(forPid pid: pid_t) -> String? {
        let args = processArgs(pid: pid)
        for (i, arg) in args.enumerated() {
            if arg == "--agent-name" && i + 1 < args.count { return args[i + 1] }
        }
        return nil
    }

    /// Get the --team-name from a Claude process's command line args.
    @objc static func teamName(forPid pid: pid_t) -> String? {
        let args = processArgs(pid: pid)
        for (i, arg) in args.enumerated() {
            if arg == "--team-name" && i + 1 < args.count { return args[i + 1] }
        }
        // Also check --teammate-mode (team lead) — it won't have --team-name
        // but we can derive from --parent-session-id
        return nil
    }

    /// Get the --parent-session-id from a Claude process's command line args.
    @objc static func parentSessionId(forPid pid: pid_t) -> String? {
        let args = processArgs(pid: pid)
        for (i, arg) in args.enumerated() {
            if arg == "--parent-session-id" && i + 1 < args.count { return args[i + 1] }
        }
        return nil
    }

    /// Extract session ID from a Claude process's command line args (--resume or --session-id).
    @objc static func sessionId(forPid pid: pid_t) -> String? {
        let args = processArgs(pid: pid)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        for (i, arg) in args.enumerated() {
            if (arg == "--resume" || arg == "--session-id" || arg == "-r") && i + 1 < args.count {
                let val = args[i + 1]
                if val.count >= 8 && val.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
                    return val
                }
            }
        }
        return nil
    }

    // MARK: - Path Security

    /// The expected base path for all Claude data files.
    private static let expectedClaudeBase: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude").path
    }()

    /// Validate that a file URL resolves (after symlink resolution) to a path
    /// within ~/.claude/. Returns false if the file is a symlink escape.
    private static func isWithinClaudeDir(_ file: URL) -> Bool {
        let resolved = file.resolvingSymlinksInPath()
        return resolved.path.hasPrefix(expectedClaudeBase)
    }

    // MARK: - Session ID Mapping via ~/.claude/iterm-sessions/

    private static let itermSessionsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/iterm-sessions")
    }()

    /// Write the mapping: ITERM_SESSION_ID → Claude session ID
    @objc static func saveSessionMapping(itermSessionId: String, claudeSessionId: String) {
        let dir = itermSessionsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let file = dir.appendingPathComponent(itermSessionId.replacingOccurrences(of: "/", with: "_")
                                                              .replacingOccurrences(of: ":", with: "_"))
        try? claudeSessionId.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Read the mapping: ITERM_SESSION_ID → Claude session ID
    /// Falls back to UUID-suffix matching if exact match fails (tab indices change on restore).
    @objc static func loadSessionMapping(itermSessionId: String) -> String? {
        let safeName = itermSessionId.replacingOccurrences(of: "/", with: "_")
                                     .replacingOccurrences(of: ":", with: "_")
        let file = itermSessionsDir.appendingPathComponent(safeName)

        // Security: verify file resolves within ~/.claude/ after symlink resolution
        guard isWithinClaudeDir(file) else { return nil }

        // Try exact match first
        if let content = try? String(contentsOf: file, encoding: .utf8) {
            let sid = content.trimmingCharacters(in: .whitespacesAndNewlines)
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            if sid.count >= 8, sid.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
                return sid
            }
        }

        // Fall back: match by UUID suffix (the w0tXpN prefix changes on restore)
        let uuid = itermSessionId.components(separatedBy: ":").last ?? itermSessionId
        guard uuid.count >= 8 else { return nil }
        if let files = try? FileManager.default.contentsOfDirectory(at: itermSessionsDir, includingPropertiesForKeys: nil) {
            for f in files where f.lastPathComponent.hasSuffix(uuid) {
                guard isWithinClaudeDir(f) else { continue }
                if let content = try? String(contentsOf: f, encoding: .utf8) {
                    let sid = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
                    if sid.count >= 8, sid.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
                        return sid
                    }
                }
            }
        }

        return nil
    }

    /// Discover and persist the Claude session ID for a specific iTerm2 session.
    /// Read the Claude session ID for this iTerm2 session.
    /// The mapping is written by a Claude SessionStart hook to ~/.claude/iterm-sessions/.
    /// This is deterministic: each iTerm2 session has exactly one mapping file.
    @objc static func captureClaudeSessionId(forItermSessionId itermSessionId: String) -> String? {
        return loadSessionMapping(itermSessionId: itermSessionId)
    }

    private static func processArgs(pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buf.deallocate() }
        guard sysctl(&mib, 3, buf, &size, nil, 0) == 0 else { return [] }

        // First 4 bytes: argc
        guard size > MemoryLayout<Int32>.size else { return [] }
        let argc = buf.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }

        // Skip argc (4 bytes), then the executable path (null-terminated), then padding nulls
        var offset = MemoryLayout<Int32>.size
        // Skip exec path
        while offset < size && buf[offset] != 0 { offset += 1 }
        // Skip nulls after exec path
        while offset < size && buf[offset] == 0 { offset += 1 }

        // Now read argc null-terminated strings
        var args: [String] = []
        for _ in 0..<argc {
            guard offset < size else { break }
            var end = offset
            while end < size && buf[end] != 0 { end += 1 }
            if end > offset {
                let data = Data(bytes: buf + offset, count: end - offset)
                let str = String(data: data, encoding: .utf8) ?? ""
                args.append(str)
            }
            offset = end + 1
        }
        return args
    }

    // MARK: - Permission State via ~/.claude/aiterm-permission-state/

    private static let permissionStateDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/aiterm-permission-state")
    }()

    /// Returns pending permission state files keyed by iTerm session ID.
    /// Each value contains the tool name, project, and timestamp.
    @objc static func pendingPermissions() -> [String: [String: Any]] {
        let dir = permissionStateDir
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return [:]
        }
        var result: [String: [String: Any]] = [:]
        for file in files where file.pathExtension == "json" {
            // Security: verify file resolves within ~/.claude/ after symlink resolution
            guard isWithinClaudeDir(file) else { continue }
            guard let data = try? Data(contentsOf: file),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let itermSid = dict["iterm_session_id"] as? String else { continue }
            result[itermSid] = dict
        }
        return result
    }

    /// Remove stale permission state files older than 10 minutes
    @objc static func cleanStalePermissions() {
        let dir = permissionStateDir
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-600) // 10 minutes
        for file in files where file.pathExtension == "json" {
            // Security: verify file resolves within ~/.claude/ after symlink resolution
            guard isWithinClaudeDir(file) else { continue }
            if let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
               let mod = attrs.contentModificationDate, mod < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private static func childPIDs(of parentPid: pid_t) -> [pid_t] {
        let bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        let count = Int(bufferSize) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: count)
        let actualSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        let actualCount = Int(actualSize) / MemoryLayout<pid_t>.size

        var children: [pid_t] = []
        for i in 0..<actualCount {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var info = proc_bsdinfo()
            let infoSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            if infoSize > 0 && info.pbi_ppid == parentPid {
                children.append(pid)
            }
        }
        return children
    }
}

/// Watches ~/.claude/teams/ for changes using FSEvents.
@objc class VTClaudeTeamWatcher: NSObject {
    private var stream: FSEventStreamRef?
    var onChange: (() -> Void)?

    @objc func startWatching() {
        let paths = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/teams").path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/tasks").path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/aiterm-permission-state").path,
        ] as CFArray

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<VTClaudeTeamWatcher>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async {
                watcher.onChange?()
            }
        }

        stream = FSEventStreamCreate(
            nil, callback, &context,
            paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // 1 second latency
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        )

        if let stream {
            FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            FSEventStreamStart(stream)
        }
    }

    @objc func stopWatching() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit {
        stopWatching()
    }
}
