import AppKit
import os.log

private let logger = Logger(
    subsystem: "com.st0012.CctopMenubar",
    category: "WorktreeManager"
)

@MainActor
class WorktreeManager: ObservableObject {
    @Published var isCreating = false
    @Published var lastError: String?
    @Published var removingPaths: Set<String> = []
    /// Tracks which project paths have a running dev server process
    @Published var runningServers: [String: Process] = [:]
    /// Paths currently starting or stopping a server
    @Published var serverLoadingPaths: Set<String> = []
    /// Paths currently being shipped (PR creation in progress)
    @Published var shippingPaths: Set<String> = []

    let pwPath: String
    let projectsDir: String

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.pwPath = "\(home)/.local/bin/pw"
        self.projectsDir = "\(home)/Projects"
    }

    /// Check if a dev server is managed by us for this path
    func isServerRunning(for projectPath: String) -> Bool {
        if let proc = runningServers[projectPath] {
            return proc.isRunning
        }
        // Also check if someone started it externally (e.g. from Cursor terminal)
        if let port = Self.readPort(from: projectPath) {
            return Self.isPortOpen(port: port)
        }
        return false
    }

    // MARK: - Create Worktree

    func createWorktree(branch: String) {
        let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isCreating = true
        lastError = nil

        DispatchQueue.global(qos: .userInitiated).async { [pwPath] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-l", "-c", "\(pwPath) c \(trimmed)"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                DispatchQueue.main.async { [weak self] in
                    self?.isCreating = false
                    if process.terminationStatus != 0 {
                        self?.lastError = output.isEmpty
                            ? "pw exited with code \(process.terminationStatus)"
                            : output
                        logger.error("pw create failed: \(output, privacy: .public)")
                    } else {
                        logger.info("pw create succeeded")
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.isCreating = false
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Remove Worktree

    func removeWorktree(projectPath: String) {
        let name = URL(fileURLWithPath: projectPath).lastPathComponent
        let repoRoot = "\(projectsDir)/perkup-app"

        removingPaths.insert(projectPath)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Close Cursor window
            let closeScript = """
            tell application "System Events"
                tell process "Cursor"
                    set windowList to every window \
            whose title ends with "\(name)"
                    repeat with w in windowList
                        click button 1 of w
                    end repeat
                end tell
            end tell
            """
            var error: NSDictionary?
            NSAppleScript(source: closeScript)?
                .executeAndReturnError(&error)

            // Move node_modules to /tmp for fast cleanup
            let nmPath = "\(projectPath)/node_modules"
            let tmpPath = "/tmp/cctop-cleanup-\(ProcessInfo.processInfo.processIdentifier)-\(name)"
            if FileManager.default.fileExists(atPath: nmPath) {
                try? FileManager.default.moveItem(
                    atPath: nmPath, toPath: tmpPath
                )
                DispatchQueue.global(qos: .background).async {
                    try? FileManager.default.removeItem(atPath: tmpPath)
                }
            }

            // Remove worktree
            let removeScript = """
            git -C "\(repoRoot)" worktree remove "\(projectPath)" --force 2>/dev/null
            rm -rf "\(projectPath)" 2>/dev/null
            git -C "\(repoRoot)" worktree prune
            """
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-c", removeScript]
            try? proc.run()
            proc.waitUntilExit()

            logger.info("Removed worktree: \(name, privacy: .public)")
            DispatchQueue.main.async {
                self?.removingPaths.remove(projectPath)
            }
        }
    }

    // MARK: - Dev Server

    func startDevServer(projectPath: String) {
        let name = URL(fileURLWithPath: projectPath).lastPathComponent
        guard runningServers[projectPath] == nil ||
              runningServers[projectPath]?.isRunning != true else {
            return
        }

        serverLoadingPaths.insert(projectPath)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-l", "-c", "\(pwPath) s \(name)"]

        proc.terminationHandler = { [weak self] terminatedProc in
            DispatchQueue.main.async {
                self?.runningServers.removeValue(forKey: projectPath)
                self?.serverLoadingPaths.remove(projectPath)
                let code = terminatedProc.terminationStatus
                if code != 0 && code != 15 && code != 9 && code != 143 {
                    self?.lastError =
                        "\(name) server exited with code \(code)"
                }
            }
        }

        do {
            try proc.run()
            runningServers[projectPath] = proc
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                [weak self] in
                self?.serverLoadingPaths.remove(projectPath)
            }
        } catch {
            serverLoadingPaths.remove(projectPath)
            lastError = "Failed to start server: \(error.localizedDescription)"
        }
    }

    func stopDevServer(projectPath: String) {
        let name = URL(fileURLWithPath: projectPath).lastPathComponent
        serverLoadingPaths.insert(projectPath)

        // Kill managed process
        if let proc = runningServers[projectPath], proc.isRunning {
            proc.terminate()
        }
        runningServers.removeValue(forKey: projectPath)

        // Use pw k to kill by port
        DispatchQueue.global(qos: .userInitiated).async { [pwPath] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-l", "-c", "\(pwPath) k \(name)"]
            try? proc.run()
            proc.waitUntilExit()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            [weak self] in
            self?.serverLoadingPaths.remove(projectPath)
        }
    }

    /// Detect externally-started servers (e.g. from Cursor terminal)
    func refreshExternalServers(sessions: [Session]) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var changes = false
            for session in sessions {
                let path = session.projectPath
                guard Self.isPerkupWorktree(path),
                      let port = Self.readPort(from: path) else {
                    continue
                }
                let isOpen = Self.isPortOpen(port: port)
                let isTracked = self?.runningServers[path]?.isRunning == true

                if isOpen && !isTracked {
                    // External server detected — track it as a placeholder
                    changes = true
                }
            }
            if changes {
                DispatchQueue.main.async {
                    self?.objectWillChange.send()
                }
            }
        }
    }

    static func isPortOpen(port: Int) -> Bool {
        // Try IPv6 (::1) first — Vite binds to IPv6 by default
        let sock6 = socket(AF_INET6, SOCK_STREAM, 0)
        if sock6 >= 0 {
            defer { close(sock6) }
            var addr6 = sockaddr_in6()
            addr6.sin6_family = sa_family_t(AF_INET6)
            addr6.sin6_port = in_port_t(port).bigEndian
            addr6.sin6_addr = in6addr_loopback
            let result = withUnsafePointer(to: &addr6) {
                $0.withMemoryRebound(
                    to: sockaddr.self, capacity: 1
                ) {
                    connect(
                        sock6, $0,
                        socklen_t(MemoryLayout<sockaddr_in6>.size)
                    )
                }
            }
            if result == 0 { return true }
        }

        // Fallback to IPv4 (127.0.0.1)
        let sock4 = socket(AF_INET, SOCK_STREAM, 0)
        if sock4 >= 0 {
            defer { close(sock4) }
            var addr4 = sockaddr_in()
            addr4.sin_family = sa_family_t(AF_INET)
            addr4.sin_port = in_port_t(port).bigEndian
            addr4.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &addr4) {
                $0.withMemoryRebound(
                    to: sockaddr.self, capacity: 1
                ) {
                    connect(
                        sock4, $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
            if result == 0 { return true }
        }

        return false
    }

    // MARK: - Open Actions (via pw)

    func ship(projectPath: String, reviewer: String) {
        let name = URL(fileURLWithPath: projectPath).lastPathComponent
        shippingPaths.insert(projectPath)

        DispatchQueue.global(qos: .userInitiated).async { [weak self, pwPath] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [
                "-l", "-c",
                "\(pwPath) ship \(name) \(reviewer)",
            ]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            try? proc.run()
            proc.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            DispatchQueue.main.async {
                self?.shippingPaths.remove(projectPath)
                if proc.terminationStatus != 0 {
                    self?.lastError = "Ship failed: \(output)"
                } else {
                    // Refresh PRs so the session moves to In Review tab
                    self?.refreshPRs()
                }
            }
        }
    }

    func openCursor(projectPath: String) {
        let name = URL(fileURLWithPath: projectPath).lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async { [pwPath] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-l", "-c", "\(pwPath) o \(name)"]
            try? proc.run()
        }
    }

    func openWeb(projectPath: String) {
        let name = URL(fileURLWithPath: projectPath).lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async { [pwPath] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-l", "-c", "\(pwPath) w \(name)"]
            try? proc.run()
        }
    }

    // MARK: - Read Port

    static func readPort(from projectPath: String) -> Int? {
        let envPath = "\(projectPath)/apps/frontend/.env"
        guard let content = try? String(
            contentsOfFile: envPath, encoding: .utf8
        ) else { return nil }

        for line in content.components(separatedBy: .newlines) {
            if line.hasPrefix("PORT=") {
                let value = String(line.dropFirst(5))
                    .trimmingCharacters(in: .whitespaces)
                return Int(value)
            }
        }
        return nil
    }

    // MARK: - Focus Chrome Tab

    static func focusChromeTab(port: Int) {
        let url = "http://localhost:\(port)"
        let script = """
        tell application "Google Chrome"
            activate
            set found to false
            repeat with w in windows
                set tabIndex to 0
                repeat with t in tabs of w
                    set tabIndex to tabIndex + 1
                    if URL of t starts with "\(url)" then
                        set active tab index of w to tabIndex
                        set index of w to 1
                        set found to true
                        exit repeat
                    end if
                end repeat
                if found then exit repeat
            end repeat
            if not found then
                tell front window
                    make new tab with properties {URL:"\(url)"}
                end tell
            end if
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            logger.error(
                "Chrome focus failed: \(error, privacy: .public)"
            )
        }
    }

    // MARK: - Perkup Detection

    static func isPerkupWorktree(_ projectPath: String) -> Bool {
        let name = URL(fileURLWithPath: projectPath).lastPathComponent
        return name.hasPrefix("perkup-") || name == "perkup-app"
    }

    // MARK: - GitHub PR Integration

    struct PRInfo {
        let number: Int
        let url: String
        let title: String
        let branch: String
    }

    /// Map of branch name -> PR info, refreshed periodically
    @Published var openPRs: [String: PRInfo] = [:]

    func refreshPRs() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/gh")
            process.arguments = [
                "pr", "list",
                "--repo", "perkupapp/perkup-app",
                "--state", "open",
                "--json", "headRefName,url,number,title",
                "--limit", "50",
            ]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()

                struct GHPullRequest: Decodable {
                    let headRefName: String
                    let url: String
                    let number: Int
                    let title: String
                }

                let prs = try JSONDecoder().decode(
                    [GHPullRequest].self, from: data
                )
                var map: [String: PRInfo] = [:]
                for pr in prs {
                    map[pr.headRefName] = PRInfo(
                        number: pr.number,
                        url: pr.url,
                        title: pr.title,
                        branch: pr.headRefName
                    )
                }

                DispatchQueue.main.async {
                    self?.openPRs = map
                }
            } catch {
                logger.error(
                    "Failed to fetch PRs: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    static func openURL(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
