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

public struct GitFileStatus: Identifiable, Equatable, Sendable {
    public let path: String
    public let indexStatus: Character
    public let workingTreeStatus: Character
    public let originalPath: String?

    public var id: String {
        "\(indexStatus)\(workingTreeStatus):\(path):\(originalPath ?? "")"
    }

    public var state: GitFileState {
        if indexStatus == "?" && workingTreeStatus == "?" {
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

    public var isConflicted: Bool {
        let pair = "\(indexStatus)\(workingTreeStatus)"
        return ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(pair)
    }

    public init(path: String, indexStatus: Character, workingTreeStatus: Character, originalPath: String? = nil) {
        self.path = path
        self.indexStatus = indexStatus
        self.workingTreeStatus = workingTreeStatus
        self.originalPath = originalPath
    }
}
