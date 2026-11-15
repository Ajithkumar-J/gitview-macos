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

    // MARK: - Revert parts of a file

    /// What a partial revert changed, so it can be undone.
    struct PartialRevert: Sendable, Equatable {
        /// The reverted hunks, as a patch from the last commit to the file before the revert.
        public let patch: String
        /// Whether the staged copy held the same changes and was reverted too.
        public let includedIndex: Bool
        public let count: Int
    }

    /// The file's changes since the last commit, split into hunks. Nil for
    /// binary files or output GitView can't split.
    func changes(in file: GitFileStatus, in repositoryURL: URL) async throws -> GitFilePatch? {
        // Fixed prefixes and no textconv/external diff, whatever the user's
        // settings, so `git apply` accepts the patch exactly as shown.
        let result = try await runChecked(
            ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-relative",
             "--src-prefix=a/", "--dst-prefix=b/", "HEAD", "--", file.path],
            in: repositoryURL
        )
        return GitFilePatch.parse(result.standardOutput)
    }

    /// Puts the chosen hunks back to the last commit. The working tree must
    /// still match what was shown; otherwise Git refuses and nothing changes.
    /// The staged copy is reverted too when it holds the same changes.
    func revertChanges(_ ids: Set<Int>, of patch: GitFilePatch, in repositoryURL: URL) async throws -> PartialRevert {
        let text = patch.patch(including: ids)
        guard !text.isEmpty else {
            throw GitServiceError.noChangesSelected
        }
        let index = try await applyPatch(text, reverse: true, toIndex: true, checkOnly: true, in: repositoryURL).success
        try await applyChecked(text, reverse: true, toIndex: false, in: repositoryURL)
        if index {
            try await applyChecked(text, reverse: true, toIndex: true, in: repositoryURL)
        }
        return PartialRevert(patch: text, includedIndex: index, count: patch.hunks.filter { ids.contains($0.id) }.count)
    }

    /// Brings back changes removed by `revertChanges`.
    func undoRevert(_ revert: PartialRevert, in repositoryURL: URL) async throws {
        try await applyChecked(revert.patch, reverse: false, toIndex: false, in: repositoryURL)
        if revert.includedIndex,
           try await applyPatch(revert.patch, reverse: false, toIndex: true, checkOnly: true, in: repositoryURL).success {
            try await applyChecked(revert.patch, reverse: false, toIndex: true, in: repositoryURL)
        }
    }

    private func applyChecked(_ patch: String, reverse: Bool, toIndex: Bool, in repositoryURL: URL) async throws {
        let result = try await applyPatch(patch, reverse: reverse, toIndex: toIndex, checkOnly: false, in: repositoryURL)
        guard result.success else {
            throw GitServiceError.commandFailed(result)
        }
    }

    /// Runs `git apply` on a private temporary file holding `patch`.
    private func applyPatch(_ patch: String, reverse: Bool, toIndex: Bool, checkOnly: Bool, in repositoryURL: URL) async throws -> GitCommandResult {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("GitView-\(UUID().uuidString).patch")
        try Data(patch.utf8).write(to: file, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: file) }

        var arguments = ["apply", "--whitespace=nowarn"]
        if reverse { arguments.append("--reverse") }
        if toIndex { arguments.append("--cached") }
        if checkOnly { arguments.append("--check") }
        return try await runGit(arguments + ["--", file.path], workingDirectory: repositoryURL)
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
        if let remote {
            arguments += ["--end-of-options", try GitArgument.name(remote, kind: "remote")]
        } else {
            arguments.append("--all")
        }
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
        let remote = try GitArgument.name(remote, kind: "remote")
        let localBranch = try GitArgument.name(localBranch, kind: "branch")
        let remoteBranch = try GitArgument.name(remoteBranch, kind: "branch")
        arguments += ["--end-of-options", remote, "refs/heads/\(localBranch):refs/heads/\(remoteBranch)"]
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
        let name = try GitArgument.name(name, kind: "branch")
        let start = try startPoint.map { ["--end-of-options", try GitArgument.name($0, kind: "branch")] } ?? []
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

    /// Clones `url`; `progress` receives Git's progress as it downloads.
    func clone(url: String, into directory: URL, branch: String?, recurseSubmodules: Bool, progress: (@Sendable (GitProgress) -> Void)? = nil) async throws -> String {
        if let problem = GitArgument.cloneURLProblem(url) ?? GitArgument.folderNameProblem(directory.lastPathComponent) {
            throw GitServiceError.invalidName(kind: "repository URL", value: problem)
        }
        var arguments = ["clone", "--progress"]
        if let branch, !branch.isEmpty { arguments += ["--branch", try GitArgument.name(branch, kind: "branch")] }
        if recurseSubmodules { arguments.append("--recurse-submodules") }
        arguments += ["--", url, directory.path]
        let tracker = GitProgress.Tracker(onUpdate: progress)
        let result = try await runGit(arguments, workingDirectory: directory.deletingLastPathComponent(), onError: progress == nil ? nil : tracker.consume)
        guard result.success else {
            throw GitServiceError.commandFailed(GitCommandResult(
                exitCode: result.exitCode, standardOutput: result.standardOutput,
                standardError: GitProgress.removingProgressLines(result.standardError), command: result.command
            ))
        }
        let output = GitCommandResult(
            exitCode: result.exitCode, standardOutput: result.standardOutput,
            standardError: GitProgress.removingProgressLines(result.standardError), command: result.command
        )
        return commandOutput(from: output, fallback: "Cloned into \(directory.path).")
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
/// must appear somewhere in the name, ignoring case and order. Spaces, `_`, `-`,
/// `/` and `.` all separate words, so "release 13", "release_13" and "17_2"
/// match "Fetch-from-release-tag13", "release/13" and "webapp_v17.2".
public enum BranchSearch {
    public static let resultLimit = 300
    private static let separators = CharacterSet(charactersIn: "_-/.").union(.whitespacesAndNewlines)

    public static func matches(_ name: String, query: String) -> Bool {
        let words = query.components(separatedBy: separators).filter { !$0.isEmpty }
        guard !words.isEmpty else {
            // Only separators typed, such as "_": match them literally.
            let literal = query.trimmingCharacters(in: .whitespaces)
            return literal.isEmpty || name.contains(literal)
        }
        return words.allSatisfy { name.localizedCaseInsensitiveContains($0) }
    }

    /// Names containing the query exactly as typed come first, then by name.
    public static func ranked(_ names: [String], for query: String) -> [String] {
        let typed = query.trimmingCharacters(in: .whitespaces)
        return names.sorted { first, second in
            let firstExact = first.localizedCaseInsensitiveContains(typed)
            let secondExact = second.localizedCaseInsensitiveContains(typed)
            if firstExact != secondExact { return firstExact }
            return first.localizedStandardCompare(second) == .orderedAscending
        }
    }

    /// Server branch names that match, as `remote/name` branches marked unfetched.
    public static func unfetchedBranches(_ names: [String], matching query: String, remote: String, limit: Int = resultLimit) -> [GitBranch] {
        ranked(names.filter { matches($0, query: query) }, for: query)
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

// MARK: - Progress

/// One progress line from Git's `--progress` output, such as
/// "Receiving objects:  45% (450/1000), 1.20 MiB | 2.00 MiB/s".
public struct GitProgress: Equatable, Sendable {
    public let stage: String
    /// Percent of this stage, when Git knows the total.
    public let percent: Int?
    /// Counts and speed, e.g. "450/1000 · 1.20 MiB | 2.00 MiB/s".
    public let detail: String?

    /// Share of a clone or fetch each stage covers, so one bar can run 0–100%.
    private static let stages: [(name: String, start: Double, end: Double)] = [
        ("enumerating objects", 0.00, 0.01), ("counting objects", 0.01, 0.03), ("compressing objects", 0.03, 0.05),
        ("receiving objects", 0.05, 0.80), ("resolving deltas", 0.80, 0.95),
        ("updating files", 0.95, 1.00), ("checking out files", 0.95, 1.00),
    ]

    /// Progress of the whole download (0…1), when the stage is known.
    public var overallFraction: Double? {
        guard let stage = Self.stages.first(where: { $0.name == self.stage.lowercased() }) else { return nil }
        let fraction = Double(percent ?? 0) / 100
        return stage.start + (stage.end - stage.start) * fraction
    }

    public static func parse(_ line: String) -> GitProgress? {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("remote:") {
            text = String(text.dropFirst("remote:".count)).trimmingCharacters(in: .whitespaces)
        }
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let stage = String(text[..<colon])
        guard !stage.isEmpty, stage.count <= 40, stage.allSatisfy({ $0.isLetter || $0 == " " }) else { return nil }
        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)

        var percent: Int?
        var detail: String?
        if let percentSign = rest.firstIndex(of: "%"), let value = Int(rest[..<percentSign].trimmingCharacters(in: .whitespaces)) {
            percent = min(max(value, 0), 100)
            var remainder = rest[rest.index(after: percentSign)...].trimmingCharacters(in: .whitespaces)
            if remainder.hasSuffix(", done.") { remainder.removeLast(", done.".count) }
            remainder = remainder.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
            remainder = remainder.replacingOccurrences(of: ", ", with: " · ").trimmingCharacters(in: .whitespaces)
            detail = remainder.isEmpty ? nil : remainder
        } else if let count = Int(rest.split(separator: ",").first?.trimmingCharacters(in: .whitespaces) ?? "") {
            detail = "\(count)"
        } else {
            return nil
        }
        return GitProgress(stage: stage, percent: percent, detail: detail)
    }

    /// Git rewrites progress lines in place with "\r"; keep only finished lines.
    public static func removingProgressLines(_ text: String) -> String {
        text.components(separatedBy: "\n").compactMap { line -> String? in
            let last = line.components(separatedBy: "\r").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            return parse(last) != nil && !last.contains(", done.") ? nil : last
        }
        .joined(separator: "\n")
    }

    /// Splits streamed output on "\r" and "\n" and reports each new progress line.
    final class Tracker: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = ""
        private let onUpdate: (@Sendable (GitProgress) -> Void)?

        init(onUpdate: (@Sendable (GitProgress) -> Void)?) {
            self.onUpdate = onUpdate
        }

        lazy var consume: @Sendable (String) -> Void = { [weak self] text in self?.feed(text) }

        private func feed(_ text: String) {
            lock.lock()
            pending += text
            var lines = pending.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            pending = lines.removeLast()
            lock.unlock()
            for line in lines {
                if let progress = GitProgress.parse(line) {
                    onUpdate?(progress)
                }
            }
        }
    }
}

// MARK: - Repository addresses

public enum RemoteURL {
    /// A comparable form: host and path, lowercased, without user info, scheme,
    /// ".git" or trailing slash, so `git@host:a/b.git` matches `https://host/a/b`.
    public static func normalized(_ url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespaces).lowercased()
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
        } else if let colon = text.firstIndex(of: ":"), !text[..<colon].contains("/") {
            // scp-like: user@host:path
            text = text.replacingCharacters(in: colon...colon, with: "/")
        }
        if let at = text.firstIndex(of: "@"), !text[..<at].contains("/") {
            text = String(text[text.index(after: at)...])
        }
        if let slash = text.firstIndex(of: "/"), let port = text[..<slash].firstIndex(of: ":") {
            text.removeSubrange(port..<slash)
        }
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }
        return text
    }
}
