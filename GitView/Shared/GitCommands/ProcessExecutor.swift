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
                Self.read(outputPipe.fileHandleForReading)
            }
            let errorTask = Task.detached {
                Self.read(errorPipe.fileHandleForReading)
            }

            process.waitUntilExit()

            let outputData = await outputTask.value
            let errorData = await errorTask.value
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let error = String(data: errorData, encoding: .utf8) ?? ""
            let command = Redactor.redact(([executableURL.path] + arguments).joined(separator: " "))

            return GitCommandResult(
                exitCode: process.terminationStatus,
                standardOutput: output,
                standardError: error,
                command: command
            )
        }.value
    }

    /// Most output GitView keeps from one command. Reading continues past it (so
    /// Git never blocks on a full pipe) but the rest is dropped, so a huge diff
    /// or a hostile repository cannot exhaust memory.
    public static let outputLimit = 64 * 1024 * 1024

    static func read(_ handle: FileHandle) -> Data {
        var data = Data()
        while let chunk = try? handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            if data.count < outputLimit {
                data.append(chunk.prefix(outputLimit - data.count))
            }
        }
        return data
    }

    /// Variables that would point Git at another repository or configuration,
    /// run other programs, print credentials (GIT_TRACE_CURL) or turn off
    /// certificate checks. GitView decides these itself.
    static func isUnsafeInheritedVariable(_ name: String) -> Bool {
        let exact: Set<String> = [
            "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
            "GIT_COMMON_DIR", "GIT_NAMESPACE", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_EXEC_PATH",
            "GIT_EXTERNAL_DIFF", "GIT_DIFF_OPTS", "GIT_PAGER", "GIT_EDITOR", "GIT_SEQUENCE_EDITOR", "GIT_SSL_NO_VERIFY",
            "GIT_CURL_VERBOSE", "GIT_REDACT_COOKIES", "GIT_PROTOCOL_FROM_USER", "GIT_ALLOW_PROTOCOL",
            "GITVIEW_ASKPASS", "GITVIEW_ASKPASS_APP", "GITVIEW_ASKPASS_ICON",
        ]
        return exact.contains(name)
            || name.hasPrefix("GIT_CONFIG_KEY_") || name.hasPrefix("GIT_CONFIG_VALUE_")
            || name.hasPrefix("GIT_TRACE") || name.hasPrefix("DYLD_")
    }

    /// Environment for other tools GitView starts (the `code` command): the
    /// usual tool folders on PATH, without Git overrides or GitView's prompt.
    public static func toolEnvironment(
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = baseEnvironment.filter { !isUnsafeInheritedVariable($0.key) }
        let existingPath = environment["PATH"] ?? ""
        let pathParts = AppConstants.executableSearchPaths + existingPath
            .split(separator: ":")
            .map(String.init)

        var seenPaths = Set<String>()
        environment["PATH"] = pathParts
            .filter { path in
                // Relative entries (".", "bin") would let the current folder supply programs.
                guard path.hasPrefix("/"), !seenPaths.contains(path) else {
                    return false
                }
                seenPaths.insert(path)
                return true
            }
            .joined(separator: ":")

        return environment
    }

    public static func gitProcessEnvironment(
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = toolEnvironment(baseEnvironment: baseEnvironment)

        // GitView has no terminal: fail fast instead of waiting for a prompt
        // that can never be answered. Credential helpers and SSH agents still work.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // ...and ask through GitView's sign-in dialog instead: user names, passwords
        // or tokens, SSH key passphrases and "trust this new server?" questions.
        // Answers are kept by the Keychain credential helper, so this happens once.
        // Inside GitView.app, Git and SSH run GitView's own (code-signed) binary
        // as the prompt; GITVIEW_ASKPASS tells it to ask and exit. Elsewhere
        // (tests) a small script shows an osascript dialog instead.
        let prompt: String?
        if let app = GitAskPass.appExecutablePath {
            prompt = app
            environment["GITVIEW_ASKPASS"] = "1"
        } else {
            prompt = GitAskPass.scriptURL?.path
            if let icon = GitAskPass.iconPath {
                environment["GITVIEW_ASKPASS_ICON"] = icon
            }
        }
        if let prompt {
            if environment["GIT_ASKPASS"] == nil {
                environment["GIT_ASKPASS"] = prompt
            }
            if environment["SSH_ASKPASS"] == nil {
                environment["SSH_ASKPASS"] = prompt
                environment["SSH_ASKPASS_REQUIRE"] = "force"
            }
        }
        // Background refreshes must not take index locks other tools may need.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        // Never open an editor for merge commit messages created by pull.
        environment["GIT_MERGE_AUTOEDIT"] = "no"

        return environment
    }
}

/// The program Git (`GIT_ASKPASS`) and SSH (`SSH_ASKPASS`) run to ask the user
/// a question. It shows a native dialog and prints the answer.
enum GitAskPass {
    static let scriptURL: URL? = install()
    static let iconPath: String? = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")?.path
    /// GitView's own executable, which shows the dialog itself (`--askpass`).
    /// Only inside GitView.app, not in tests or the Finder extension.
    static let appExecutablePath: String? = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.executablePath : nil

    static let script = #"""
    #!/bin/sh
    # Written by GitView. Git and SSH run this to ask for a user name, password,
    # token, key passphrase or a yes/no confirmation, because GitView has no
    # terminal. The answer is printed on standard output; exit 1 cancels.
    # Only used outside GitView.app (for example in tests); the app uses itself.
    exec /usr/bin/osascript - "$1" <<'APPLESCRIPT'
    on run argv
    	set question to item 1 of argv
    	set dialogIcon to note
    	set iconPath to system attribute "GITVIEW_ASKPASS_ICON"
    	if iconPath is not "" then
    		try
    			set dialogIcon to (POSIX file iconPath) as alias
    		end try
    	end if
    	activate
    	if question contains "(yes/no" then
    		display dialog question buttons {"Cancel", "Connect"} default button "Cancel" cancel button "Cancel" with title "GitView: Trust This Server?" with icon caution
    		return "yes"
    	end if
    	set promptText to question
    	if question starts with "Password for" then
    		set promptText to promptText & return & return & "GitHub, GitLab, Azure DevOps and Bitbucket need a personal access token (or app password) here, not your account password. It is saved in your Keychain."
    	end if
    	if question contains "assword" or question contains "assphrase" or question contains "PIN" then
    		set answerRecord to display dialog promptText default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK" cancel button "Cancel" with title "GitView: Sign In" with icon dialogIcon
    	else
    		set answerRecord to display dialog promptText default answer "" buttons {"Cancel", "OK"} default button "OK" cancel button "Cancel" with title "GitView: Sign In" with icon dialogIcon
    	end if
    	return text returned of answerRecord
    end run
    APPLESCRIPT

    """#

    /// Writes the script to Application Support (rewritten when GitView updates it).
    private static func install() -> URL? {
        let fileManager = FileManager.default
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = support.appendingPathComponent("GitView", isDirectory: true)
        let url = directory.appendingPathComponent("git-askpass.sh")
        do {
            if (try? String(contentsOf: url, encoding: .utf8)) != script {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try script.write(to: url, atomically: true, encoding: .utf8)
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }
}
