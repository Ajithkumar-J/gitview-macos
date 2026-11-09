import Foundation

/// One entry of `git stash list`.
public struct GitStash: Identifiable, Hashable, Sendable {
    public let index: Int
    public let message: String
    public let date: Date?

    public var id: Int { index }
    public var ref: String { "stash@{\(index)}" }

    public init(index: Int, message: String, date: Date?) {
        self.index = index
        self.message = message
        self.date = date
    }
}

/// Operations behind the TortoiseGit-style command windows opened from Finder.
public extension GitService {
    /// Git's well-known empty tree, used as the diff base before the first commit.
    static let emptyTreeHash = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    func hasCommits(in repositoryURL: URL) async -> Bool {
        (try? await runGit(["rev-parse", "--verify", "--quiet", "HEAD"], workingDirectory: repositoryURL).success) ?? false
    }

    // MARK: - Commit selected files

    /// Commits exactly the given files as they are in the working tree, like
    /// TortoiseGit's commit dialog: untracked files are added first, and other
    /// staged changes are left staged but not committed (`git commit --only`).
    /// With `amend` and no files, only the message of the last commit changes.
    func commit(message: String, files: [GitFileStatus], amend: Bool = false, in repositoryURL: URL) async throws -> GitCommitOutcome {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            throw GitServiceError.emptyCommitMessage
        }
        guard amend || !files.isEmpty else {
            throw GitServiceError.noFilesSelected
        }
        guard await identity(in: repositoryURL).isComplete else {
            throw GitServiceError.identityNotConfigured
        }

        let untracked = files.filter(\.isUntracked).map(\.path)
        if !untracked.isEmpty {
            try await runChecked(["add", "--"] + untracked, in: repositoryURL)
        }

        var arguments = ["commit", "-m", trimmedMessage]
        if amend {
            arguments.append("--amend")
        }
        if files.isEmpty {
            arguments.append("--only")
        } else {
            arguments += ["--only", "--"] + Self.uniquePaths(files.flatMap(\.allPaths))
        }

        let commitResult = try await runGit(arguments, workingDirectory: repositoryURL)
        guard commitResult.success else {
            // Do not leave files staged by this attempt behind.
            if !untracked.isEmpty {
                _ = try? await runGit(["reset", "-q", "--"] + untracked, workingDirectory: repositoryURL)
            }
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

    /// Full message of the last commit, for "Amend last commit".
    func lastCommitMessage(in repositoryURL: URL) async throws -> String {
        try await runChecked(["log", "-1", "--format=%B"], in: repositoryURL).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Add / Revert

    func add(paths: [String], in repositoryURL: URL) async throws -> String {
        guard !paths.isEmpty else {
            throw GitServiceError.noFilesSelected
        }
        let result = try await runChecked(["add", "-A", "--"] + paths, in: repositoryURL)
        let count = paths.count == 1 ? "1 file" : "\(paths.count) files"
        return commandOutput(from: result, fallback: "Added \(count).")
    }

    /// Throws away all local changes (staged and unstaged) to the given tracked
    /// files. Newly added files are only removed from the index; the file stays on disk.
    func revert(_ files: [GitFileStatus], in repositoryURL: URL) async throws -> String {
        let files = files.filter { !$0.isUntracked }
        guard !files.isEmpty else {
            throw GitServiceError.noFilesSelected
        }

        let hasHead = await hasCommits(in: repositoryURL)
        let added = files.filter { !hasHead || $0.indexStatus == "A" }
        let restored = files.filter { hasHead && $0.indexStatus != "A" }

        if !added.isEmpty {
            try await runChecked(["rm", "--cached", "-q", "-r", "--"] + added.map(\.path), in: repositoryURL)
        }
        if !restored.isEmpty {
            try await runChecked(
                ["restore", "--source=HEAD", "--staged", "--worktree", "--"] + Self.uniquePaths(restored.flatMap(\.allPaths)),
                in: repositoryURL
            )
        }

        let count = files.count == 1 ? "1 file" : "\(files.count) files"
        return "Reverted \(count)."
    }

    // MARK: - Diff

    /// Working tree compared with the last commit (staged and unstaged together).
    func diffAgainstHead(_ file: GitFileStatus, in repositoryURL: URL) async throws -> String {
        if file.isUntracked {
            return try await diff(for: file, mode: .unstaged, in: repositoryURL)
        }

        let base = await hasCommits(in: repositoryURL) ? "HEAD" : Self.emptyTreeHash
        let result = try await runGit(["diff", "--no-color", "--no-ext-diff", "-M", base, "--"] + file.allPaths, workingDirectory: repositoryURL)
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }
        return result.standardOutput
    }

    // MARK: - Log ranges

    /// Commits in `range` (for example `origin/main..HEAD`), newest first.
    func commits(inRange range: String, limit: Int = 200, in repositoryURL: URL) async throws -> [GitCommit] {
        let result = try await runGit(
            ["log", "--max-count=\(limit)", "--date=iso-strict", GitLogParser.logFormat, range, "--"],
            workingDirectory: repositoryURL
        )
        guard result.success else {
            return []
        }
        return GitLogParser.parseLog(result.standardOutput)
    }

    func refExists(_ ref: String, in repositoryURL: URL) async -> Bool {
        (try? await runGit(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], workingDirectory: repositoryURL).success) ?? false
    }

    // MARK: - Remotes

    /// `git fetch` from one remote, or from all remotes when `remote` is nil.
    func fetch(remote: String?, prune: Bool, tags: Bool, in repositoryURL: URL) async throws -> String {
        var arguments = ["fetch"]
        if prune { arguments.append("--prune") }
        if tags { arguments.append("--tags") }
        arguments += remote.map { [$0] } ?? ["--all"]
        let result = try await runChecked(arguments, in: repositoryURL)
        return commandOutput(from: result, fallback: "Fetch complete. Already up to date.")
    }

    func push(
        localBranch: String,
        remote: String,
        remoteBranch: String,
        setUpstream: Bool,
        forceWithLease: Bool,
        includeTags: Bool,
        in repositoryURL: URL
    ) async throws -> String {
        var arguments = ["push"]
        if setUpstream { arguments.append("--set-upstream") }
        if forceWithLease { arguments.append("--force-with-lease") }
        if includeTags { arguments.append("--follow-tags") }
        arguments += [remote, "refs/heads/\(localBranch):refs/heads/\(remoteBranch)"]
        let result = try await runChecked(arguments, in: repositoryURL)
        return commandOutput(from: result, fallback: "Everything up-to-date.")
    }

    // MARK: - Branches

    /// Returns Git's error text when `name` is not a valid branch name.
    func branchNameProblem(_ name: String, in repositoryURL: URL) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return "Enter a branch name."
        }
        let valid = (try? await runGit(["check-ref-format", "--branch", trimmed], workingDirectory: repositoryURL).success) ?? false
        if !valid {
            return "“\(trimmed)” is not a valid branch name."
        }
        if await refExists("refs/heads/\(trimmed)", in: repositoryURL) {
            return "A branch named “\(trimmed)” already exists."
        }
        return nil
    }

    func createBranch(named name: String, from startPoint: String?, switchToBranch: Bool, in repositoryURL: URL) async throws -> String {
        let name = name.trimmingCharacters(in: .whitespaces)
        let start = startPoint.map { [$0] } ?? []
        let arguments = switchToBranch ? ["switch", "-c", name] + start : ["branch", name] + start
        let result = try await runChecked(arguments, in: repositoryURL)
        let fallback = switchToBranch ? "Switched to new branch \(name)." : "Created branch \(name)."
        return commandOutput(from: result, fallback: fallback)
    }

    // MARK: - Stash

    func stashes(in repositoryURL: URL) async throws -> [GitStash] {
        let result = try await runChecked(["stash", "list", "--format=%gd%x1f%cI%x1f%gs"], in: repositoryURL)
        return result.standardOutput.split(separator: "\n").enumerated().compactMap { offset, line in
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { return nil }
            return GitStash(index: offset, message: fields[2], date: GitLogParser.parseDate(fields[1]))
        }
    }

    func stashSave(message: String, includeUntracked: Bool, in repositoryURL: URL) async throws -> String {
        var arguments = ["stash", "push"]
        if includeUntracked { arguments.append("--include-untracked") }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { arguments += ["-m", trimmed] }
        let result = try await runChecked(arguments, in: repositoryURL)
        return commandOutput(from: result, fallback: "Changes stashed.")
    }

    /// Applies a stash; `pop` also drops it when it applied cleanly.
    func stashApply(_ stash: GitStash, pop: Bool, in repositoryURL: URL) async throws -> String {
        let result = try await runChecked(["stash", pop ? "pop" : "apply", stash.ref], in: repositoryURL)
        return commandOutput(from: result, fallback: pop ? "Stash applied and dropped." : "Stash applied.")
    }

    func stashDrop(_ stash: GitStash, in repositoryURL: URL) async throws -> String {
        let result = try await runChecked(["stash", "drop", stash.ref], in: repositoryURL)
        return commandOutput(from: result, fallback: "Stash dropped.")
    }

    // MARK: - Clone / Init

    func clone(url: String, into directory: URL, branch: String?, recurseSubmodules: Bool) async throws -> String {
        var arguments = ["clone"]
        if let branch, !branch.isEmpty { arguments += ["--branch", branch] }
        if recurseSubmodules { arguments.append("--recurse-submodules") }
        arguments += ["--", url, directory.path]
        let result = try await runGit(arguments, workingDirectory: directory.deletingLastPathComponent())
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }
        return commandOutput(from: result, fallback: "Cloned into \(directory.path).")
    }

    func initRepository(at directory: URL) async throws -> String {
        let result = try await runGit(["init"], workingDirectory: directory)
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }
        return commandOutput(from: result)
    }

    // MARK: - Helpers

    private static func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}

// MARK: - Identity

/// The name and email Git records as author and committer.
public struct GitIdentity: Equatable, Sendable {
    public var name: String
    public var email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }

    public var isComplete: Bool {
        let email = email.trimmingCharacters(in: .whitespaces)
        return !name.trimmingCharacters(in: .whitespaces).isEmpty
            && email.contains("@") && !email.contains(" ")
    }
}

public extension GitService {
    /// `user.name` / `user.email` as Git resolves them for the repository
    /// (repository, then global, then system configuration). Without them Git
    /// silently invents an identity such as "you@Mac.local".
    func identity(in repositoryURL: URL?) async -> GitIdentity {
        func value(_ key: String) async -> String {
            let result = try? await runGit(["config", "--get", key], workingDirectory: repositoryURL)
            return result?.success == true ? result!.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        }
        return GitIdentity(name: await value("user.name"), email: await value("user.email"))
    }

    /// Saves the identity for every repository (`--global`), or only for `repositoryURL`.
    func saveIdentity(_ identity: GitIdentity, globally: Bool = true, in repositoryURL: URL? = nil) async throws {
        let scope = globally ? ["--global"] : []
        let name = identity.name.trimmingCharacters(in: .whitespaces)
        let email = identity.email.trimmingCharacters(in: .whitespaces)
        for (key, value) in [("user.name", name), ("user.email", email)] {
            let result = try await runGit(["config"] + scope + [key, value], workingDirectory: repositoryURL)
            guard result.success else {
                throw GitServiceError.commandFailed(result)
            }
        }
    }
}

// MARK: - Branch search

/// How GitView matches typed text against branch names everywhere: every word
/// must appear somewhere in the name, ignoring case and order. "release 13"
/// matches "Fetch-from-release-tag13" and "Release_13_hotfix".
public enum BranchSearch {
    public static let resultLimit = 300

    public static func matches(_ name: String, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        return words.allSatisfy { name.localizedCaseInsensitiveContains($0) }
    }

    /// Server branch names that match, as `remote/name` branches marked unfetched.
    public static func unfetchedBranches(_ names: [String], matching query: String, remote: String, limit: Int = resultLimit) -> [GitBranch] {
        names
            .filter { matches($0, query: query) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .prefix(limit)
            .map { GitBranch(name: "\(remote)/\($0)", isCurrent: false, isRemote: true, isUnfetched: true) }
    }
}

/// Branch names on each server, listed once and reused for a few minutes, so
/// search-as-you-type does not contact the server on every keystroke. Shared by
/// the main window and every command window.
public actor RemoteBranchDirectory {
    public static let shared = RemoteBranchDirectory()
    public static let maximumAge: TimeInterval = 180

    private var lists: [String: (date: Date, names: [String])] = [:]
    private var loading: [String: Task<[String], Error>] = [:]

    public init() {}

    /// Branch names on `remote`; `refresh` asks the server even when a recent list exists.
    public func branchNames(remote: String, in repositoryURL: URL, service: GitService, refresh: Bool = false) async throws -> [String] {
        let key = repositoryURL.standardizedFileURL.path + "\u{0}" + remote
        if !refresh, let list = lists[key], Date().timeIntervalSince(list.date) < Self.maximumAge {
            return list.names
        }
        if let task = loading[key] {
            return try await task.value
        }
        let task = Task { try await service.remoteBranchNames(remote: remote, in: repositoryURL) }
        loading[key] = task
        defer { loading[key] = nil }
        let names = try await task.value
        lists[key] = (Date(), names)
        return names
    }

    /// Matching server branches (not yet fetched ones are marked `isUnfetched`).
    public func search(_ query: String, remote: String, in repositoryURL: URL, service: GitService, refresh: Bool = false) async throws -> [GitBranch] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let names = try await branchNames(remote: remote, in: repositoryURL, service: service, refresh: refresh)
        return BranchSearch.unfetchedBranches(names, matching: query, remote: remote)
    }
}

