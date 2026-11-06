import Foundation

/// The list a change is displayed in. A partially staged file appears in both
/// `.staged` and `.unstaged`, mirroring how Git itself sees it.
public enum GitChangeArea: String, CaseIterable, Identifiable, Sendable {
    case conflicted
    case staged
    case unstaged
    case untracked

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .conflicted: "Merge Conflicts"
        case .staged: "Staged Changes"
        case .unstaged: "Changes"
        case .untracked: "Untracked Files"
        }
    }
}

public enum GitChangeKind: Sendable, Equatable {
    case modified
    case added
    case deleted
    case renamed
    case copied
    case typeChanged
    case untracked
    case conflicted

    public init(statusCode: Character) {
        switch statusCode {
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "T": self = .typeChanged
        case "?": self = .untracked
        case "U": self = .conflicted
        default: self = .modified
        }
    }

    public var letter: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .untracked: "U"
        case .conflicted: "!"
        }
    }

    public var title: String {
        switch self {
        case .modified: "Modified"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .typeChanged: "Type Changed"
        case .untracked: "Untracked"
        case .conflicted: "Conflicted"
        }
    }
}

public struct GitChange: Identifiable, Hashable, Sendable {
    public let file: GitFileStatus
    public let area: GitChangeArea

    public var id: String {
        "\(area.rawValue):\(file.path)"
    }

    public var path: String {
        file.path
    }

    public var kind: GitChangeKind {
        switch area {
        case .conflicted: .conflicted
        case .untracked: .untracked
        case .staged: GitChangeKind(statusCode: file.indexStatus)
        case .unstaged: GitChangeKind(statusCode: file.workingTreeStatus)
        }
    }

    public var diffMode: GitDiffMode {
        area == .staged ? .staged : .unstaged
    }

    public var fileName: String {
        (path as NSString).lastPathComponent
    }

    public var directory: String {
        let directory = (path as NSString).deletingLastPathComponent
        return directory
    }

    public init(file: GitFileStatus, area: GitChangeArea) {
        self.file = file
        self.area = area
    }
}

public extension Array where Element == GitFileStatus {
    func changes(in area: GitChangeArea) -> [GitChange] {
        let matching: [GitFileStatus]
        switch area {
        case .conflicted: matching = filter(\.isConflicted)
        case .staged: matching = filter(\.hasStagedChanges)
        case .unstaged: matching = filter(\.hasUnstagedChanges)
        case .untracked: matching = filter(\.isUntracked)
        }

        return matching
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map { GitChange(file: $0, area: area) }
    }
}
