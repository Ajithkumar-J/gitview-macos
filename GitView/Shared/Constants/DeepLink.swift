import Foundation

/// `gitview://open?path=<item>&path=<item>&action=<action>` — used by the Finder
/// extension and the Services menu to hand Finder items to the main app.
/// This file is compiled into both the app and the Finder extension, so it must
/// not depend on anything else in Shared.
public struct GitViewDeepLink: Equatable, Sendable {
    /// One Finder command. `open` shows the main window; every other action
    /// opens its own TortoiseGit-style command window.
    public enum Action: String, Sendable, CaseIterable {
        case open
        case commit
        case status
        case diff
        case log
        case add
        case revert
        case pull
        case fetch
        case push
        case switchBranch = "switch"
        case createBranch = "branch"
        case stash
        case stashPop = "stash-pop"
        case clone
        case createRepository = "init"

        public var title: String {
            switch self {
            case .open: "Open GitView"
            case .commit: "Commit"
            case .status: "Check for Modifications"
            case .diff: "Diff"
            case .log: "Show Log"
            case .add: "Add"
            case .revert: "Revert"
            case .pull: "Pull"
            case .fetch: "Fetch"
            case .push: "Push"
            case .switchBranch: "Switch/Checkout"
            case .createBranch: "Create Branch"
            case .stash: "Stash Changes"
            case .stashPop: "Stash Pop"
            case .clone: "Clone"
            case .createRepository: "Create Repository"
            }
        }

        public var systemImage: String {
            switch self {
            case .open: "macwindow"
            case .commit: "checkmark.circle"
            case .status: "doc.text.magnifyingglass"
            case .diff: "plusminus"
            case .log: "clock.arrow.circlepath"
            case .add: "plus.circle"
            case .revert: "arrow.uturn.backward.circle"
            case .pull: "arrow.down.circle"
            case .fetch: "arrow.down.to.line.circle"
            case .push: "arrow.up.circle"
            case .switchBranch: "arrow.triangle.swap"
            case .createBranch: "arrow.triangle.branch"
            case .stash: "tray.and.arrow.down"
            case .stashPop: "tray.and.arrow.up"
            case .clone: "square.and.arrow.down.on.square"
            case .createRepository: "folder.badge.plus"
            }
        }
    }

    public static let scheme = "gitview"

    /// Selected Finder items (files or folders). Never empty.
    public let paths: [String]
    public let action: Action

    /// The first selected item.
    public var path: String {
        paths[0]
    }

    public init(path: String, action: Action = .open) {
        self.init(paths: [path], action: action)!
    }

    public init?(paths: [String], action: Action = .open) {
        let paths = paths.filter { !$0.isEmpty }
        guard !paths.isEmpty else {
            return nil
        }
        self.paths = paths
        self.action = action
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == "open" else {
            return nil
        }

        // Links can come from any app or web page: accept only absolute local
        // paths (no "..", control characters or absurd sizes) and a bounded count.
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let rawPaths = items.filter { $0.name == "path" }.compactMap(\.value)
        guard (1...Self.maximumPaths).contains(rawPaths.count) else {
            return nil
        }
        var paths = [String]()
        for path in rawPaths {
            guard let safe = Self.validatedPath(path) else { return nil }
            paths.append(safe)
        }

        self.paths = paths
        self.action = items.first(where: { $0.name == "action" })?.value.flatMap(Action.init(rawValue:)) ?? .open
    }

    public static let maximumPaths = 1000

    static func validatedPath(_ path: String) -> String? {
        let hasControl = path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !hasControl,
              !path.split(separator: "/").contains("..") else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "open"
        components.queryItems = paths.map { URLQueryItem(name: "path", value: $0) }
        if action != .open {
            components.queryItems?.append(URLQueryItem(name: "action", value: action.rawValue))
        }
        return components.url
    }
}
