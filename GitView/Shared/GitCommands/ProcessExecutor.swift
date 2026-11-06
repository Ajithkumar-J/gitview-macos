import Foundation

public protocol ProcessExecuting: Sendable {
    func run(executableURL: URL, arguments: [String], workingDirectory: URL?) async throws -> GitCommandResult
}

public struct ProcessExecutor: ProcessExecuting {
    public init() {}

    public func run(executableURL: URL, arguments: [String], workingDirectory: URL?) async throws -> GitCommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            process.environment = Self.gitProcessEnvironment()
            process.standardInput = FileHandle.nullDevice

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()

            let outputTask = Task.detached {
                outputPipe.fileHandleForReading.readDataToEndOfFile()
            }
            let errorTask = Task.detached {
                errorPipe.fileHandleForReading.readDataToEndOfFile()
            }

            process.waitUntilExit()

            let outputData = await outputTask.value
            let errorData = await errorTask.value
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let error = String(data: errorData, encoding: .utf8) ?? ""
            let command = ([executableURL.path] + arguments).joined(separator: " ")

            return GitCommandResult(
                exitCode: process.terminationStatus,
                standardOutput: output,
                standardError: error,
                command: command
            )
        }.value
    }

    public static func gitProcessEnvironment(
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = baseEnvironment
        let existingPath = environment["PATH"] ?? ""
        let pathParts = AppConstants.executableSearchPaths + existingPath
            .split(separator: ":")
            .map(String.init)

        var seenPaths = Set<String>()
        environment["PATH"] = pathParts
            .filter { path in
                guard !path.isEmpty, !seenPaths.contains(path) else {
                    return false
                }
                seenPaths.insert(path)
                return true
            }
            .joined(separator: ":")

        // GitView has no terminal: fail fast instead of waiting for a prompt
        // that can never be answered. Credential helpers and SSH agents still work.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // Background refreshes must not take index locks other tools may need.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        // Never open an editor for merge commit messages created by pull.
        environment["GIT_MERGE_AUTOEDIT"] = "no"

        return environment
    }
}
