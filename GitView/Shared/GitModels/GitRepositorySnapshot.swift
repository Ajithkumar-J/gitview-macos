import Foundation

public struct GitRepositorySnapshot: Equatable, Sendable {
    public let selectedPath: URL
    public let rootPath: URL
    public let name: String
    /// Current branch name, or `"Detached HEAD"` when HEAD is detached.
    public let branch: String
    public let isDetachedHead: Bool
    /// Full commit id of HEAD, `nil` when the repository has no commits yet.
    public let headOID: String?
    public let upstreamBranch: String?
    public let aheadCount: Int
    public let behindCount: Int
    public let remotes: [String]
    public let files: [GitFileStatus]

    public init(
        selectedPath: URL,
        rootPath: URL,
        branch: String,
        isDetachedHead: Bool = false,
        headOID: String? = nil,
        upstreamBranch: String?,
        aheadCount: Int = 0,
        behindCount: Int = 0,
        remotes: [String] = [],
        files: [GitFileStatus]
    ) {
        self.selectedPath = selectedPath
        self.rootPath = rootPath
        self.name = rootPath.lastPathComponent
        self.branch = branch
        self.isDetachedHead = isDetachedHead
        self.headOID = headOID
        self.upstreamBranch = upstreamBranch
        self.aheadCount = aheadCount
        self.behindCount = behindCount
        self.remotes = remotes
        self.files = files
    }

    public func changes(in area: GitChangeArea) -> [GitChange] {
        files.changes(in: area)
    }

    public var stagedCount: Int {
        files.filter(\.hasStagedChanges).count
    }

    public var hasConflicts: Bool {
        files.contains(where: \.isConflicted)
    }

    public var hasCommits: Bool {
        headOID != nil
    }

    /// Remote used for push/pull when the branch has no upstream yet.
    public var defaultRemote: String? {
        if let upstreamBranch, let remote = remotes.first(where: { upstreamBranch.hasPrefix("\($0)/") }) {
            return remote
        }

        if remotes.contains("origin") {
            return "origin"
        }

        return remotes.first
    }

    public var branchDisplayName: String {
        guard isDetachedHead else {
            return branch
        }

        if let headOID {
            return "Detached at \(headOID.prefix(7))"
        }

        return branch
    }
}
