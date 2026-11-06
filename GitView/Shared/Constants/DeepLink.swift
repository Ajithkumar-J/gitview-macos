import Foundation

/// `gitview://open?path=<folder>&action=<action>` — used by the Finder extension
/// and the Services menu to hand a folder to the main app.
/// This file is compiled into both the app and the Finder extension, so it must
/// not depend on anything else in Shared.
public struct GitViewDeepLink: Equatable, Sendable {
    public enum Action: String, Sendable, CaseIterable {
        case open
        case status
        case pull
        case push
        case log
    }

    public static let scheme = "gitview"

    public let path: String
    public let action: Action

    public init(path: String, action: Action = .open) {
        self.path = path
        self.action = action
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == "open" else {
            return nil
        }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let path = items.first(where: { $0.name == "path" })?.value, !path.isEmpty else {
            return nil
        }

        self.path = path
        self.action = items.first(where: { $0.name == "action" })?.value.flatMap(Action.init(rawValue:)) ?? .open
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        if action != .open {
            components.queryItems?.append(URLQueryItem(name: "action", value: action.rawValue))
        }
        return components.url
    }
}
