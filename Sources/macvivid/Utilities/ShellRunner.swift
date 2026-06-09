import Foundation

// MARK: - Shell Command Runner

/// Result of a shell command execution
struct ShellResult {
    let output: String
    let error: String
    let exitCode: Int32

    var isSuccess: Bool {
        return exitCode == 0
    }
}

/// Utility to run shell commands from Swift
enum ShellRunner {

    /// Run a shell command and return the result
    @discardableResult
    static func run(_ command: String, sudo: Bool = false) -> ShellResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        if sudo {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["/bin/zsh", "-c", command]
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
        }

        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ShellResult(
                output: "",
                error: "Failed to execute command: \(error.localizedDescription)",
                exitCode: -1
            )
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return ShellResult(
            output: output,
            error: errorOutput,
            exitCode: process.terminationStatus
        )
    }

    /// Run a command and return just the output string (convenience)
    static func output(_ command: String) -> String? {
        let result = run(command)
        return result.isSuccess ? result.output : nil
    }

    /// Check if a command-line tool is available
    static func isToolAvailable(_ tool: String) -> Bool {
        let result = run("which \(tool)")
        return result.isSuccess && !result.output.isEmpty
    }

    /// Run a command with sudo, prompting for password
    @discardableResult
    static func runWithSudo(_ command: String) -> ShellResult {
        return run(command, sudo: true)
    }

    /// Copy a file with sudo
    @discardableResult
    static func sudoCopy(from source: String, to destination: String) -> ShellResult {
        return runWithSudo("cp -f '\(source)' '\(destination)'")
    }

    /// Create a directory with sudo
    @discardableResult
    static func sudoMkdir(_ path: String) -> ShellResult {
        return runWithSudo("mkdir -p '\(path)'")
    }

    /// Remove a file/directory with sudo
    @discardableResult
    static func sudoRemove(_ path: String) -> ShellResult {
        return runWithSudo("rm -rf '\(path)'")
    }
}
