import Foundation

// MARK: - MacVivid Logger

/// Simple logger with colored terminal output and optional file logging
enum Logger {

    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case success = "SUCCESS"
        case warning = "WARNING"
        case error = "ERROR"
    }

    /// Whether to show debug messages
    static var isVerbose = false

    /// Whether to write logs to file
    static var fileLoggingEnabled = false

    /// Log directory path
    private static var logDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.macvivid/logs"
    }

    /// Log file path
    private static var logFile: String {
        return "\(logDir)/macvivid.log"
    }

    // MARK: - Public API

    static func debug(_ message: String) {
        guard isVerbose else { return }
        log(.debug, message)
    }

    static func info(_ message: String) {
        log(.info, message)
    }

    static func success(_ message: String) {
        log(.success, message)
    }

    static func warning(_ message: String) {
        log(.warning, message)
    }

    static func error(_ message: String) {
        log(.error, message)
    }

    /// Print a step progress (e.g., "Step 1/3: Doing something")
    static func step(_ current: Int, of total: Int, _ message: String) {
        let prefix = "\(Emoji.check) Step \(current)/\(total):".colored(.green)
        print("\(prefix) \(message)")
        writeToFile("STEP \(current)/\(total): \(message)")
    }

    /// Print a section header
    static func section(_ title: String) {
        print("")
        print(title.styled(.bold, .cyan))
        print(String(repeating: "─", count: 40).colored(.dim))
    }

    /// Print a blank line
    static func newline() {
        print("")
    }

    // MARK: - Private

    private static func log(_ level: Level, _ message: String) {
        let emoji: String
        let color: ANSIColor

        switch level {
        case .debug:
            emoji = "🐛"
            color = .dim
        case .info:
            emoji = Emoji.info
            color = .cyan
        case .success:
            emoji = Emoji.check
            color = .green
        case .warning:
            emoji = Emoji.warning
            color = .yellow
        case .error:
            emoji = Emoji.cross
            color = .red
        }

        let formattedMessage = "\(emoji) \(message)".colored(color)
        print(formattedMessage)

        writeToFile("[\(level.rawValue)] \(message)")
    }

    private static func writeToFile(_ message: String) {
        guard fileLoggingEnabled else { return }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = dateFormatter.string(from: Date())
        let logLine = "[\(timestamp)] \(message)\n"

        // Ensure log directory exists
        let fm = FileManager.default
        if !fm.fileExists(atPath: logDir) {
            try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        }

        // Append to log file
        if let data = logLine.data(using: .utf8) {
            if fm.fileExists(atPath: logFile) {
                if let fileHandle = FileHandle(forWritingAtPath: logFile) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                fm.createFile(atPath: logFile, contents: data)
            }
        }
    }

    /// Setup the logger based on flags
    static func setup(verbose: Bool, logToFile: Bool = false) {
        isVerbose = verbose
        fileLoggingEnabled = logToFile
    }
}
