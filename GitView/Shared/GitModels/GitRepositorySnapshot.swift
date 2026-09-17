import Foundation

public struct GitRepositorySnapshot: Equatable, Sendable {
    public let selectedPath: URL
    public let rootPath: URL
    public let name: String
    public let branch: String
    public let upstreamBranch: String?
    public let branches: [GitBranch]
    public let files: [GitFileStatus]

    public var groupedFiles: [(state: GitFileState, files: [GitFileStatus])] {
        GitFileState.allCases.compactMap { state in
            let matchingFiles = files.filter { $0.state == state }
            return matchingFiles.isEmpty ? nil : (state, matchingFiles)
        }
    }

    public init(selectedPath: URL, rootPath: URL, branch: String, upstreamBranch: String?, branches: [GitBranch], files: [GitFileStatus]) {
        self.selectedPath = selectedPath
        self.rootPath = rootPath
        self.name = rootPath.lastPathComponent
        self.branch = branch
        self.upstreamBranch = upstreamBranch
        self.branches = branches
        self.files = files
    }
}
