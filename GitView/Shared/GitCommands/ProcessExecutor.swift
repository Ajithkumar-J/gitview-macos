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
        // ...and ask through GitView's sign-in dialog instead: user names, passwords
        // or tokens, SSH key passphrases and "trust this new server?" questions.
        // Answers are kept by the Keychain credential helper, so this happens once.
        if let askPass = GitAskPass.scriptURL {
            if environment["GIT_ASKPASS"] == nil {
                environment["GIT_ASKPASS"] = askPass.path
            }
            if environment["SSH_ASKPASS"] == nil {
                environment["SSH_ASKPASS"] = askPass.path
                environment["SSH_ASKPASS_REQUIRE"] = "force"
            }
            if let app = GitAskPass.appExecutablePath {
                environment["GITVIEW_ASKPASS_APP"] = app
            }
            if let icon = GitAskPass.iconPath {
                environment["GITVIEW_ASKPASS_ICON"] = icon
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
    if [ -n "$GITVIEW_ASKPASS_APP" ] && [ -x "$GITVIEW_ASKPASS_APP" ]; then
    	exec "$GITVIEW_ASKPASS_APP" --askpass "$1"
    fi
    # Fallback outside GitView.app (for example while running tests).
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
    		display dialog question buttons {"Cancel", "Connect"} default button "Connect" cancel button "Cancel" with title "GitView: Trust This Server?" with icon caution
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
