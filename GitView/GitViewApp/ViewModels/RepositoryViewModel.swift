import AppKit
import Foundation
import Observation
#if canImport(Shared)
import Shared
#endif

/// State and actions for one GitView window. Views call these methods; only
/// `GitService` talks to Git.
@MainActor
@Observable
final class RepositoryViewModel {
    // MARK: Environment

    private(set) var gitService: GitService?
    private(set) var gitVersion: String?
    let recents = RecentRepositories.shared

    // MARK: Repository

    private(set) var snapshot: GitRepositorySnapshot?
    var section: AppSection = .changes
    private(set) var isOpening = false
    private(set) var isRefreshing = false

    // MARK: Activity / feedback

    /// Non-nil while a long-running operation (pull, push, commit, …) runs.
    private(set) var activity: String?
    private(set) var statusMessage: StatusMessage?
    private(set) var outputLog: [OutputEntry] = []
    var isShowingOutputLog = false
    var alert: AlertContent?

    var isBusy: Bool {
        activity != nil
    }

    // MARK: Changes

    var selectedChangeID: GitChange.ID? {
        didSet {
            if oldValue != selectedChangeID {
                loadSelectedChangeDiff()
            }
        }
    }
    private(set) var changeDiff: DiffState = .placeholder("Select a file to see its changes.")
    var commitMessage = ""
    var pendingDiscard: GitChange?

    // MARK: Remote operations

    var pendingRemoteOperation: GitRemoteOperation?
    var pendingPullPreview: GitPullPreview?
    var pullSourceBranch = ""
    var selectedPullStrategy: GitPullStrategy = .merge
    private(set) var isPreparingPull = false

    // MARK: History

    private(set) var commits: [GitCommit] = []
    private(set) var isLoadingHistory = false
    private(set) var canLoadMoreHistory = false
    private var historyHeadOID: String??
    var historyFilter = ""
    /// Repository-relative paths the history is limited to (Show Log on a file or folder).
    var historyPaths: [String] = []
    var selectedCommitID: GitCommit.ID? {
        didSet {
            if oldValue != selectedCommitID {
                loadSelectedCommitDetail()
            }
        }
    }
    private(set) var commitDetail: CommitDetailState = .none
    var selectedCommitFileID: GitCommitFile.ID? {
        didSet {
            if oldValue != selectedCommitFileID {
                loadSelectedCommitFileDiff()
            }
        }
    }
    private(set) var commitFileDiff: DiffState = .placeholder("Select a file to see its changes.")

    // MARK: Branches

    private(set) var branches: [GitBranch] = []
    var branchFilter = "" {
        didSet {
            if branchFilter != oldValue { scheduleRemoteSearch() }
        }
    }
    private var remoteSearchTask: Task<Void, Never>?
    private(set) var remoteSearchResults: [GitBranch] = []
    private(set) var isSearchingRemote = false
    var selectedBranchID: GitBranch.ID?

    // MARK: Private

    @ObservationIgnored private var operationChain: Task<Void, Never>?
    @ObservationIgnored private var isRefreshQueued = false
    @ObservationIgnored private var diffTask: Task<Void, Never>?
    @ObservationIgnored private var commitDetailTask: Task<Void, Never>?
    @ObservationIgnored private var commitFileDiffTask: Task<Void, Never>?

    init() {
        detectGit()
    }

    func detectGit() {
        do {
            let service = try GitService()
            gitService = service
            Task {
                gitVersion = await service.version()
            }
        } catch {
            gitService = nil
        }
    }

    // MARK: - Opening

    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.title = "Open Git Repository"
        panel.message = "Choose a Git working copy or any folder inside one."
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        open(url)
    }

    func open(_ url: URL, then action: GitViewDeepLink.Action = .open) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        // A file (e.g. right-clicked in Finder) opens the repository that contains it.
        let url = exists && !isDirectory.boolValue ? url.deletingLastPathComponent() : url
        Task {
            await openRepository(at: url)
            guard snapshot != nil else { return }
            switch action {
            case .log:
                section = .history
            case .pull:
                requestPull()
            case .push:
                requestPush()
            default:
                section = .changes
            }
        }
    }

    func handle(deepLink url: URL) {
        guard let link = GitViewDeepLink(url: url) else {
            return
        }

        open(URL(fileURLWithPath: link.path, isDirectory: true), then: link.action)
    }

    func closeRepository() {
        snapshot = nil
        resetRepositoryState()
    }

    private func openRepository(at url: URL) async {
        guard let gitService else {
            return
        }

        isOpening = true
        defer { isOpening = false }

        do {
            let loaded = try await gitService.loadRepository(at: url, trust: RepositoryTrustPrompt.confirm)
            let isSameRepository = loaded.rootPath == snapshot?.rootPath
            if !isSameRepository {
                resetRepositoryState()
            }
            snapshot = loaded
            pullSourceBranch = loaded.upstreamBranch ?? ""
            recents.add(loaded.rootPath)
            await loadBranches()
            if !isSameRepository {
                statusMessage = StatusMessage(text: "Opened \(loaded.name)", kind: .info)
            }
        } catch {
            if case GitServiceError.notARepository = error {
                alert = AlertContent(title: "Not a Git Repository", message: error.localizedDescription)
            } else {
                alert = AlertContent(title: "Could Not Open Repository", message: error.localizedDescription)
            }
        }
    }

    private func resetRepositoryState() {
        section = .changes
        selectedChangeID = nil
        changeDiff = .placeholder("Select a file to see its changes.")
        commitMessage = ""
        commits = []
        historyHeadOID = nil
        canLoadMoreHistory = false
        historyFilter = ""
        selectedCommitID = nil
        commitDetail = .none
        branches = []
        branchFilter = ""
        remoteSearchResults = []
        selectedBranchID = nil
        pendingPullPreview = nil
        pullSourceBranch = ""
    }

    // MARK: - Refresh

    func refresh() {
        guard snapshot != nil, !isRefreshQueued else {
            return
        }

        isRefreshQueued = true
        enqueue { [weak self] in
            guard let self else { return }
            self.isRefreshQueued = false
            await self.reload()
        }
    }

    /// Re-reads status, branches and (if HEAD moved) history, keeping selections.
    private func reload() async {
        guard let gitService, let root = snapshot?.rootPath else {
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let loaded = try await gitService.loadRepository(at: root, trust: RepositoryTrustPrompt.confirm)
            let previousHead = snapshot?.headOID
            snapshot = loaded
            if pullSourceBranch.isEmpty {
                pullSourceBranch = loaded.upstreamBranch ?? ""
            }

            let changeIDs = Set(Self.allChanges(in: loaded).map(\.id))
            if let selectedChangeID, !changeIDs.contains(selectedChangeID) {
                self.selectedChangeID = nil
            } else {
                loadSelectedChangeDiff()
            }

            await loadBranches()

            if previousHead != loaded.headOID, historyHeadOID != nil {
                await loadHistory(reset: true)
            }
        } catch {
            if case GitServiceError.notARepository = error {
                alert = AlertContent(title: "Repository Unavailable", message: "\(root.path) is no longer a Git repository.")
                closeRepository()
            } else {
                postError(title: "Refresh Failed", error)
            }
        }
    }

    // MARK: - Operation queue

    /// Runs Git operations one after another so quick clicks never race.
    private func enqueue(_ body: @escaping @MainActor () async -> Void) {
        let previous = operationChain
        operationChain = Task { @MainActor in
            await previous?.value
            await body()
        }
    }

    /// Runs a mutating operation, records its output and refreshes afterwards.
    private func perform(
        _ activityText: String,
        failureTitle: String,
        announce: Bool = true,
        success: String? = nil,
        _ work: @escaping @MainActor (GitService, URL) async throws -> String?
    ) {
        enqueue { [weak self] in
            guard let self, let gitService = self.gitService, let root = self.snapshot?.rootPath else {
                return
            }

            if announce {
                self.activity = activityText
            }

            do {
                if let message = try await work(gitService, root) {
                    self.log(title: activityText.replacingOccurrences(of: "…", with: ""), text: message, isError: false)
                    if announce {
                        self.statusMessage = StatusMessage(text: success ?? Self.firstLine(of: message), kind: .success)
                    }
                }
            } catch {
                self.postError(title: failureTitle, error)
            }

            await self.reload()
            self.activity = nil
        }
    }

    private func postError(title: String, _ error: Error) {
        let output = error.localizedDescription
        let message = [(error as? LocalizedError)?.recoverySuggestion, output]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        log(title: title, text: message, isError: true)
        statusMessage = StatusMessage(text: title, kind: .error)
        alert = AlertContent(title: title, message: message)
    }

    func log(title: String, text: String, isError: Bool) {
        outputLog.append(OutputEntry(title: title, text: Redactor.redact(text), isError: isError))
        if outputLog.count > 200 {
            outputLog.removeFirst(outputLog.count - 200)
        }
    }

    func clearOutputLog() {
        outputLog.removeAll()
    }

    private static func firstLine(of text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    // MARK: - Changes

    static func allChanges(in snapshot: GitRepositorySnapshot) -> [GitChange] {
        GitChangeArea.allCases.flatMap { snapshot.changes(in: $0) }
    }

    var selectedChange: GitChange? {
        guard let snapshot, let selectedChangeID else {
            return nil
        }
        return Self.allChanges(in: snapshot).first { $0.id == selectedChangeID }
    }

    var stagedCount: Int {
        snapshot?.stagedCount ?? 0
    }

    /// False when Git has no user.name / user.email; the commit panel asks for them.
    var hasGitIdentity = true

    var canCommit: Bool {
        hasGitIdentity
            && stagedCount > 0
            && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(snapshot?.hasConflicts ?? false)
            && !isBusy
    }

    var commitDisabledReason: String? {
        guard let snapshot else { return nil }
        if !hasGitIdentity { return "Enter your name and email first." }
        if snapshot.hasConflicts { return "Resolve merge conflicts before committing." }
        if stagedCount == 0 { return snapshot.files.isEmpty ? "No changes to commit." : "Stage files to include them in the commit." }
        if commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a commit message." }
        return nil
    }

    private func loadSelectedChangeDiff() {
        diffTask?.cancel()
        guard let change = selectedChange, let gitService, let root = snapshot?.rootPath else {
            changeDiff = .placeholder(snapshot?.files.isEmpty == true ? "Working tree clean." : "Select a file to see its changes.")
            return
        }

        if case .loaded = changeDiff {
            // Keep showing the old diff while refreshing to avoid flicker.
        } else {
            changeDiff = .loading
        }

        diffTask = Task {
            let state = await Self.loadDiff { try await gitService.diff(for: change, in: root) }
            guard !Task.isCancelled else { return }
            changeDiff = state
        }
    }

    nonisolated private static func loadDiff(_ load: @Sendable () async throws -> String) async -> DiffState {
        do {
            let text = try await load()
            let diff = await Task.detached(priority: .userInitiated) { GitDiffParser.parse(text) }.value
            return diff.isEmpty ? .placeholder("No textual changes.") : .loaded(diff)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func stage(_ change: GitChange) {
        stage([change])
    }

    func stage(_ changes: [GitChange]) {
        let files = changes.map(\.file)
        moveSelectionIfNeeded(from: changes, to: .staged)
        perform("Staging…", failureTitle: "Stage Failed", announce: false) { service, root in
            try await service.stage(files, in: root)
            return nil
        }
    }

    func unstage(_ changes: [GitChange]) {
        let files = changes.map(\.file)
        moveSelectionIfNeeded(from: changes, to: .unstaged)
        perform("Unstaging…", failureTitle: "Unstage Failed", announce: false) { service, root in
            try await service.unstage(files, in: root)
            return nil
        }
    }

    func stageAll() {
        perform("Staging all changes…", failureTitle: "Stage Failed", announce: false) { service, root in
            try await service.stageAll(in: root)
            return nil
        }
    }

    func unstageAll() {
        perform("Unstaging all changes…", failureTitle: "Unstage Failed", announce: false) { service, root in
            try await service.unstageAll(in: root)
            return nil
        }
    }

    func toggleStage(_ change: GitChange) {
        switch change.area {
        case .staged:
            unstage([change])
        case .unstaged, .untracked, .conflicted:
            stage([change])
        }
    }

    /// Keeps the diff on the same file after it moves between lists.
    private func moveSelectionIfNeeded(from changes: [GitChange], to area: GitChangeArea) {
        guard let selected = selectedChange, changes.contains(selected) else {
            return
        }
        let targetArea = selected.file.isUntracked && area == .unstaged ? .untracked : area
        selectedChangeID = GitChange(file: selected.file, area: targetArea).id
    }

    func requestDiscard(_ change: GitChange) {
        pendingDiscard = change
    }

    func confirmDiscard() {
        guard let change = pendingDiscard else { return }
        pendingDiscard = nil
        perform("Discarding changes…", failureTitle: "Discard Failed") { service, root in
            try await service.discardChanges(change, in: root)
        }
    }

    func commit() {
        guard canCommit else {
            if let reason = commitDisabledReason {
                statusMessage = StatusMessage(text: reason, kind: .info)
            }
            return
        }

        let message = commitMessage
        perform("Committing…", failureTitle: "Commit Failed") { [weak self] service, root in
            let outcome = try await service.commit(message: message, in: root)
            self?.commitMessage = ""
            self?.selectedChangeID = nil
            return "Committed \(outcome.shortHash) — \(outcome.subject)"
        }
    }

    // MARK: - Remote operations

    var remoteName: String? {
        snapshot?.defaultRemote
    }

    func fetch() {
        guard snapshot?.remotes.isEmpty == false else {
            alert = AlertContent(title: "No Remote", message: GitServiceError.noRemoteConfigured.localizedDescription)
            return
        }

        perform("Fetching…", failureTitle: "Fetch Failed", success: "Fetched from \(remoteName ?? "remote")") { service, root in
            try await service.fetch(in: root)
        }
    }

    func requestPull() {
        guard let snapshot else { return }
        guard !snapshot.isDetachedHead else {
            alert = AlertContent(title: "Cannot Pull", message: GitServiceError.detachedHeadRemoteOperation.localizedDescription)
            return
        }
        guard !snapshot.remotes.isEmpty else {
            alert = AlertContent(title: "Cannot Pull", message: GitServiceError.noRemoteConfigured.localizedDescription)
            return
        }

        if pullSourceBranch.isEmpty {
            pullSourceBranch = snapshot.upstreamBranch ?? ""
        }
        pendingPullPreview = nil
        pendingRemoteOperation = .pull
        if !pullSourceBranch.isEmpty {
            preparePull()
        }
    }

    /// Fetches the pull source and computes what the pull would bring in.
    func preparePull() {
        guard let gitService, let snapshot else { return }
        let source = pullSourceBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = remoteName
        isPreparingPull = true
        pendingPullPreview = nil

        enqueue { [weak self] in
            guard let self else { return }
            do {
                self.pendingPullPreview = try await gitService.pullPreview(
                    sourceBranch: source.isEmpty ? nil : source,
                    localFiles: snapshot.files,
                    remote: remote,
                    in: snapshot.rootPath
                )
            } catch GitServiceError.emptyPullSource {
                self.pendingPullPreview = nil
            } catch {
                self.pendingRemoteOperation = nil
                self.postError(title: "Pull Preview Failed", error)
            }
            self.isPreparingPull = false
        }
    }

    func requestPush() {
        guard let snapshot else { return }
        guard !snapshot.isDetachedHead else {
            alert = AlertContent(title: "Cannot Push", message: GitServiceError.detachedHeadRemoteOperation.localizedDescription)
            return
        }
        guard !snapshot.remotes.isEmpty else {
            alert = AlertContent(title: "Cannot Push", message: GitServiceError.noRemoteConfigured.localizedDescription)
            return
        }
        guard snapshot.hasCommits else {
            alert = AlertContent(title: "Nothing to Push", message: "Create a commit before pushing.")
            return
        }

        pendingRemoteOperation = snapshot.upstreamBranch == nil ? .pushSetUpstream : .push
    }

    func cancelRemoteOperation() {
        pendingRemoteOperation = nil
        pendingPullPreview = nil
    }

    func confirmRemoteOperation() {
        guard let operation = pendingRemoteOperation, let snapshot else {
            return
        }

        pendingRemoteOperation = nil
        let remote = remoteName
        let branch = snapshot.branch

        switch operation {
        case .pull:
            let source = pendingPullPreview?.sourceBranch
            let target = pendingPullPreview?.target ?? snapshot.upstreamBranch ?? "upstream"
            let strategy = selectedPullStrategy
            perform("Pulling from \(target)…", failureTitle: "Pull Failed", success: "Pulled from \(target)") { service, root in
                try await service.pull(sourceBranch: source, strategy: strategy, remote: remote, in: root)
            }
        case .push:
            perform("Pushing to \(snapshot.upstreamBranch ?? branch)…", failureTitle: "Push Failed", success: "Pushed to \(snapshot.upstreamBranch ?? branch)") { service, root in
                try await service.push(in: root)
            }
        case .pushSetUpstream:
            perform("Pushing to \(remote ?? "remote")/\(branch)…", failureTitle: "Push Failed", success: "Published \(branch) to \(remote ?? "remote")") { service, root in
                try await service.pushSetUpstream(branch: branch, remote: remote, in: root)
            }
        }
        pendingPullPreview = nil
    }

    var remoteConfirmationTitle: String {
        switch pendingRemoteOperation {
        case .pushSetUpstream: "Publish Branch?"
        default: "Push Commits?"
        }
    }

    var remoteConfirmationMessage: String {
        guard let snapshot else { return "" }
        switch pendingRemoteOperation {
        case .pushSetUpstream:
            return "“\(snapshot.branch)” has no upstream branch. GitView will run:\n\ngit push --set-upstream \(remoteName ?? "origin") \(snapshot.branch)"
        case .push:
            let count = snapshot.aheadCount
            let commits = count == 1 ? "1 commit" : "\(count) commits"
            return count > 0
                ? "Push \(commits) to \(snapshot.upstreamBranch ?? snapshot.branch)?"
                : "\(snapshot.upstreamBranch ?? snapshot.branch) already has all local commits. Push anyway?"
        default:
            return ""
        }
    }

    // MARK: - External apps

    func openInTerminal() {
        guard let root = snapshot?.rootPath else { return }
        Task {
            do {
                try await ExternalApps.openTerminal(at: root)
            } catch {
                alert = AlertContent(title: "Could Not Open Terminal", message: error.localizedDescription)
            }
        }
    }

    func openInVSCode(_ relativePath: String? = nil) {
        guard let root = snapshot?.rootPath else { return }
        var urls = [root]
        if let relativePath {
            urls.append(root.appendingPathComponent(relativePath))
        }
        Task {
            do {
                try await ExternalApps.openInVSCode(urls)
            } catch {
                alert = AlertContent(title: "Could Not Open VS Code", message: error.localizedDescription)
            }
        }
    }

    func revealInFinder(_ relativePath: String? = nil) {
        guard let root = snapshot?.rootPath else { return }
        ExternalApps.revealInFinder(relativePath.map { root.appendingPathComponent($0) } ?? root)
    }

    func copyPath(_ relativePath: String) {
        ExternalApps.copyToPasteboard(relativePath)
        statusMessage = StatusMessage(text: "Copied \(relativePath)", kind: .info)
    }
}

// MARK: - History

extension RepositoryViewModel {
    var filteredCommits: [GitCommit] {
        let query = historyFilter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            return commits
        }

        return commits.filter {
            $0.subject.localizedCaseInsensitiveContains(query)
                || $0.authorName.localizedCaseInsensitiveContains(query)
                || $0.hash.hasPrefix(query.lowercased())
        }
    }

    var selectedCommit: GitCommit? {
        commits.first { $0.id == selectedCommitID }
    }

    func loadHistoryIfNeeded() {
        guard historyHeadOID == nil, !isLoadingHistory else {
            return
        }

        Task {
            await loadHistory(reset: true)
        }
    }

    func loadMoreHistory() {
        guard canLoadMoreHistory, !isLoadingHistory else {
            return
        }

        Task {
            await loadHistory(reset: false)
        }
    }

    fileprivate func loadHistory(reset: Bool) async {
        guard let gitService, let snapshot else {
            return
        }

        isLoadingHistory = true
        defer { isLoadingHistory = false }

        do {
            let skip = reset ? 0 : commits.count
            let page = try await gitService.history(skip: skip, paths: historyPaths, in: snapshot.rootPath)
            commits = reset ? page : commits + page
            canLoadMoreHistory = page.count == GitService.historyPageSize
            historyHeadOID = .some(snapshot.headOID)
            if let selectedCommitID, !commits.contains(where: { $0.id == selectedCommitID }) {
                self.selectedCommitID = nil
            }
        } catch {
            postError(title: "Could Not Load History", error)
        }
    }

    fileprivate func loadSelectedCommitDetail() {
        commitDetailTask?.cancel()
        selectedCommitFileID = nil
        commitFileDiff = .placeholder("Select a file to see its changes.")

        guard let hash = selectedCommitID, let gitService, let root = snapshot?.rootPath else {
            commitDetail = .none
            return
        }

        commitDetail = .loading
        commitDetailTask = Task {
            do {
                let detail = try await gitService.commitDetail(hash: hash, in: root)
                guard !Task.isCancelled else { return }
                commitDetail = .loaded(detail)
                selectedCommitFileID = detail.files.first?.id
            } catch {
                guard !Task.isCancelled else { return }
                commitDetail = .failed(error.localizedDescription)
            }
        }
    }

    fileprivate func loadSelectedCommitFileDiff() {
        commitFileDiffTask?.cancel()
        guard
            case .loaded(let detail) = commitDetail,
            let file = detail.files.first(where: { $0.id == selectedCommitFileID }),
            let gitService,
            let root = snapshot?.rootPath
        else {
            commitFileDiff = .placeholder("Select a file to see its changes.")
            return
        }

        let hash = detail.commit.hash
        commitFileDiff = .loading
        commitFileDiffTask = Task {
            let state = await Self.loadDiff { try await gitService.diff(for: file, inCommit: hash, in: root) }
            guard !Task.isCancelled else { return }
            commitFileDiff = state
        }
    }
}

// MARK: - Branches

extension RepositoryViewModel {
    var localBranches: [GitBranch] {
        filteredBranches(branches.filter { !$0.isRemote })
            .sorted { lhs, rhs in
                if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    var remoteBranches: [GitBranch] {
        filteredBranches(branches.filter(\.isRemote))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Branches found on the server that are not fetched locally yet.
    var unfetchedRemoteBranches: [GitBranch] {
        let known = Set(branches.map(\.name))
        return remoteSearchResults.filter { !known.contains($0.name) }
    }

    var selectedBranch: GitBranch? {
        (branches + remoteSearchResults).first { $0.id == selectedBranchID }
    }

    private func filteredBranches(_ list: [GitBranch]) -> [GitBranch] {
        let query = branchFilter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return list }
        return list.filter { BranchSearch.matches($0.name, query: query) }
    }

    fileprivate func loadBranches() async {
        guard let gitService, let root = snapshot?.rootPath else { return }
        do {
            branches = try await gitService.branches(in: root)
        } catch {
            branches = []
            log(title: "Could Not Load Branches", text: error.localizedDescription, isError: true)
        }
    }

    /// Searches the server as you type (after a short pause), using the cached
    /// branch list so only the first search contacts the server.
    private func scheduleRemoteSearch() {
        remoteSearchTask?.cancel()
        let query = branchFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, remoteName != nil else {
            remoteSearchResults = []
            return
        }
        remoteSearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.runRemoteSearch(query, refresh: false, announce: false)
        }
    }

    /// Enter or the globe button: list the server's branches again, then search.
    func searchRemoteBranches() {
        remoteSearchTask?.cancel()
        let query = branchFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        remoteSearchTask = Task { [weak self] in
            await self?.runRemoteSearch(query, refresh: true, announce: true)
        }
    }

    private func runRemoteSearch(_ query: String, refresh: Bool, announce: Bool) async {
        guard let gitService, let root = snapshot?.rootPath, let remote = remoteName, !query.isEmpty else {
            return
        }
        isSearchingRemote = true
        defer { isSearchingRemote = false }
        do {
            let results = try await RemoteBranchDirectory.shared.search(query, remote: remote, in: root, service: gitService, refresh: refresh)
            // Ignore results for text the user has since changed.
            guard query == branchFilter.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            remoteSearchResults = results
            if announce {
                let newCount = unfetchedRemoteBranches.count
                statusMessage = StatusMessage(
                    text: newCount == 0 ? "No other branches on \(remote) match “\(query)”." : "Found \(newCount) unfetched branch\(newCount == 1 ? "" : "es") on \(remote).",
                    kind: .info
                )
            }
        } catch {
            if announce {
                postError(title: "Remote Search Failed", error)
            } else {
                log(title: "Remote Branch Search Failed", text: error.localizedDescription, isError: true)
            }
        }
    }

    func switchBranch(to branch: GitBranch) {
        guard !branch.isCurrent else { return }
        let title = branch.isRemote ? "Checking out \(branch.localTrackingName)…" : "Switching to \(branch.name)…"
        perform(title, failureTitle: "Unable to Switch Branch", success: "Switched to \(branch.localTrackingName)") { [weak self] service, root in
            var fetched = ""
            if branch.isUnfetched {
                fetched = try await service.fetchRemoteBranch(branch, in: root)
            }
            let output = try await service.switchBranch(to: branch, in: root)
            self?.selectedChangeID = nil
            self?.remoteSearchResults = []
            return [fetched, output].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
    }
}
