import Foundation

public enum GitServiceError: LocalizedError, Equatable {
    case gitExecutableNotFound
    case notARepository(String)
    case emptyCommitMessage
    case noFilesSelected
    case nothingStaged
    case emptyPullSource
    case noRemoteConfigured
    case detachedHeadRemoteOperation
    case commandFailed(GitCommandResult)

    public var errorDescription: String? {
        switch self {
        case .gitExecutableNotFound:
            "Git is not installed or could not be found."
        case .notARepository(let path):
            "This folder is not part of a Git repository.\n\n\(path)"
        case .emptyCommitMessage:
            "Enter a commit message before committing."
        case .noFilesSelected:
            "Select at least one file."
        case .nothingStaged:
            "Stage at least one file before committing."
        case .emptyPullSource:
            "Enter a branch to pull from, for example development or origin/development."
        case .noRemoteConfigured:
            "This repository has no remote configured."
        case .detachedHeadRemoteOperation:
            "Pull and push are unavailable while the repository is in detached HEAD state."
        case .commandFailed(let result):
            Self.message(for: result)
        }
    }

    private static func message(for result: GitCommandResult) -> String {
        let error = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = [error, output].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return text.isEmpty ? "Git exited with code \(result.exitCode)." : text
    }
}

public struct GitCommitOutcome: Equatable, Sendable {
    public let shortHash: String
    public let subject: String
    public let output: String
}

public final class GitService: Sendable {
    public static let historyPageSize = 100

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
            // /usr/bin/git is only a shim when the Command Line Tools are missing;
            // it then prompts to install them instead of running Git.
            if path == "/usr/bin/git", !Self.commandLineToolsInstalled(fileManager: fileManager) {
                continue
            }
            return URL(fileURLWithPath: path)
        }

        let pathEnvironment = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in pathEnvironment.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("git")
            if candidate.path != "/usr/bin/git", fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    private static func commandLineToolsInstalled(fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/git")
            || fileManager.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git")
            || (try? fileManager.contentsOfDirectory(atPath: "/Applications"))?.contains(where: { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }) == true
    }

    public func version() async -> String? {
        guard let result = try? await runGit(["--version"], workingDirectory: nil), result.success else {
            return nil
        }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Repository

    public func loadRepository(at selectedURL: URL) async throws -> GitRepositorySnapshot {
        let rootPath = try await repositoryRoot(for: selectedURL)
        async let summaryTask = statusSummary(in: rootPath)
        async let remotesTask = remotes(in: rootPath)
        let summary = try await summaryTask
        let remotes = await remotesTask

        return GitRepositorySnapshot(
            selectedPath: selectedURL,
            rootPath: rootPath,
            branch: summary.isDetached ? "Detached HEAD" : (summary.branchHead ?? "Detached HEAD"),
            isDetachedHead: summary.isDetached,
            headOID: summary.headOID,
            upstreamBranch: summary.upstream,
            aheadCount: summary.aheadCount,
            behindCount: summary.behindCount,
            remotes: remotes,
            files: summary.files
        )
    }

    public func repositoryRoot(for url: URL) async throws -> URL {
        let result = try await runGit(["-C", url.path, "rev-parse", "--show-toplevel"], workingDirectory: nil)
        guard result.success else {
            throw GitServiceError.notARepository(url.path)
        }

        let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path, isDirectory: true)
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

    public func statusSummary(in repositoryURL: URL) async throws -> GitStatusSummary {
        let result = try await runGit(
            ["status", "--porcelain=v2", "--branch", "--untracked-files=all", "-z"],
            workingDirectory: repositoryURL
        )
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }

        return GitStatusParser.parsePorcelainV2(result.standardOutput)
    }

    public func status(in repositoryURL: URL) async throws -> [GitFileStatus] {
        try await statusSummary(in: repositoryURL).files
    }

    public func remotes(in repositoryURL: URL) async -> [String] {
        guard let result = try? await runGit(["remote"], workingDirectory: repositoryURL), result.success else {
            return []
        }

        return result.standardOutput.split(whereSeparator: \.isNewline).map(String.init)
    }

    // MARK: - Branches

    /// Local branches followed by remote-tracking branches already known locally.
    public func branches(in repositoryURL: URL) async throws -> [GitBranch] {
        let result = try await runGit(
            ["for-each-ref", "--sort=-committerdate", GitLogParser.branchFormat, "refs/heads", "refs/remotes"],
            workingDirectory: repositoryURL
        )
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }

        return GitLogParser.parseBranches(result.standardOutput)
    }

    /// Asks the remote server for branch names, including ones not fetched yet.
    public func searchRemoteBranches(matching query: String, remote: String = "origin", in repositoryURL: URL) async throws -> [GitBranch] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return []
        }

        let result = try await runGit(["ls-remote", "--heads", remote, "*\(trimmedQuery)*"], workingDirectory: repositoryURL)
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
                return GitBranch(name: "\(remote)/\(branchName)", isCurrent: false, isRemote: true, isUnfetched: true)
            }
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

    /// Fetches a single remote branch so it can be checked out.
    public func fetchRemoteBranch(_ branch: GitBranch, in repositoryURL: URL) async throws -> String {
        guard branch.isRemote, let remote = branch.remoteName else {
            return ""
        }

        let remoteBranchName = branch.localTrackingName
        let result = try await runGit(
            ["fetch", remote, "\(remoteBranchName):refs/remotes/\(remote)/\(remoteBranchName)"],
            workingDirectory: repositoryURL
        )
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }

        return commandOutput(from: result)
    }

    // MARK: - Diffs

    public func diff(for change: GitChange, in repositoryURL: URL) async throws -> String {
        try await diff(for: change.file, mode: change.diffMode, in: repositoryURL)
    }

    public func diff(for file: GitFileStatus, mode: GitDiffMode, in repositoryURL: URL) async throws -> String {
        if file.isUntracked {
            return try await untrackedFileDiff(for: file, in: repositoryURL)
        }

        var arguments = ["diff", "--no-color", "--no-ext-diff", "-M"]
        if mode == .staged {
            arguments.append("--cached")
        }
        arguments += ["--"] + file.allPaths

        let result = try await runGit(arguments, workingDirectory: repositoryURL)
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }

        return result.standardOutput
    }

    private func untrackedFileDiff(for file: GitFileStatus, in repositoryURL: URL) async throws -> String {
        let result = try await runGit(["diff", "--no-color", "--no-index", "--", "/dev/null", file.path], workingDirectory: repositoryURL)
        // `diff --no-index` exits with 1 when the files differ, which is always the case here.
        guard result.success || result.exitCode == 1 else {
            throw GitServiceError.commandFailed(result)
        }

        return result.standardOutput
    }

    // MARK: - Staging

    public func stage(_ files: [GitFileStatus], in repositoryURL: URL) async throws {
        guard !files.isEmpty else {
            throw GitServiceError.noFilesSelected
        }

        // `-A` also records deletions of the given paths.
        try await runChecked(["add", "-A", "--"] + files.flatMap(\.allPaths), in: repositoryURL)
    }

    public func unstage(_ files: [GitFileStatus], in repositoryURL: URL) async throws {
        guard !files.isEmpty else {
            throw GitServiceError.noFilesSelected
        }

        // `git reset -- <paths>` also works before the first commit, unlike `git restore --staged`.
        try await runChecked(["reset", "-q", "--"] + files.flatMap(\.allPaths), in: repositoryURL)
    }

    public func stageAll(in repositoryURL: URL) async throws {
        try await runChecked(["add", "-A"], in: repositoryURL)
    }

    public func unstageAll(in repositoryURL: URL) async throws {
        try await runChecked(["reset", "-q"], in: repositoryURL)
    }

    /// Discards working-tree changes for the file. Staged changes are kept.
    public func discardChanges(_ change: GitChange, in repositoryURL: URL) async throws -> String {
        switch change.area {
        case .untracked:
            try await runChecked(["clean", "-f", "--", change.path], in: repositoryURL)
        case .unstaged:
            try await runChecked(["restore", "--worktree", "--", change.path], in: repositoryURL)
        case .staged, .conflicted:
            try await runChecked(["restore", "--staged", "--worktree", "--source=HEAD", "--"] + change.file.allPaths, in: repositoryURL)
        }

        return "Discarded changes in \(change.path)."
    }

    // MARK: - Commit

    /// Commits what is currently staged, like `git commit -m`.
    public func commit(message: String, in repositoryURL: URL) async throws -> GitCommitOutcome {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            throw GitServiceError.emptyCommitMessage
        }

        let staged = try await status(in: repositoryURL).filter(\.hasStagedChanges)
        guard !staged.isEmpty else {
            throw GitServiceError.nothingStaged
        }

        let commitResult = try await runGit(["commit", "-m", trimmedMessage], workingDirectory: repositoryURL)
        guard commitResult.success else {
            throw GitServiceError.commandFailed(commitResult)
        }

        let infoResult = try await runGit(["log", "-1", "--format=%h%x1f%s"], workingDirectory: repositoryURL)
        let info = infoResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\u{1f}", maxSplits: 1).map(String.init)

        return GitCommitOutcome(
            shortHash: info.first ?? "",
            subject: info.count > 1 ? info[1] : trimmedMessage,
            output: commandOutput(from: commitResult)
        )
    }

    // MARK: - History

    /// Commits reachable from HEAD, newest first. `paths` limits the log to
    /// commits touching those repository-relative paths.
    public func history(limit: Int = GitService.historyPageSize, skip: Int = 0, paths: [String] = [], in repositoryURL: URL) async throws -> [GitCommit] {
        let result = try await runGit(
            ["log", "--max-count=\(limit)", "--skip=\(skip)", "--date=iso-strict", GitLogParser.logFormat, "HEAD", "--"] + paths,
            workingDirectory: repositoryURL
        )

        guard result.success else {
            // A repository without commits has no history; that is not an error.
            let hasHead = try await runGit(["rev-parse", "--verify", "--quiet", "HEAD"], workingDirectory: repositoryURL).success
            if !hasHead {
                return []
            }
            throw GitServiceError.commandFailed(result)
        }

        return GitLogParser.parseLog(result.standardOutput)
    }

    public func commitDetail(hash: String, in repositoryURL: URL) async throws -> GitCommitDetail {
        async let headerTask = runGit(["show", "-s", GitLogParser.detailFormat, hash], workingDirectory: repositoryURL)
        async let filesTask = runGit(
            ["show", "--format=", "--name-status", "-z", "-M", "--diff-merges=first-parent", hash],
            workingDirectory: repositoryURL
        )

        let header = try await headerTask
        guard header.success else {
            throw GitServiceError.commandFailed(header)
        }

        let files = try await filesTask
        guard files.success else {
            throw GitServiceError.commandFailed(files)
        }

        guard let detail = GitLogParser.parseCommitDetail(header: header.standardOutput, nameStatus: files.standardOutput) else {
            throw GitServiceError.commandFailed(header)
        }

        return detail
    }

    public func diff(for file: GitCommitFile, inCommit hash: String, in repositoryURL: URL) async throws -> String {
        let result = try await runGit(
            ["show", "--format=", "--no-color", "--no-ext-diff", "-M", "--diff-merges=first-parent", hash, "--"] + file.allPaths,
            workingDirectory: repositoryURL
        )
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }

        return result.standardOutput
    }

    // MARK: - Remote operations

    public func fetch(in repositoryURL: URL) async throws -> String {
        let result = try await runGit(["fetch", "--prune"], workingDirectory: repositoryURL)
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }

        return commandOutput(from: result, fallback: "Fetch complete. Already up to date.")
    }

    public func pullPreview(sourceBranch: String?, localFiles: [GitFileStatus], remote: String?, in repositoryURL: URL) async throws -> GitPullPreview {
        let branch = try await currentBranch(in: repositoryURL)
        guard branch != "Detached HEAD" else {
            throw GitServiceError.detachedHeadRemoteOperation
        }

        let target = try await pullTarget(for: sourceBranch, remote: remote, in: repositoryURL)

        if let sourceBranch = target.sourceBranch, let remote = target.remote {
            _ = try await runChecked(["fetch", remote, sourceBranch], in: repositoryURL)
        } else {
            _ = try await runChecked(["fetch"], in: repositoryURL)
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

    public func incomingChangedFiles(from comparisonRef: String, in repositoryURL: URL) async throws -> [String] {
        let result = try await runGit(["diff", "--name-only", "-z", "HEAD...\(comparisonRef)"], workingDirectory: repositoryURL)
        guard result.success else {
            return []
        }

        return result.standardOutput
            .split(separator: "\0")
            .map(String.init)
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

    public func pull(sourceBranch: String?, strategy: GitPullStrategy, remote: String?, in repositoryURL: URL) async throws -> String {
        let target = try await pullTarget(for: sourceBranch, remote: remote, in: repositoryURL)
        var arguments = ["pull"] + strategy.gitArguments
        if let sourceBranch = target.sourceBranch, let remote = target.remote {
            arguments += [remote, sourceBranch]
        }

        let result = try await runGit(arguments, workingDirectory: repositoryURL)
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

    public func pushSetUpstream(branch: String, remote: String?, in repositoryURL: URL) async throws -> String {
        guard branch != "Detached HEAD" else {
            throw GitServiceError.detachedHeadRemoteOperation
        }

        guard let remote else {
            throw GitServiceError.noRemoteConfigured
        }

        let result = try await runGit(["push", "--set-upstream", remote, branch], workingDirectory: repositoryURL)
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }

        return commandOutput(from: result)
    }

    private func pullTarget(for sourceBranch: String?, remote: String?, in repositoryURL: URL) async throws -> PullTarget {
        let trimmedSource = sourceBranch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let upstream = try await currentUpstreamBranch(in: repositoryURL)

        if trimmedSource.isEmpty || trimmedSource == upstream {
            guard let upstream else {
                throw GitServiceError.emptyPullSource
            }

            // Name the upstream branch explicitly. A bare `git fetch`/`git pull` fetches every
            // configured refspec, so one refspec for a branch deleted on the server
            // ("couldn't find remote ref") would make the whole pull fail.
            if let tracking = await upstreamRemoteAndBranch(in: repositoryURL) {
                return PullTarget(displayName: upstream, remote: tracking.remote, sourceBranch: tracking.branch, comparisonRef: "FETCH_HEAD")
            }
            return PullTarget(displayName: upstream, remote: nil, sourceBranch: nil, comparisonRef: "@{u}")
        }

        guard let remote else {
            throw GitServiceError.noRemoteConfigured
        }

        let remoteBranch = trimmedSource.removingPrefix("\(remote)/")
        guard !remoteBranch.isEmpty else {
            throw GitServiceError.emptyPullSource
        }

        return PullTarget(
            displayName: "\(remote)/\(remoteBranch)",
            remote: remote,
            sourceBranch: remoteBranch,
            // FETCH_HEAD is what was just fetched, even when no refspec maps this
            // branch to a remote-tracking ref.
            comparisonRef: "FETCH_HEAD"
        )
    }

    /// Remote name and remote branch the current branch tracks, e.g. ("origin", "development").
    func upstreamRemoteAndBranch(in repositoryURL: URL) async -> (remote: String, branch: String)? {
        guard let branch = try? await currentBranch(in: repositoryURL), branch != "Detached HEAD",
              let result = try? await runGit(
                ["for-each-ref", "--format=%(upstream:remotename)%00%(upstream:remoteref)", "refs/heads/\(branch)"],
                workingDirectory: repositoryURL
              ), result.success else {
            return nil
        }
        let fields = result.standardOutput.trimmingCharacters(in: .newlines).split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 2, !fields[0].isEmpty, fields[1].hasPrefix("refs/heads/") else {
            return nil
        }
        return (fields[0], String(fields[1].dropFirst("refs/heads/".count)))
    }

    // MARK: - Process helpers

    @discardableResult
    func runChecked(_ arguments: [String], in repositoryURL: URL) async throws -> GitCommandResult {
        let result = try await runGit(arguments, workingDirectory: repositoryURL)
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }
        return result
    }

    func runGit(_ arguments: [String], workingDirectory: URL?) async throws -> GitCommandResult {
        try await executor.run(
            executableURL: gitExecutableURL,
            // Ignore working-tree executable-bit noise consistently for status,
            // diffs and staging without changing the repository's configuration.
            // quotePath=false keeps non-ASCII file names readable.
            arguments: ["-c", "core.filemode=false", "-c", "core.quotePath=false", "-c", "color.ui=false"] + arguments,
            workingDirectory: workingDirectory
        )
    }

    func commandOutput(from result: GitCommandResult, fallback: String = "Command completed successfully.") -> String {
        let combinedOutput = [result.standardOutput, result.standardError]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        return combinedOutput.isEmpty ? fallback : combinedOutput
    }
}

private struct PullTarget: Sendable {
    let displayName: String
    let remote: String?
    let sourceBranch: String?
    let comparisonRef: String
}

private extension String {
    func removingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
