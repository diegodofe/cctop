import AppKit
import os.log

private let logger = Logger(
    subsystem: "com.perkup.arborist",
    category: "Application"
)

class ArboristApplication: NSApplication {
    override func reportException(_ exception: NSException) {
        // Log instead of crashing
        let log = """
        EXCEPTION: \(Date())
        Name: \(exception.name.rawValue)
        Reason: \(exception.reason ?? "unknown")
        Stack:
        \(exception.callStackSymbols.prefix(15).joined(separator: "\n"))

        """
        logger.error(
            "Caught exception: \(exception.name.rawValue, privacy: .public) — \(exception.reason ?? "unknown", privacy: .public)"
        )

        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cctop/logs/_crash.log")
        let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        try? (existing + log).write(
            to: path, atomically: true, encoding: .utf8
        )

        // Don't call super — prevents the crash
        // super.reportException(exception) would terminate the app
    }
}
