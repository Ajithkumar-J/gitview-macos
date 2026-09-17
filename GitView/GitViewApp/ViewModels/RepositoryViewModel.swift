import AppKit
import Foundation
#if canImport(Shared)
import Shared
#endif

@MainActor
final class RepositoryViewModel: ObservableObject {
    @Published private(set) var snapshot: GitRepositorySnapshot?
    @Published private(set) var gitExecutablePath = "Detecting Git..."
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingDiff = false
    @Published var selectedSection: AppSection = .changes
    @Published var selectedFile: GitFileStatus?
    @Published var selectedCommitFileIDs = Set<String>()
    @Published var selectedDiffMode: GitDiffMode = .unstaged
    @Published var selectedPullStrategy: GitPullStrategy = .merge
    @Published var pullSourceBranch = ""
    @Published var branchSearchText = ""
    @Published private(set) var remoteBranchSearchResults = [GitBranch]()
    @Published private(set) var isSearchingBranches = false
    @Published var commitMessage = ""
    @Published private(set) var diffText = "Select a changed file to view its diff."
    @Published var operationMessage: String?
    @Published var pendingRemoteOperation: GitRemoteOperation?
    @Published var pendingPullPreview: GitPullPreview?
    @Published var pendingRevertFile: GitFileStatus?
    @Published var errorMessage: String?

    private let gitService: GitService?

    init() {
        do {
            let service = try GitService()
            self.gitService = service
            self.gitExecutablePath = service.gitExecutableURL.path
        } catch {
            self.gitService = nil
            self.gitExecutablePath = "Unavailable"
            self.errorMessage = error.localizedDescription
        }
    }

    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.title = "Open Git Repository"
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        Task {
            await openRepository(at: url)
        }
    }

    func refresh() {
        guard let rootPath = snapshot?.rootPath else {
            return
        }

        Task {
            await openRepository(at: rootPath)
        }
    }

    func openRepository(at url: URL) async {
        guard let gitService else {
            errorMessage = "Git is not installed or could not be found."
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let loadedSnapshot = try await gitService.loadRepository(at: url)
            snapshot = loadedSnapshot
            pullSourceBranch = loadedSnapshot.upstreamBranch ?? ""
            selectedCommitFileIDs = defaultCommitSelection(for: loadedSnapshot.files)
            if let selectedFile, loadedSnapshot.files.contains(where: { $0.id == selectedFile.id }) {
                await loadDiff(for: selectedFile)
            } else {
                selectedFile = nil
                diffText = loadedSnapshot.files.isEmpty
                    ? "Working tree clean."
                    : "Select a changed file to view its diff."
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func openRepository(fromDeepLink url: URL) {
        guard url.scheme == "gitview", url.host == "open" else {
            return
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let path = components?.queryItems?.first(where: { $0.name == "path" })?.value, !path.isEmpty else {
            return
        }

        Task {
            await openRepository(at: URL(fileURLWithPath: path))
        }
    }

    func selectFile(_ file: GitFileStatus) {
        selectedFile = file
        if file.state == .untracked {
            selectedDiffMode = .unstaged
        } else if file.isStaged {
            selectedDiffMode = .staged
        } else {
            selectedDiffMode = .unstaged
        }

        Task {
            await loadDiff(for: file)
        }
    }

    func changeDiffMode(_ mode: GitDiffMode) {
        selectedDiffMode = mode
        guard let selectedFile else {
            return
        }

        Task {
            await loadDiff(for: selectedFile)
        }
    }

    private func loadDiff(for file: GitFileStatus) async {
        guard let gitService, let repositoryURL = snapshot?.rootPath else {
            diffText = "Open a repository before viewing diffs."
            return
        }

        isLoadingDiff = true
        do {
            diffText = try await gitService.diff(for: file, mode: selectedDiffMode, in: repositoryURL)
        } catch {
            diffText = error.localizedDescription
        }
        isLoadingDiff = false
    }

    func toggleCommitSelection(for file: GitFileStatus) {
        guard canCommit(file) else {
            return
        }

        if selectedCommitFileIDs.contains(file.id) {
            selectedCommitFileIDs.remove(file.id)
        } else {
            selectedCommitFileIDs.insert(file.id)
        }
    }

    func selectAllCommitFiles() {
        guard let files = snapshot?.files else {
            return
        }

        selectedCommitFileIDs = Set(files.filter(canCommit).map(\.id))
    }

    func clearCommitSelection() {
        selectedCommitFileIDs.removeAll()
    }

    func canCommit(_ file: GitFileStatus) -> Bool {
        !file.isConflicted
    }

    var selectedCommitFilesCount: Int {
        snapshot?.files.filter { selectedCommitFileIDs.contains($0.id) }.count ?? 0
    }

    var canCommitSelectedFiles: Bool {
        selectedCommitFilesCount > 0 && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
    }

    var remoteTargetDescription: String {
        snapshot?.upstreamBranch ?? "origin/\(snapshot?.branch ?? "")"
    }

    var remoteConfirmationMessage: String {
        guard let snapshot, let pendingRemoteOperation else {
            return ""
        }

        switch pendingRemoteOperation {
        case .pull:
            return "Pull changes from \(pendingPullPreview?.target ?? snapshot.branch) using \(selectedPullStrategy.rawValue)?"
        case .push:
            return "Push commits to \(snapshot.upstreamBranch ?? snapshot.branch)?"
        case .pushSetUpstream:
            return "This branch has no upstream. Push and set upstream to origin/\(snapshot.branch)?"
        }
    }

    var remoteConfirmationButtonTitle: String {
        pendingRemoteOperation?.rawValue ?? "Continue"
    }

    func requestPull() {
        Task {
            await preparePull()
        }
    }

    func requestPush() {
        guard let snapshot else {
            errorMessage = "Open a repository before pushing."
            return
        }

        pendingRemoteOperation = snapshot.upstreamBranch == nil ? .pushSetUpstream : .push
    }

    func confirmRemoteOperation() {
        guard let operation = pendingRemoteOperation else {
            return
        }

        pendingRemoteOperation = nil
        Task {
            await runRemoteOperation(operation)
        }
    }

    func preparePullFromTypedBranch() {
        Task {
            await preparePull()
        }
    }

    func commitSelectedFiles() {
        Task {
            await commitSelectedFiles()
        }
    }

    private func commitSelectedFiles() async {
        guard let gitService, let repositoryURL = snapshot?.rootPath, let files = snapshot?.files else {
            errorMessage = "Open a repository before committing."
            return
        }

        let selectedFiles = files.filter { selectedCommitFileIDs.contains($0.id) && canCommit($0) }
        isLoading = true
        operationMessage = nil
        errorMessage = nil

        do {
            operationMessage = try await gitService.commitSelected(files: selectedFiles, message: commitMessage, in: repositoryURL)
            commitMessage = ""
            snapshot = try await gitService.loadRepository(at: repositoryURL)
            pullSourceBranch = snapshot?.upstreamBranch ?? pullSourceBranch
            selectedFile = nil
            selectedCommitFileIDs = defaultCommitSelection(for: snapshot?.files ?? [])
            diffText = snapshot?.files.isEmpty == true ? "Working tree clean." : "Select a changed file to view its diff."
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func defaultCommitSelection(for files: [GitFileStatus]) -> Set<String> {
        Set(files.filter { $0.state != .untracked && canCommit($0) }.map(\.id))
    }

    private func runRemoteOperation(_ operation: GitRemoteOperation) async {
        guard let gitService, let repositoryURL = snapshot?.rootPath else {
            errorMessage = "Open a repository before running remote operations."
            return
        }

        isLoading = true
        operationMessage = nil
        errorMessage = nil

        do {
            let output: String
            switch operation {
            case .pull:
                output = try await gitService.pull(sourceBranch: pendingPullPreview?.sourceBranch, strategy: selectedPullStrategy, in: repositoryURL)
            case .push:
                output = try await gitService.push(in: repositoryURL)
            case .pushSetUpstream:
                output = try await gitService.pushSetUpstream(branch: snapshot?.branch ?? "", in: repositoryURL)
            }

            operationMessage = output
            snapshot = try await gitService.loadRepository(at: repositoryURL)
            pullSourceBranch = snapshot?.upstreamBranch ?? pullSourceBranch
            selectedCommitFileIDs = defaultCommitSelection(for: snapshot?.files ?? [])
            if let selectedFile, snapshot?.files.contains(where: { $0.id == selectedFile.id }) == true {
                await loadDiff(for: selectedFile)
            } else {
                selectedFile = nil
                diffText = snapshot?.files.isEmpty == true ? "Working tree clean." : "Select a changed file to view its diff."
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func requestRevert(file: GitFileStatus) {
        pendingRevertFile = file
    }

    func confirmRevert() {
        guard let file = pendingRevertFile else {
            return
        }

        pendingRevertFile = nil
        Task {
            await revert(file: file)
        }
    }

    private func revert(file: GitFileStatus) async {
        guard let gitService, let repositoryURL = snapshot?.rootPath else {
            errorMessage = "Open a repository before reverting files."
            return
        }

        isLoading = true
        operationMessage = nil
        errorMessage = nil

        do {
            operationMessage = try await gitService.revert(file: file, in: repositoryURL)
            snapshot = try await gitService.loadRepository(at: repositoryURL)
            pullSourceBranch = snapshot?.upstreamBranch ?? pullSourceBranch
            selectedCommitFileIDs = defaultCommitSelection(for: snapshot?.files ?? [])
            if selectedFile?.id == file.id {
                selectedFile = nil
                diffText = snapshot?.files.isEmpty == true ? "Working tree clean." : "Select a changed file to view its diff."
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func switchBranch(to branch: GitBranch) {
        guard !branch.isCurrent else {
            return
        }

        Task {
            await switchBranch(to: branch)
        }
    }

    private func switchBranch(to branch: GitBranch) async {
        guard let gitService, let repositoryURL = snapshot?.rootPath else {
            errorMessage = "Open a repository before switching branches."
            return
        }

        isLoading = true
        operationMessage = nil
        errorMessage = nil

        do {
            if branch.isRemote {
                _ = try await gitService.fetchRemoteBranch(branch, in: repositoryURL)
            }
            operationMessage = try await gitService.switchBranch(to: branch, in: repositoryURL)
            snapshot = try await gitService.loadRepository(at: repositoryURL)
            pullSourceBranch = snapshot?.upstreamBranch ?? ""
            selectedFile = nil
            selectedCommitFileIDs = defaultCommitSelection(for: snapshot?.files ?? [])
            diffText = snapshot?.files.isEmpty == true ? "Working tree clean." : "Select a changed file to view its diff."
            selectedSection = .changes
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func searchRemoteBranches() {
        Task {
            await searchRemoteBranches()
        }
    }

    private func searchRemoteBranches() async {
        guard let gitService, let repositoryURL = snapshot?.rootPath else {
            errorMessage = "Open a repository before searching branches."
            return
        }

        let query = branchSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            remoteBranchSearchResults = []
            errorMessage = "Enter a branch name to search."
            return
        }

        isSearchingBranches = true
        errorMessage = nil

        do {
            remoteBranchSearchResults = try await gitService.searchRemoteBranches(matching: query, in: repositoryURL)
            if remoteBranchSearchResults.isEmpty {
                operationMessage = "No remote branches found matching \"\(query)\"."
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isSearchingBranches = false
    }

    private func preparePull() async {
        guard let gitService, let repositoryURL = snapshot?.rootPath else {
            errorMessage = "Open a repository before pulling."
            return
        }

        isLoading = true
        errorMessage = nil
        pendingPullPreview = nil

        do {
            let typedSource = pullSourceBranch.trimmingCharacters(in: .whitespacesAndNewlines)
            pendingPullPreview = try await gitService.pullPreview(
                sourceBranch: typedSource.isEmpty ? nil : typedSource,
                localFiles: snapshot?.files ?? [],
                in: repositoryURL
            )
            pendingRemoteOperation = .pull
        } catch {
            if case GitServiceError.emptyPullSource = error {
                pendingRemoteOperation = .pull
                errorMessage = nil
            } else {
                errorMessage = error.localizedDescription
            }
        }

        isLoading = false
    }
}
