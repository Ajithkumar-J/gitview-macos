import Foundation
import Observation

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

extension URL {
    /// `/Users/me/Workspace/app` → `~/Workspace/app`
    var abbreviatedPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
