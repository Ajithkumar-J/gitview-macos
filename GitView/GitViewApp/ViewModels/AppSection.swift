import Foundation

enum AppSection: String, Hashable, CaseIterable, Identifiable {
    case changes
    case history
    case branches

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .changes: "Changes"
        case .history: "History"
        case .branches: "Branches"
        }
    }

    var systemImage: String {
        switch self {
        case .changes: "square.and.pencil"
        case .history: "clock.arrow.circlepath"
        case .branches: "arrow.triangle.branch"
        }
    }
}
