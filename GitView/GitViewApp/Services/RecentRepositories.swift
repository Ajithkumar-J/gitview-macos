import Foundation
import Observation
#if canImport(Shared)
import Shared
#endif

/// Remembers recently opened repository roots. Only paths are stored.
@MainActor
@Observable
final class RecentRepositories {
    static let shared = RecentRepositories()

    private static let defaultsKey = "GitView.RecentRepositories"
    private static let limit = 10

    private(set) var urls: [URL]

    private init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        urls = paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func add(_ url: URL) {
        let standardized = url.standardizedFileURL
        urls.removeAll { $0.standardizedFileURL.path == standardized.path }
        urls.insert(standardized, at: 0)
        urls = Array(urls.prefix(Self.limit))
        save()
    }

    func remove(_ url: URL) {
        urls.removeAll { $0.standardizedFileURL.path == url.standardizedFileURL.path }
        save()
    }

    func clear() {
        urls.removeAll()
        save()
    }

    private func save() {
        UserDefaults.standard.set(urls.map(\.path), forKey: Self.defaultsKey)
    }
}

/// Addresses of repositories cloned with GitView, newest first, offered in the
/// Clone window. Addresses containing a password or token are never stored.
@MainActor
@Observable
final class CloneHistory {
    static let shared = CloneHistory()

    private static let defaultsKey = "GitView.CloneHistory"
    private static let limit = 20

    private(set) var urls: [String]

    private init() {
        urls = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
    }

    func add(_ url: String) {
        let url = url.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty, Redactor.redact(url) == url else { return }
        let key = RemoteURL.normalized(url)
        urls.removeAll { RemoteURL.normalized($0) == key }
        urls.insert(url, at: 0)
        urls = Array(urls.prefix(Self.limit))
        save()
    }

    func remove(_ url: String) {
        urls.removeAll { $0 == url }
        save()
    }

    func clear() {
        urls.removeAll()
        save()
    }

    private func save() {
        UserDefaults.standard.set(urls, forKey: Self.defaultsKey)
    }
}

extension URL {
    /// `/Users/me/Workspace/app` → `~/Workspace/app`
    var abbreviatedPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
