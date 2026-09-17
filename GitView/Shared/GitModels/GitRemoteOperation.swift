import Foundation

public enum GitRemoteOperation: String, Identifiable, Sendable {
    case pull = "Pull"
    case push = "Push"
    case pushSetUpstream = "Push and Set Upstream"

    public var id: String {
        rawValue
    }
}
