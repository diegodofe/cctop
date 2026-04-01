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
        removingPaths.insert(projectPath)

        DispatchQueue.global(qos: .userInitiated).async {
            [weak self, pwPath] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-l", "-c", "\(pwPath) d \(name)"]
            try? proc.run()
            proc.waitUntilExit()

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
        // Use NSWorkspace to open the folder in Cursor (instant, no permissions needed)
        let cursorBundleID = "com.todesktop.230313mzl4w4u92"
        if let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: cursorBundleID
        ) {
            NSWorkspace.shared.open(
                [URL(fileURLWithPath: projectPath)],
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
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

    @Published var reviewingPaths: Set<String> = []
    @Published var syncingPaths: Set<String> = []
    @Published var pushingPaths: Set<String> = []
    @Published var isRefreshingAll = false

    func startReview(projectPath: String) {
        let name = URL(fileURLWithPath: projectPath).lastPathComponent
        reviewingPaths.insert(projectPath)

        DispatchQueue.global(qos: .userInitiated).async {
            [weak self, pwPath] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [
                "-l", "-c", "\(pwPath) review \(name)",
            ]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            try? proc.run()
            proc.waitUntilExit()

            DispatchQueue.main.async {
                self?.reviewingPaths.remove(projectPath)
            }
        }
    }

    func syncWorktree(projectPath: String) {
        let name = URL(fileURLWithPath: projectPath).lastPathComponent
        syncingPaths.insert(projectPath)

        runPwCommand(
            command: "sync", name: name, path: projectPath,
            loadingSet: \.syncingPaths
        )
    }

    func pushWorktree(projectPath: String) {
        let name = URL(fileURLWithPath: projectPath).lastPathComponent
        pushingPaths.insert(projectPath)

        runPwCommand(
            command: "push", name: name, path: projectPath,
            loadingSet: \.pushingPaths
        )
    }

    private func runPwCommand(
        command: String,
        name: String,
        path: String,
        loadingSet: ReferenceWritableKeyPath<
            WorktreeManager, Set<String>
        >
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            [weak self, pwPath] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [
                "-l", "-c", "\(pwPath) \(command) \(name)",
            ]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            try? proc.run()
            proc.waitUntilExit()

            let data = pipe.fileHandleForReading
                .readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)
                ?? ""
            let success = proc.terminationStatus == 0

            DispatchQueue.main.async {
                self?[keyPath: loadingSet].remove(path)
                if success {
                    if let sessions = self?.lastSessions {
                        self?.refreshGitSync(sessions: sessions)
                    }
                } else if output.contains("CONFLICT") {
                    self?.lastError =
                        "\(name): merge conflicts with main"
                } else if output.contains("uncommitted") {
                    self?.lastError =
                        "\(name): uncommitted changes"
                } else {
                    self?.lastError =
                        "\(name): \(command) failed"
                }
            }
        }
    }

    /// Store last sessions for post-sync refresh
    var lastSessions: [Session]?

    @Published var automergingPaths: Set<String> = []

    func enableAutomerge(projectPath: String) {
        let name = URL(fileURLWithPath: projectPath).lastPathComponent
        automergingPaths.insert(projectPath)

        runPwCommand(
            command: "automerge", name: name, path: projectPath,
            loadingSet: \.automergingPaths
        )
    }

    func openPR(projectPath: String) {
        let name = URL(fileURLWithPath: projectPath).lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async { [pwPath] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-l", "-c", "\(pwPath) pr \(name)"]
            try? proc.run()
        }
    }

    // MARK: - Perkup Detection

    /// Resolve a session's projectPath to its worktree root.
    /// Claude Code may be started from a subdirectory (e.g. apps/frontend),
    /// so we walk up the path looking for a perkup-* directory.
    static func worktreeRoot(for projectPath: String) -> String? {
        var url = URL(fileURLWithPath: projectPath)
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects").path
        while url.path.count > projectsDir.count {
            let name = url.lastPathComponent
            if name.hasPrefix("perkup-") || name == "perkup-app" {
                return url.path
            }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    static func isPerkupWorktree(_ projectPath: String) -> Bool {
        worktreeRoot(for: projectPath) != nil
    }

    // MARK: - GitHub PR Integration

    struct PRInfo {
        let number: Int
        let url: String
        let title: String
        let branch: String
        let merged: Bool
        let reviewDecision: String
        let autoMergeEnabled: Bool
    }

    struct GitSyncStatus {
        let ahead: Int    // commits ahead of remote
        let behind: Int   // commits behind main
        let unpushed: Bool
        let staged: Int   // number of staged files
        let unstaged: Int // number of modified/untracked files
    }

    /// Map of branch name -> PR info
    @Published var openPRs: [String: PRInfo] = [:]
    /// Map of project path -> git sync status
    @Published var gitSyncStatus: [String: GitSyncStatus] = [:]

    func refreshPRs() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = URL(
                fileURLWithPath: "/opt/homebrew/bin/gh"
            )
            process.arguments = [
                "pr", "list",
                "--repo", "perkupapp/perkup-app",
                "--state", "all",
                "--json",
                "headRefName,url,number,title,state,reviewDecision,autoMergeRequest",
                "--limit", "50",
            ]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading
                    .readDataToEndOfFile()

                struct AutoMerge: Decodable {
                    let enabledAt: String?
                }
                struct GHPullRequest: Decodable {
                    let headRefName: String
                    let url: String
                    let number: Int
                    let title: String
                    let state: String
                    let reviewDecision: String?
                    let autoMergeRequest: AutoMerge?
                }

                let prs = try JSONDecoder().decode(
                    [GHPullRequest].self, from: data
                )
                var map: [String: PRInfo] = [:]
                for pr in prs {
                    // Skip closed-not-merged PRs
                    if pr.state == "CLOSED" { continue }
                    map[pr.headRefName] = PRInfo(
                        number: pr.number,
                        url: pr.url,
                        title: pr.title,
                        branch: pr.headRefName,
                        merged: pr.state == "MERGED",
                        reviewDecision: pr.reviewDecision ?? "",
                        autoMergeEnabled: pr.autoMergeRequest != nil
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

    func refreshAll(
        sessions: [Session],
        reloadSessions: (() -> Void)? = nil
    ) {
        isRefreshingAll = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // PRs
            self?.refreshPRs()
            // Git sync (includes fetch)
            self?.refreshGitSyncSync(sessions: sessions)
            // Sessions
            DispatchQueue.main.async {
                reloadSessions?()
                self?.isRefreshingAll = false
            }
        }
    }

    /// Synchronous version for use in background thread
    private func refreshGitSyncSync(sessions: [Session]) {
        lastSessions = sessions
        var statuses: [String: GitSyncStatus] = [:]
        for session in sessions {
            guard Self.isPerkupWorktree(session.projectPath)
            else { continue }
            let path = session.projectPath

            let fetchProc = Process()
            fetchProc.executableURL = URL(
                fileURLWithPath: "/usr/bin/git"
            )
            fetchProc.arguments = [
                "-C", path, "fetch", "origin", "--quiet",
            ]
            fetchProc.standardOutput = Pipe()
            fetchProc.standardError = Pipe()
            try? fetchProc.run()
            fetchProc.waitUntilExit()

            let ahead = Self.gitCount(
                path: path,
                args: ["rev-list", "--count", "@{upstream}..HEAD"]
            )
            let behind = Self.gitCount(
                path: path,
                args: ["rev-list", "--count", "HEAD..origin/main"]
            )
            let unpushed = ahead == nil

            let statusOutput = Self.gitOutput(
                path: path, args: ["status", "--porcelain"]
            )
            var staged = 0
            var unstaged = 0
            for line in statusOutput.components(
                separatedBy: .newlines
            ) where line.count >= 2 {
                let idx = line.index(line.startIndex, offsetBy: 0)
                let wt = line.index(line.startIndex, offsetBy: 1)
                if line[idx] != " " && line[idx] != "?" {
                    staged += 1
                }
                if line[wt] != " " || line[idx] == "?" {
                    unstaged += 1
                }
            }

            statuses[path] = GitSyncStatus(
                ahead: ahead ?? 0,
                behind: behind ?? 0,
                unpushed: unpushed,
                staged: staged,
                unstaged: unstaged
            )
        }
        DispatchQueue.main.async { [weak self] in
            self?.gitSyncStatus = statuses
        }
    }

    func refreshGitSync(sessions: [Session]) {
        lastSessions = sessions
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var statuses: [String: GitSyncStatus] = [:]
            for session in sessions {
                guard Self.isPerkupWorktree(session.projectPath)
                else { continue }
                let path = session.projectPath

                // Fetch latest refs (quick, only updates refs)
                let fetchProc = Process()
                fetchProc.executableURL = URL(
                    fileURLWithPath: "/usr/bin/git"
                )
                fetchProc.arguments = [
                    "-C", path, "fetch", "origin",
                    "--quiet",
                ]
                fetchProc.standardOutput = Pipe()
                fetchProc.standardError = Pipe()
                try? fetchProc.run()
                fetchProc.waitUntilExit()

                // Get ahead of remote (unpushed commits)
                let ahead = Self.gitCount(
                    path: path,
                    args: [
                        "rev-list", "--count",
                        "@{upstream}..HEAD",
                    ]
                )
                // Get behind main
                let behind = Self.gitCount(
                    path: path,
                    args: [
                        "rev-list", "--count",
                        "HEAD..origin/main",
                    ]
                )
                // Check if tracking branch exists
                let unpushed = ahead == nil

                // Count staged and unstaged changes
                let statusOutput = Self.gitOutput(
                    path: path,
                    args: ["status", "--porcelain"]
                )
                var staged = 0
                var unstaged = 0
                for line in statusOutput.components(
                    separatedBy: .newlines
                ) where line.count >= 2 {
                    let idx = line.index(
                        line.startIndex, offsetBy: 0
                    )
                    let wt = line.index(
                        line.startIndex, offsetBy: 1
                    )
                    if line[idx] != " " && line[idx] != "?" {
                        staged += 1
                    }
                    if line[wt] != " " || line[idx] == "?" {
                        unstaged += 1
                    }
                }

                statuses[path] = GitSyncStatus(
                    ahead: ahead ?? 0,
                    behind: behind ?? 0,
                    unpushed: unpushed,
                    staged: staged,
                    unstaged: unstaged
                )
            }
            DispatchQueue.main.async {
                self?.gitSyncStatus = statuses
            }
        }
    }

    private static func gitOutput(
        path: String, args: [String]
    ) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", path] + args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading
                .readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private static func gitCount(
        path: String, args: [String]
    ) -> Int? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", path] + args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading
                .readDataToEndOfFile()
            let str = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(str ?? "")
        } catch {
            return nil
        }
    }

    // URL opening is handled by `pw pr` command
}
