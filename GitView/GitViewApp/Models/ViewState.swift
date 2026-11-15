import Foundation
#if canImport(Shared)
import Shared
#endif

/// What the diff viewer is currently showing.
enum DiffState: Equatable {
    case placeholder(String)
    case loading
    case loaded(GitDiff)
    case failed(String)
}

enum CommitDetailState: Equatable {
    case none
    case loading
    case loaded(GitCommitDetail)
    case failed(String)
}

struct StatusMessage: Equatable, Identifiable {
    enum Kind {
        case success
        case info
        case error
    }

    let id = UUID()
    let text: String
    let kind: Kind
    let date = Date()
}

struct OutputEntry: Identifiable, Equatable {
    let id = UUID()
    let date = Date()
    let title: String
    let text: String
    let isError: Bool
}

struct AlertContent: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}
