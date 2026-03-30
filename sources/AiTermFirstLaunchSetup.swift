import Foundation
import AppKit

/// Runs once on first launch to set up AiTerm hooks, directories, and preferences.
@objc class AiTermFirstLaunchSetup: NSObject {

    private static let setupVersionKey = "AiTermFirstLaunchSetupVersion"
    // Bump this when adding new migrations. Each version runs exactly once.
    private static let currentSetupVersion = 3

    @objc static func runIfNeeded() {
        let defaults = UserDefaults.standard
        let completedVersion = defaults.integer(forKey: setupVersionKey)
        if completedVersion >= currentSetupVersion { return }

        // Run on a background thread to avoid blocking the UI on first launch
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser.path
            let claudeDir = "\(home)/.claude"

            for version in (completedVersion + 1)...currentSetupVersion {
                NSLog("AiTerm: Running migration v\(version)...")
                backupExisting(claudeDir: claudeDir)
                runMigration(version: version, claudeDir: claudeDir, defaults: defaults)
                DispatchQueue.main.async {
                    defaults.set(version, forKey: setupVersionKey)
                }
                NSLog("AiTerm: Migration v\(version) complete.")
            }
        }
    }

    /// Each migration is a self-contained, incremental step.
    /// - v1: Initial setup — directories, hooks, settings merge, preferences copy
    /// When adding a new migration, bump currentSetupVersion and add a case here.
    /// Rules:
    ///   - NEVER overwrite a hook script the user may have customized. Use writeHookIfMissing().
    ///   - ALWAYS merge into settings.json, never overwrite.
    ///   - ALWAYS backup before modifying.
    private static func runMigration(version: Int, claudeDir: String, defaults: UserDefaults) {
        let fm = FileManager.default

        switch version {
        case 1:
            // Create directories with restrictive permissions
            for dir in ["hooks", "aiterm-permission-state", "iterm-sessions"] {
                let dirPath = "\(claudeDir)/\(dir)"
                try? fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dirPath)
            }
            // Also ensure the parent .claude dir has restrictive permissions
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: claudeDir)

            // Write hook scripts (only if they don't exist — never clobber user edits)
            writeHookScripts(hooksDir: "\(claudeDir)/hooks", overwrite: false)

            // Merge hooks into settings.json
            mergeHooksIntoSettings(settingsPath: "\(claudeDir)/settings.json")

            // Copy iTerm2 preferences to AiTerm bundle if needed
            copyPreferencesIfNeeded()

            // AiTerm defaults: left sidebar with vertical tabs
            defaults.set(2, forKey: "TabViewType")  // 0=Top, 1=Bottom, 2=Left
            // Don't override TabStyleWithAutomaticOption — preserve user's iTerm2 theme

            // Set sidebar width (15% of screen, min 160px)
            if defaults.double(forKey: "LeftTabBarWidth") < 150 {
                let screenWidth = NSScreen.main?.frame.width ?? 1440
                defaults.set(max(round(screenWidth * 0.15), 160), forKey: "LeftTabBarWidth")
            }

            // Always-save window restoration
            defaults.set(true, forKey: "NSQuitAlwaysKeepsWindows")

        case 2:
            // v2: Enforce AiTerm defaults for -suite isolation coexistence with iTerm2
            defaults.set(2, forKey: "TabViewType")  // Left sidebar
            // Don't override TabStyleWithAutomaticOption — preserve user's iTerm2 theme
            defaults.set(true, forKey: "NSQuitAlwaysKeepsWindows")
            if defaults.double(forKey: "LeftTabBarWidth") < 150 {
                let screenWidth = NSScreen.main?.frame.width ?? 1440
                defaults.set(max(round(screenWidth * 0.15), 160), forKey: "LeftTabBarWidth")
            }

        case 3:
            // v3: Strip Sparkle keys that were bulk-copied from iTerm2 prefs.
            // Without a valid SUFeedURL, Sparkle raises SUNoFeedURL and crashes.
            let sparkleKeys = [
                "SUEnableAutomaticChecks",
                "SUFeedURL",
                "SUHasLaunchedBefore",
                "SULastCheckTime",
                "SUScheduledCheckInterval",
            ]
            for key in sparkleKeys {
                defaults.removeObject(forKey: key)
            }

        default:
            NSLog("AiTerm: Unknown migration version \(version), skipping.")
        }
    }

    private static func backupExisting(claudeDir: String) {
        let fm = FileManager.default
        let timestamp = {
            let df = DateFormatter()
            df.dateFormat = "yyyyMMdd-HHmmss"
            return df.string(from: Date())
        }()
        let backupDir = "\(claudeDir)/backups/aiterm-install-\(timestamp)"
        try? fm.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupDir)

        let settingsPath = "\(claudeDir)/settings.json"
        if fm.fileExists(atPath: settingsPath) {
            try? fm.copyItem(atPath: settingsPath, toPath: "\(backupDir)/settings.json")
        }
        let hooksDir = "\(claudeDir)/hooks"
        if fm.fileExists(atPath: hooksDir) {
            try? fm.copyItem(atPath: hooksDir, toPath: "\(backupDir)/hooks")
        }
        NSLog("AiTerm: Backup saved to \(backupDir)")
    }

    private static func writeHookScripts(hooksDir: String, overwrite: Bool = false) {
        let notifyPermission = """
        #!/usr/bin/env python3
        # Sends a macOS notification and writes permission state file.
        # All JSON generation and osascript calls use Python to avoid shell injection.
        import json, os, re, subprocess, sys, time

        def main():
            try:
                data = json.load(sys.stdin)
            except (json.JSONDecodeError, ValueError):
                sys.exit(0)

            cwd = data.get("cwd", "unknown")
            project = os.path.basename(cwd)
            session_id = data.get("session_id", "")
            ntype = data.get("notification_type", "")

            if ntype in ("idle_prompt", "auth_success"):
                sys.exit(0)

            iterm_sid = os.environ.get("ITERM_SESSION_ID", "unknown")
            file_key = session_id if session_id else re.sub(r"[:/\\\\.]", "_", iterm_sid)

            state_dir = os.path.expanduser("~/.claude/aiterm-permission-state")
            os.makedirs(state_dir, exist_ok=True)
            state_path = os.path.join(state_dir, f"{file_key}.json")
            state = {"project": project, "session_id": session_id,
                     "iterm_session_id": iterm_sid, "timestamp": int(time.time())}
            with open(state_path, "w") as f:
                json.dump(state, f)
            os.chmod(state_path, 0o600)

            safe_project = re.sub(r"[^a-zA-Z0-9._-]", "_", project)
            debounce_file = f"/tmp/claude-notify-debounce-{safe_project}"
            now = int(time.time())
            try:
                with open(debounce_file, "r") as f:
                    last = int(f.read().strip())
                if now - last < 10:
                    sys.exit(0)
            except (FileNotFoundError, ValueError):
                pass
            with open(debounce_file, "w") as f:
                f.write(str(now))

            rate_file = "/tmp/claude-notify-last-sound"
            play_sound = True
            try:
                with open(rate_file, "r") as f:
                    last_sound = int(f.read().strip())
                if now - last_sound < 3:
                    play_sound = False
            except (FileNotFoundError, ValueError):
                pass
            with open(rate_file, "w") as f:
                f.write(str(now))

            escaped = project.replace("\\\\", "\\\\\\\\").replace('"', '\\\\"')
            script = f'display notification "Claude needs your attention" with title "Claude Code" subtitle "{escaped}"'
            if play_sound:
                script += ' sound name "Ping"'
            subprocess.run(["osascript", "-e", script], check=False)

        if __name__ == "__main__":
            main()
        """

        let clearPermission = """
        #!/bin/bash
        input=$(cat)
        session_id=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)
        iterm_sid="${ITERM_SESSION_ID:-unknown}"
        file_key="${session_id:-${iterm_sid//[:.\\/]/_}}"
        rm -f "$HOME/.claude/aiterm-permission-state/${file_key}.json"
        """

        let sessionMap = """
        #!/bin/bash
        input=$(cat)
        session_id=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)
        iterm_sid="${ITERM_SESSION_ID:-unknown}"
        if [ -n "$session_id" ] && [ "$iterm_sid" != "unknown" ]; then
            mkdir -p ~/.claude/iterm-sessions
            echo "$session_id" > ~/.claude/iterm-sessions/"${iterm_sid//[:.\\/]/_}"
        fi
        """

        let scripts: [(String, String)] = [
            ("notify-permission.sh", notifyPermission),
            ("clear-permission.sh", clearPermission),
            ("iterm-session-map.sh", sessionMap),
        ]

        for (name, content) in scripts {
            let path = "\(hooksDir)/\(name)"
            // Skip if file already exists and we're not overwriting (respect user edits)
            if !overwrite && FileManager.default.fileExists(atPath: path) {
                NSLog("AiTerm: Hook \(name) already exists, skipping.")
                continue
            }
            // Dedent: remove leading 8-space indentation from heredoc
            let dedented = content.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in
                    let s = String(line)
                    if s.hasPrefix("        ") { return String(s.dropFirst(8)) }
                    return s
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"

            try? dedented.write(toFile: path, atomically: true, encoding: .utf8)

            // Set owner-only executable permissions (0700) for hook scripts
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        }
        NSLog("AiTerm: Hook scripts written to \(hooksDir)")
    }

    private static func mergeHooksIntoSettings(settingsPath: String) {
        var settings: [String: Any]
        if let data = FileManager.default.contents(atPath: settingsPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        } else {
            settings = [:]
        }

        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]

        let aitermHooks: [(String, String)] = [
            ("SessionStart", "~/.claude/hooks/iterm-session-map.sh"),
            ("Notification", "~/.claude/hooks/notify-permission.sh"),
            ("PostToolUse", "~/.claude/hooks/clear-permission.sh"),
            ("Stop", "~/.claude/hooks/clear-permission.sh"),
        ]

        for (event, command) in aitermHooks {
            var eventEntries = (hooks[event] as? [[String: Any]]) ?? []
            let alreadyExists = eventEntries.contains { entry in
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return entryHooks.contains { ($0["command"] as? String) == command }
            }
            if !alreadyExists {
                eventEntries.append(["hooks": [["type": "command", "command": command]]])
            }
            hooks[event] = eventEntries
        }

        settings["hooks"] = hooks

        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: settingsPath))
            // Ensure settings file has restrictive permissions (owner read/write only)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsPath)
        }
        NSLog("AiTerm: Hooks merged into \(settingsPath)")
    }

    private static func copyPreferencesIfNeeded() {
        let aitermDefaults = UserDefaults(suiteName: "com.nkanamar.aiterm")
        if aitermDefaults?.object(forKey: "New Bookmarks") != nil { return } // Already has profiles

        // Try to import from iTerm2
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["export", "com.googlecode.iterm2", "-"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else { return }

        let importTask = Process()
        importTask.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        importTask.arguments = ["import", "com.nkanamar.aiterm", "-"]
        let importPipe = Pipe()
        importTask.standardInput = importPipe
        try? importTask.run()
        importPipe.fileHandleForWriting.write(data)
        importPipe.fileHandleForWriting.closeFile()
        importTask.waitUntilExit()

        NSLog("AiTerm: Preferences copied from iTerm2")

        // Strip Sparkle auto-update keys — AiTerm has no feed URL, and the
        // bulk import copies SUEnableAutomaticChecks=YES from iTerm2 which
        // causes Sparkle to schedule a check, hit the missing SUFeedURL, and crash.
        let sparkleKeys = [
            "SUEnableAutomaticChecks",
            "SUFeedURL",
            "SUHasLaunchedBefore",
            "SULastCheckTime",
            "SUScheduledCheckInterval",
        ]
        for key in sparkleKeys {
            aitermDefaults?.removeObject(forKey: key)
        }
        NSLog("AiTerm: Stripped Sparkle keys to prevent SUNoFeedURL crash")
    }
}
