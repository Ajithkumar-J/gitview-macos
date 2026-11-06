import Cocoa
import FinderSync

/// Adds a "GitView" submenu to Finder's context menu and toolbar.
/// The extension is sandboxed and never runs Git itself: every action opens
/// the main app with a `gitview://` deep link (see GitViewDeepLink).
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

    // MARK: Toolbar button

    override var toolbarItemName: String {
        "GitView"
    }

    override var toolbarItemToolTip: String {
        "Git actions for this folder"
    }

    override var toolbarItemImage: NSImage {
        NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "GitView") ?? NSImage()
    }

    // MARK: Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let submenu = NSMenu(title: "GitView")
        // Finder copies menus across processes and drops `representedObject`,
        // so each action gets its own selector.
        submenu.addItem(item("Open GitView", #selector(openGitView(_:)), symbol: "macwindow"))
        submenu.addItem(item("Git Status", #selector(showStatus(_:)), symbol: "square.and.pencil"))
        submenu.addItem(.separator())
        submenu.addItem(item("Pull…", #selector(pull(_:)), symbol: "arrow.down.circle"))
        submenu.addItem(item("Push…", #selector(push(_:)), symbol: "arrow.up.circle"))
        submenu.addItem(.separator())
        submenu.addItem(item("Git Log", #selector(showLog(_:)), symbol: "clock.arrow.circlepath"))

        if menuKind == .toolbarItemMenu {
            return submenu
        }

        let menu = NSMenu(title: "")
        let root = NSMenuItem(title: "GitView", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        root.submenu = submenu
        menu.addItem(root)
        return menu
    }

    private func item(_ title: String, _ action: Selector, symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    @objc private func openGitView(_ sender: Any?) { open(.open) }
    @objc private func showStatus(_ sender: Any?) { open(.status) }
    @objc private func pull(_ sender: Any?) { open(.pull) }
    @objc private func push(_ sender: Any?) { open(.push) }
    @objc private func showLog(_ sender: Any?) { open(.log) }

    private func open(_ action: GitViewDeepLink.Action) {
        guard let folder = selectedFolderURL(), let url = GitViewDeepLink(path: folder.path, action: action).url else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    /// The right-clicked item, or the folder being viewed. Files resolve to their folder;
    /// the app then walks up to the repository root.
    private func selectedFolderURL() -> URL? {
        let controller = FIFinderSyncController.default()
        guard let url = controller.selectedItemURLs()?.first ?? controller.targetedURL() else {
            return nil
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return url.deletingLastPathComponent()
        }
        return url
    }
}
