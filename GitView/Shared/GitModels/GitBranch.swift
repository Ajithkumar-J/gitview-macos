import Foundation

public struct GitBranch: Identifiable, Hashable, Sendable {
    /// Short ref name: `main` for local branches, `origin/main` for remote ones.
    public let name: String
    public let isCurrent: Bool
    public let isRemote: Bool
    public let upstream: String?
    public let aheadCount: Int
    public let behindCount: Int
    public let isUpstreamGone: Bool
    public let lastCommitDate: Date?
    public let lastCommitSubject: String?
    /// `true` when the branch was found with `git ls-remote` and is not fetched locally yet.
    public let isUnfetched: Bool

    public var displayName: String {
        name
    }

    public var remoteName: String? {
        guard isRemote, let slashIndex = name.firstIndex(of: "/") else {
            return nil
        }

        return String(name[..<slashIndex])
    }

    public var localTrackingName: String {
        guard isRemote, let slashIndex = name.firstIndex(of: "/") else {
            return name
        }

        return String(name[name.index(after: slashIndex)...])
    }

    public var id: String {
        "\(isRemote ? "remote" : "local"):\(name)"
    }

    public init(
        name: String,
        isCurrent: Bool,
        isRemote: Bool = false,
        upstream: String? = nil,
        aheadCount: Int = 0,
        behindCount: Int = 0,
        isUpstreamGone: Bool = false,
        lastCommitDate: Date? = nil,
        lastCommitSubject: String? = nil,
        isUnfetched: Bool = false
    ) {
        self.name = name
        self.isCurrent = isCurrent
        self.isRemote = isRemote
        self.upstream = upstream
        self.aheadCount = aheadCount
        self.behindCount = behindCount
        self.isUpstreamGone = isUpstreamGone
        self.lastCommitDate = lastCommitDate
        self.lastCommitSubject = lastCommitSubject
        self.isUnfetched = isUnfetched
    }
}
