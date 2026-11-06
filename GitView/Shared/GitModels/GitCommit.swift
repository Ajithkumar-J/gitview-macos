import Foundation

public struct GitCommit: Identifiable, Hashable, Sendable {
    public let hash: String
    public let shortHash: String
    public let authorName: String
    public let authorEmail: String
    public let date: Date
    public let parentHashes: [String]
    /// Decorations such as `HEAD -> main`, `origin/main`, `tag: v1.0`.
    public let refs: [String]
    public let subject: String

    public var id: String {
        hash
    }

    public var isMerge: Bool {
        parentHashes.count > 1
    }

    public init(
        hash: String,
        shortHash: String,
        authorName: String,
        authorEmail: String,
        date: Date,
        parentHashes: [String],
        refs: [String],
        subject: String
    ) {
        self.hash = hash
        self.shortHash = shortHash
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.date = date
        self.parentHashes = parentHashes
        self.refs = refs
        self.subject = subject
    }
}

public struct GitCommitFile: Identifiable, Hashable, Sendable {
    public let path: String
    public let originalPath: String?
    public let kind: GitChangeKind

    public var id: String {
        "\(originalPath ?? ""):\(path)"
    }

    public var allPaths: [String] {
        [originalPath, path].compactMap { $0 }
    }

    public init(path: String, originalPath: String? = nil, kind: GitChangeKind) {
        self.path = path
        self.originalPath = originalPath
        self.kind = kind
    }
}

public struct GitCommitDetail: Equatable, Sendable {
    public let commit: GitCommit
    public let committerName: String
    public let committerEmail: String
    public let committerDate: Date
    /// Full commit message including the subject line.
    public let message: String
    public let files: [GitCommitFile]

    public var body: String {
        let lines = message.components(separatedBy: "\n")
        return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(
        commit: GitCommit,
        committerName: String,
        committerEmail: String,
        committerDate: Date,
        message: String,
        files: [GitCommitFile]
    ) {
        self.commit = commit
        self.committerName = committerName
        self.committerEmail = committerEmail
        self.committerDate = committerDate
        self.message = message
        self.files = files
    }
}
