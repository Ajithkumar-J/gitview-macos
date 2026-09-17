import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let servicesProvider = FinderServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = servicesProvider
        NSUpdateDynamicServices()
    }
}

final class FinderServiceProvider: NSObject {
    @objc func openInGitViewService(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
            let selectedURL = urls.first,
            let deepLinkURL = Self.deepLinkURL(for: selectedURL)
        else {
            error.pointee = "GitView could not read the selected Finder item." as NSString
            return
        }

        NSWorkspace.shared.open(deepLinkURL)
    }

    private static func deepLinkURL(for selectedURL: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "gitview"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "path", value: selectedURL.path)
        ]
        return components.url
    }
}
