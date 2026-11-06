import AppKit
#if canImport(Shared)
import Shared
#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let servicesProvider = FinderServiceProvider()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Take over gitview:// URL events before SwiftUI installs its own handler,
        // which would open an extra window for every link.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = servicesProvider
        NSUpdateDynamicServices()
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: text) else {
            return
        }
        MainActor.assumeIsolated {
            DeepLinkRouter.shared.route(url)
        }
    }
}

/// Delivers deep links to the most recently focused window, queueing them
/// until a window exists after a cold launch.
@MainActor
final class DeepLinkRouter {
    static let shared = DeepLinkRouter()

    private final class WeakModel {
        weak var model: RepositoryViewModel?
        init(_ model: RepositoryViewModel) { self.model = model }
    }

    private var models = [WeakModel]()
    private var pending = [URL]()

    func register(_ model: RepositoryViewModel) {
        models.removeAll { $0.model == nil || $0.model === model }
        models.append(WeakModel(model))
        let queued = pending
        pending.removeAll()
        queued.forEach { model.handle(deepLink: $0) }
    }

    func route(_ url: URL) {
        if let model = models.last(where: { $0.model != nil })?.model {
            model.handle(deepLink: url)
        } else {
            pending.append(url)
        }
    }
}

/// Backs the "Open in GitView" entry in Finder's Services / Quick Actions menu.
final class FinderServiceProvider: NSObject {
    @objc func openInGitViewService(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
            let selectedURL = urls.first,
            let deepLinkURL = GitViewDeepLink(path: selectedURL.path).url
        else {
            error.pointee = "GitView could not read the selected Finder item." as NSString
            return
        }

        NSWorkspace.shared.open(deepLinkURL)
    }
}
