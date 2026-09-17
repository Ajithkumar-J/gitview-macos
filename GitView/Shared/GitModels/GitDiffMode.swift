import Foundation

public enum GitDiffMode: String, CaseIterable, Identifiable, Sendable {
    case unstaged = "Unstaged"
    case staged = "Staged"

    public var id: String {
        rawValue
    }
}
