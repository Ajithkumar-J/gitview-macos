import Cocoa
import FinderSync

@objc(GitViewFinderSyncExtension)
final class FinderSyncExtension: FIFinderSync {
    override init() {
        super.init()
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        FIFinderSyncController.default().directoryURLs = [
            URL(fileURLWithPath: "/", isDirectory: true),
            homeURL,
            homeURL.appendingPathComponent("Desktop", isDirectory: true),
            homeURL.appendingPathComponent("Documents", isDirectory: true),
            homeURL.appendingPathComponent("Downloads", isDirectory: true),
            homeURL.appendingPathComponent("DevSource", isDirectory: true),
            URL(fileURLWithPath: "/Volumes", isDirectory: true)
        ]
        NSLog("GitView Finder extension loaded")
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        NSLog("GitView Finder extension requested menu for kind \(menuKind.rawValue)")
        let menu = NSMenu(title: "GitView")
        let item = NSMenuItem(
            title: "Open in GitView",
            action: #selector(openInGitView(_:)),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func openInGitView(_ sender: Any?) {
        guard let selectedURL = selectedRepositoryURL() else {
            return
        }

        var components = URLComponents()
        components.scheme = "gitview"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "path", value: selectedURL.path)
        ]

        guard let url = components.url else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func selectedRepositoryURL() -> URL? {
        let controller = FIFinderSyncController.default()
        if let selectedURL = controller.selectedItemURLs()?.first {
            return selectedURL
        }

        return controller.targetedURL()
    }
}
