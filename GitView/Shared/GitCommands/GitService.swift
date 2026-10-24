import Foundation

public enum GitServiceError: LocalizedError, Equatable {
    case gitExecutableNotFound
    case notARepository(String)
    case emptyCommitMessage
    case noFilesSelected
    case emptyPullSource
    case detachedHeadRemoteOperation
    case commandFailed(GitCommandResult)

    public var errorDescription: String? {
        switch self {
        case .gitExecutableNotFound:
            "Git is not installed or could not be found."
        case .notARepository(let path):
            "\(path) is not part of a Git repository."
        case .emptyCommitMessage:
            "Enter a commit message before committing."
        case .noFilesSelected:
            "Select at least one file to commit."
        case .emptyPullSource:
            "Enter a branch to pull from, for example development or origin/development."
        case .detachedHeadRemoteOperation:
            "Pull and push are unavailable while the repository is in detached HEAD state."
        case .commandFailed(let result):
            result.standardError.isEmpty ? result.standardOutput : result.standardError
        }
    }
}

public final class GitService: Sendable {
    private let executor: ProcessExecuting
    public let gitExecutableURL: URL

    public init(
        executor: ProcessExecuting = ProcessExecutor(),
        fileManager: FileManager = .default,
        gitExecutableURL: URL? = nil
    ) throws {
        self.executor = executor

        if let gitExecutableURL {
            self.gitExecutableURL = gitExecutableURL
        } else if let resolvedURL = Self.resolveGitExecutable(fileManager: fileManager) {
            self.gitExecutableURL = resolvedURL
        } else {
            throw GitServiceError.gitExecutableNotFound
        }
    }

    public static func resolveGitExecutable(fileManager: FileManager = .default) -> URL? {
        for path in AppConstants.gitExecutableCandidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let pathEnvironment = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in pathEnvironment.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("git")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    public func loadRepository(at selectedURL: URL) async throws -> GitRepositorySnapshot {
        let rootPath = try await repositoryRoot(for: selectedURL)
        async let branch = currentBranch(in: rootPath)
        async let files = status(in: rootPath)
        let resolvedBranch = try await branch
        let loadedFiles = try await files
        let upstreamBranch = await currentUpstreamBranchBestEffort(in: rootPath)

        return GitRepositorySnapshot(
            selectedPath: selectedURL,
            rootPath: rootPath,
            branch: resolvedBranch,
            upstreamBranch: upstreamBranch,
            branches: [GitBranch(name: resolvedBranch, isCurrent: true)],
            files: loadedFiles
        )
    }

    public func repositoryRoot(for url: URL) async throws -> URL {
        let result = try await runGit(["-C", url.path, "rev-parse", "--show-toplevel"], workingDirectory: nil)
        guard result.success else {
            throw GitServiceError.notARepository(url.path)
        }

        let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path)
    }

    public func currentBranch(in repositoryURL: URL) async throws -> String {
        let result = try await runGit(["branch", "--show-current"], workingDirectory: repositoryURL)
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }

        let branch = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? "Detached HEAD" : branch
    }

    public func currentUpstreamBranch(in repositoryURL: URL) async throws -> String? {
        let result = try await runGit(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], workingDirectory: repositoryURL)
        guard result.success else {
            return nil
        }

        let upstream = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return upstream.isEmpty ? nil : upstream
    }

    public func currentUpstreamBranchBestEffort(in repositoryURL: URL) async -> String? {
        do {
            return try await currentUpstreamBranch(in: repositoryURL)
        } catch {
            return nil
        }
    }

    public func status(in repositoryURL: URL) async throws -> [GitFileStatus] {
        let result = try await runGit(["status", "--porcelain"], workingDirectory: repositoryURL)
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }

        return GitStatusParser.parsePorcelainV1(result.standardOutput)
    }

    public func branches(in repositoryURL: URL) async throws -> [GitBranch] {
        let result = try await runGit(["branch", "--format=%(refname:short)|%(HEAD)"], workingDirectory: repositoryURL)
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }

        return result.standardOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let parts = String(line).components(separatedBy: "|")
                guard let name = parts.first, !name.isEmpty else {
                    return nil
                }
                return GitBranch(name: name, isCurrent: parts.dropFirst().first == "*")
            }
    }

    public func searchRemoteBranches(matching query: String, in repositoryURL: URL) async throws -> [GitBranch] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return []
        }

        let pattern = "*\(trimmedQuery)*"
        let result = try await runGit(["ls-remote", "--heads", "origin", pattern], workingDirectory: repositoryURL)
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }

        return result.standardOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                guard let ref = line.split(separator: "\t").last else {
                    return nil
                }

                let branchName = ref.replacingOccurrences(of: "refs/heads/", with: "")
                return GitBranch(name: "origin/\(branchName)", isCurrent: false, isRemote: true)
            }
    }

    public func branchesBestEffort(in repositoryURL: URL, currentBranch: String) async -> [GitBranch] {
        do {
            let loadedBranches = try await branches(in: repositoryURL)
            if loadedBranches.isEmpty, currentBranch != "Detached HEAD" {
                return [GitBranch(name: currentBranch, isCurrent: true)]
            }
            return loadedBranches
        } catch {
            guard currentBranch != "Detached HEAD" else {
                return []
            }
            return [GitBranch(name: currentBranch, isCurrent: true)]
        }
    }

    public func diff(for file: GitFileStatus, mode: GitDiffMode, in repositoryURL: URL) async throws -> String {
        if file.state == .untracked {
            return try await untrackedFileDiff(for: file, in: repositoryURL)
        }

        let arguments: [String]
        switch mode {
        case .unstaged:
            arguments = ["diff", "--", file.path]
        case .staged:
            arguments = ["diff", "--cached", "--", file.path]
        }

        let result = try await runGit(arguments, workingDirectory: repositoryURL)
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }

        let diff = result.standardOutput.trimmingCharacters(in: .newlines)
        if diff.isEmpty {
            return "No \(mode.rawValue.lowercased()) diff is available for \(file.path)."
        }

        return diff
    }

    public func commitSelected(files: [GitFileStatus], message: String, in repositoryURL: URL) async throws -> String {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            throw GitServiceError.emptyCommitMessage
        }

        guard !files.isEmpty else {
            throw GitServiceError.noFilesSelected
        }

        let unstageResult = try await runGit(["restore", "--staged", "--", "."], workingDirectory: repositoryURL)
        guard unstageResult.success else {
            throw GitServiceError.commandFailed(unstageResult)
        }

        let addArguments = ["add", "--"] + files.map(\.path)
        let addResult = try await runGit(addArguments, workingDirectory: repositoryURL)
        guard addResult.success else {
            throw GitServiceError.commandFailed(addResult)
        }

        let commitResult = try await runGit(["commit", "-m", trimmedMessage], workingDirectory: repositoryURL)
        guard commitResult.success else {
            throw GitServiceError.commandFailed(commitResult)
        }

        let hashResult = try await runGit(["rev-parse", "--short", "HEAD"], workingDirectory: repositoryURL)
        let hash = hashResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        if hash.isEmpty {
            return commitResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return "Commit successful: \(hash)"
    }

    public func fetch(in repositoryURL: URL) async throws -> String {
        let result = try await runGit(["fetch"], workingDirectory: repositoryURL)
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }

        return commandOutput(from: result)
    }

    public func pullPreview(sourceBranch: String?, localFiles: [GitFileStatus], in repositoryURL: URL) async throws -> GitPullPreview {
        let branch = try await currentBranch(in: repositoryURL)
        guard branch != "Detached HEAD" else {
            throw GitServiceError.detachedHeadRemoteOperation
        }

        let target = try await pullTarget(for: sourceBranch, in: repositoryURL)

        if let sourceBranch = target.sourceBranch {
            _ = try await fetchBranch(sourceBranch, in: repositoryURL)
        } else {
            _ = try await fetch(in: repositoryURL)
        }

        async let incomingFiles = incomingChangedFiles(from: target.comparisonRef, in: repositoryURL)
        async let aheadBehindCounts = aheadBehind(comparedTo: target.comparisonRef, in: repositoryURL)
        let localChangedFiles = localFiles.map(\.path).sorted()
        let loadedIncomingFiles = try await incomingFiles.sorted()
        let counts = try await aheadBehindCounts
        let possibleConflicts = Array(Set(localChangedFiles).intersection(loadedIncomingFiles)).sorted()

        return GitPullPreview(
            target: target.displayName,
            sourceBranch: target.sourceBranch,
            aheadCount: counts.ahead,
            behindCount: counts.behind,
            localChangedFiles: localChangedFiles,
            incomingChangedFiles: loadedIncomingFiles,
            possibleConflictFiles: possibleConflicts
        )
    }

    public func incomingChangedFiles(in repositoryURL: URL) async throws -> [String] {
        try await incomingChangedFiles(from: "@{u}", in: repositoryURL)
    }

    public func incomingChangedFiles(from comparisonRef: String, in repositoryURL: URL) async throws -> [String] {
        let result = try await runGit(["diff", "--name-only", "HEAD..\(comparisonRef)"], workingDirectory: repositoryURL)
        guard result.success else {
            return []
        }

        return result.standardOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    public func aheadBehind(in repositoryURL: URL) async throws -> (ahead: Int, behind: Int) {
        try await aheadBehind(comparedTo: "@{u}", in: repositoryURL)
    }

    public func aheadBehind(comparedTo comparisonRef: String, in repositoryURL: URL) async throws -> (ahead: Int, behind: Int) {
        let result = try await runGit(["rev-list", "--left-right", "--count", "HEAD...\(comparisonRef)"], workingDirectory: repositoryURL)
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }

        let counts = result.standardOutput
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Int($0) }

        guard counts.count == 2 else {
            return (ahead: 0, behind: 0)
        }

        return (ahead: counts[0], behind: counts[1])
    }

    public func pull(strategy: GitPullStrategy, in repositoryURL: URL) async throws -> String {
        let result = try await runGit(["pull"] + strategy.gitArguments, workingDirectory: repositoryURL)
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }

        return commandOutput(from: result)
    }

    public func pull(sourceBranch: String?, strategy: GitPullStrategy, in repositoryURL: URL) async throws -> String {
        let target = try await pullTarget(for: sourceBranch, in: repositoryURL)
        let result: GitCommandResult
        if let sourceBranch = target.sourceBranch {
            result = try await runGit(["pull"] + strategy.gitArguments + ["origin", sourceBranch], workingDirectory: repositoryURL)
        } else {
            result = try await runGit(["pull"] + strategy.gitArguments, workingDirectory: repositoryURL)
        }

        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }

        return commandOutput(from: result)
    }

    public func push(in repositoryURL: URL) async throws -> String {
        let result = try await runGit(["push"], workingDirectory: repositoryURL)
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }

        return commandOutput(from: result)
    }

    public func pushSetUpstream(branch: String, in repositoryURL: URL) async throws -> String {
        guard branch != "Detached HEAD" else {
            throw GitServiceError.detachedHeadRemoteOperation
        }

        let result = try await runGit(["push", "--set-upstream", "origin", branch], workingDirectory: repositoryURL)
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }

        return commandOutput(from: result)
    }

    public func switchBranch(to branch: String, in repositoryURL: URL) async throws -> String {
        let result = try await runGit(["switch", branch], workingDirectory: repositoryURL)
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }

        return commandOutput(from: result)
    }

    public func switchBranch(to branch: GitBranch, in repositoryURL: URL) async throws -> String {
        let arguments: [String]
        if branch.isRemote, await localBranchExists(branch.localTrackingName, in: repositoryURL) {
            arguments = ["switch", branch.localTrackingName]
        } else if branch.isRemote {
            arguments = ["switch", "--track", branch.name]
        } else {
            arguments = ["switch", branch.name]
        }

        let result = try await runGit(arguments, workingDirectory: repositoryURL)
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }

        return commandOutput(from: result)
    }

    private func localBranchExists(_ branchName: String, in repositoryURL: URL) async -> Bool {
        let result = try? await runGit(["show-ref", "--verify", "--quiet", "refs/heads/\(branchName)"], workingDirectory: repositoryURL)
        return result?.success == true
    }

    public func fetchRemoteBranch(_ branch: GitBranch, in repositoryURL: URL) async throws -> String {
        guard branch.isRemote else {
            return ""
        }

        let remoteBranchName = branch.localTrackingName
        let result = try await runGit(["fetch", "origin", "\(remoteBranchName):refs/remotes/origin/\(remoteBranchName)"], workingDirectory: repositoryURL)
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }

        return commandOutput(from: result)
    }

    public func revert(file: GitFileStatus, in repositoryURL: URL) async throws -> String {
        let result: GitCommandResult
        if file.state == .untracked {
            result = try await runGit(["clean", "-f", "--", file.path], workingDirectory: repositoryURL)
        } else {
            result = try await runGit(["restore", "--staged", "--worktree", "--", file.path], workingDirectory: repositoryURL)
        }

        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }

        let output = commandOutput(from: result)
        return output == "Command completed successfully." ? "Reverted \(file.path)." : output
    }

    private func fetchBranch(_ sourceBranch: String, in repositoryURL: URL) async throws -> String {
        let result = try await runGit(["fetch", "origin", sourceBranch], workingDirectory: repositoryURL)
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }

        return commandOutput(from: result)
    }

    private func pullTarget(for sourceBranch: String?, in repositoryURL: URL) async throws -> PullTarget {
        let trimmedSource = sourceBranch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedSource.isEmpty {
            guard let upstream = try await currentUpstreamBranch(in: repositoryURL) else {
                throw GitServiceError.emptyPullSource
            }

            return PullTarget(displayName: upstream, sourceBranch: nil, comparisonRef: "@{u}")
        }

        let remoteBranch = trimmedSource.removingPrefix("origin/")
        guard !remoteBranch.isEmpty else {
            throw GitServiceError.emptyPullSource
        }

        return PullTarget(
            displayName: "origin/\(remoteBranch)",
            sourceBranch: remoteBranch,
            comparisonRef: "origin/\(remoteBranch)"
        )
    }

    private func runGit(_ arguments: [String], workingDirectory: URL?) async throws -> GitCommandResult {
        try await executor.run(
            executableURL: gitExecutableURL,
            // Ignore working-tree executable-bit noise consistently for status,
            // diffs and staging without changing the repository's configuration.
            arguments: ["-c", "core.filemode=false"] + arguments,
            workingDirectory: workingDirectory
        )
    }

    private func commandOutput(from result: GitCommandResult) -> String {
        let combinedOutput = [result.standardOutput, result.standardError]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        return combinedOutput.isEmpty ? "Command completed successfully." : combinedOutput
    }

    private func untrackedFileDiff(for file: GitFileStatus, in repositoryURL: URL) async throws -> String {
        let result = try await runGit(["diff", "--no-index", "--", "/dev/null", file.path], workingDirectory: repositoryURL)
        guard result.success || result.exitCode == 1 else {
            throw GitServiceError.commandFailed(result)
        }

        let diff = result.standardOutput.trimmingCharacters(in: .newlines)
        if diff.isEmpty {
            return "No diff is available for \(file.path)."
        }

        return diff
    }
}

private struct PullTarget: Sendable {
    let displayName: String
    let sourceBranch: String?
    let comparisonRef: String
}

private extension String {
    func removingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
