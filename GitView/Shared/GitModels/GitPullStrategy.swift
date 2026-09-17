import Foundation

public enum GitPullStrategy: String, CaseIterable, Identifiable, Sendable {
    case merge = "Merge"
    case rebase = "Rebase"
    case fastForwardOnly = "Fast-Forward Only"

    public var id: String {
        rawValue
    }

    public var gitArguments: [String] {
        switch self {
        case .merge:
            ["--no-rebase"]
        case .rebase:
            ["--rebase"]
        case .fastForwardOnly:
            ["--ff-only"]
        }
    }
}

public struct GitPullPreview: Equatable, Sendable {
    public let target: String
    public let sourceBranch: String?
    public let aheadCount: Int
    public let behindCount: Int
    public let localChangedFiles: [String]
    public let incomingChangedFiles: [String]
    public let possibleConflictFiles: [String]

    public var isDiverged: Bool {
        aheadCount > 0 && behindCount > 0
    }

    public var hasPossibleConflicts: Bool {
        !possibleConflictFiles.isEmpty
    }

    public init(
        target: String,
        sourceBranch: String?,
        aheadCount: Int,
        behindCount: Int,
        localChangedFiles: [String],
        incomingChangedFiles: [String],
        possibleConflictFiles: [String]
    ) {
        self.target = target
        self.sourceBranch = sourceBranch
        self.aheadCount = aheadCount
        self.behindCount = behindCount
        self.localChangedFiles = localChangedFiles
        self.incomingChangedFiles = incomingChangedFiles
        self.possibleConflictFiles = possibleConflictFiles
    }
}
