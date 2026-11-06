import Foundation

public enum GitDiffLineKind: Sendable, Equatable {
    /// File-level metadata, e.g. `new file mode 100644` or `Binary files differ`.
    case meta
    case hunkHeader
    case context
    case addition
    case deletion
    /// `\ No newline at end of file`
    case noNewline
}

public struct GitDiffLine: Sendable, Equatable {
    public let kind: GitDiffLineKind
    public let oldLineNumber: Int?
    public let newLineNumber: Int?
    public let text: String

    public init(kind: GitDiffLineKind, oldLineNumber: Int? = nil, newLineNumber: Int? = nil, text: String) {
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.text = text
    }
}

public struct GitDiff: Sendable, Equatable {
    public let lines: [GitDiffLine]
    public let additions: Int
    public let deletions: Int
    public let isBinary: Bool
    public let isTruncated: Bool

    public var isEmpty: Bool {
        lines.isEmpty
    }

    public init(lines: [GitDiffLine], additions: Int, deletions: Int, isBinary: Bool, isTruncated: Bool) {
        self.lines = lines
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
        self.isTruncated = isTruncated
    }

    public static let empty = GitDiff(lines: [], additions: 0, deletions: 0, isBinary: false, isTruncated: false)
}
