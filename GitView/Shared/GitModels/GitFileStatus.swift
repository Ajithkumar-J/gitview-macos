import Foundation

public enum GitFileState: String, CaseIterable, Identifiable, Sendable {
    case staged = "Staged"
    case modified = "Modified"
    case added = "Added"
    case deleted = "Deleted"
    case renamed = "Renamed"
    case untracked = "Untracked"
    case conflicted = "Conflicted"

    public var id: String {
        rawValue
    }
}

/// One entry of `git status`. `indexStatus` / `workingTreeStatus` are the
/// porcelain `X` / `Y` columns, with `" "` meaning "unchanged".
public struct GitFileStatus: Identifiable, Hashable, Sendable {
    public let path: String
    public let indexStatus: Character
    public let workingTreeStatus: Character
    public let originalPath: String?

    public var id: String {
        "\(indexStatus)\(workingTreeStatus):\(path):\(originalPath ?? "")"
    }

    public var state: GitFileState {
        if isUntracked {
            return .untracked
        }

        if isConflicted {
            return .conflicted
        }

        if indexStatus != " " {
            return .staged
        }

        switch workingTreeStatus {
        case "M":
            return .modified
        case "A":
            return .added
        case "D":
            return .deleted
        case "R":
            return .renamed
        default:
            return .modified
        }
    }

    public var shortStatus: String {
        "\(indexStatus)\(workingTreeStatus)"
    }

    public var isStaged: Bool {
        indexStatus != " " && indexStatus != "?"
    }

    public var isUntracked: Bool {
        indexStatus == "?" && workingTreeStatus == "?"
    }

    public var isConflicted: Bool {
        let pair = "\(indexStatus)\(workingTreeStatus)"
        return ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(pair)
    }

    /// The file has changes recorded in the index (shown under "Staged Changes").
    public var hasStagedChanges: Bool {
        !isConflicted && !isUntracked && indexStatus != " "
    }

    /// The file has working-tree changes not yet in the index (shown under "Changes").
    public var hasUnstagedChanges: Bool {
        !isConflicted && !isUntracked && workingTreeStatus != " "
    }

    /// Paths that must be passed to Git so that both sides of a rename are handled.
    public var allPaths: [String] {
        [originalPath, path].compactMap { $0 }
    }

    public init(path: String, indexStatus: Character, workingTreeStatus: Character, originalPath: String? = nil) {
        self.path = path
        self.indexStatus = indexStatus
        self.workingTreeStatus = workingTreeStatus
        self.originalPath = originalPath
    }
}
