import Foundation

public struct GitBranch: Identifiable, Equatable, Sendable {
    public let name: String
    public let isCurrent: Bool
    public let isRemote: Bool

    public var displayName: String {
        name
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

    public init(name: String, isCurrent: Bool, isRemote: Bool = false) {
        self.name = name
        self.isCurrent = isCurrent
        self.isRemote = isRemote
    }
}
