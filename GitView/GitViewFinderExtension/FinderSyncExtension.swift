import Cocoa
import FinderSync
import os

/// Paths stay private in the system log.
private let log = Logger(subsystem: "com.local.GitView.FinderExtension", category: "menu")

/// TortoiseGit-style Finder integration: a context menu that adapts to what
/// was right-clicked (repository or not, files or folders) and a toolbar item.
/// The extension is sandboxed and never runs Git itself: every command opens
/// the main app with a `gitview://` deep link (see GitViewDeepLink), and the
/// app shows that command's own window.
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
            URL(fileURLWithPath: "/Volumes", isDirectory: true)
        ]
        log.info("GitView Finder extension loaded")
    }

    // MARK: Toolbar button

    override var toolbarItemName: String {
        "GitView"
    }

    override var toolbarItemToolTip: String {
        "Git commands for this folder"
    }

    override var toolbarItemImage: NSImage {
        NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "GitView") ?? NSImage()
    }

    // MARK: Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let targets = targetURLs(for: menuKind)
        guard let first = targets.first else {
            return nil
        }

        let menu = NSMenu(title: "")
        if let repository = RepositoryLocator.repository(containing: first) {
            let hasItemSelection = menuKind == .contextualMenuForItems
            let branch = repository.branchName.map { " → “\($0)”" } ?? ""

            let submenu = repositoryMenu(hasItemSelection: hasItemSelection)
            if menuKind == .toolbarItemMenu {
                submenu.insertItem(item("Git Commit\(branch)…", #selector(commit(_:)), .commit), at: 0)
                return submenu
            }

            menu.addItem(item("Git Commit\(branch)…", #selector(commit(_:)), .commit))
            menu.addItem(root(submenu))
        } else {
            menu.addItem(item("Git Clone…", #selector(clone(_:)), .clone))
            menu.addItem(item("Git Create Repository Here…", #selector(createRepository(_:)), .createRepository))
            if menuKind == .toolbarItemMenu {
                return menu
            }
        }
        return menu
    }

    private func repositoryMenu(hasItemSelection: Bool) -> NSMenu {
        let menu = NSMenu(title: "GitView")
        if hasItemSelection {
            menu.addItem(item("Diff", #selector(diff(_:)), .diff))
        }
        menu.addItem(item("Show Log", #selector(showLog(_:)), .log))
        menu.addItem(item("Check for Modifications", #selector(status(_:)), .status))
        menu.addItem(.separator())
        menu.addItem(item("Pull…", #selector(pull(_:)), .pull))
        menu.addItem(item("Fetch…", #selector(fetch(_:)), .fetch))
        menu.addItem(item("Push…", #selector(push(_:)), .push))
        menu.addItem(.separator())
        menu.addItem(item("Switch/Checkout…", #selector(switchBranch(_:)), .switchBranch))
        menu.addItem(item("Create Branch…", #selector(createBranch(_:)), .createBranch))
        menu.addItem(.separator())
        menu.addItem(item("Stash Changes…", #selector(stash(_:)), .stash))
        menu.addItem(item("Stash List / Pop…", #selector(stashPop(_:)), .stashPop))
        menu.addItem(.separator())
        menu.addItem(item("Add…", #selector(add(_:)), .add))
        menu.addItem(item("Revert…", #selector(revert(_:)), .revert))
        menu.addItem(.separator())
        menu.addItem(item("Open in GitView", #selector(openGitView(_:)), .open))
        return menu
    }

    private func root(_ submenu: NSMenu) -> NSMenuItem {
        let root = NSMenuItem(title: "GitView", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        root.submenu = submenu
        return root
    }

    private func item(_ title: String, _ action: Selector, _ command: Command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil)
        return item
    }

    // Finder copies menus across processes and drops `representedObject`,
    // so each command gets its own selector.
    @objc private func openGitView(_ sender: Any?) { send(.open) }
    @objc private func commit(_ sender: Any?) { send(.commit) }
    @objc private func diff(_ sender: Any?) { send(.diff) }
    @objc private func showLog(_ sender: Any?) { send(.log) }
    @objc private func status(_ sender: Any?) { send(.status) }
    @objc private func pull(_ sender: Any?) { send(.pull) }
    @objc private func fetch(_ sender: Any?) { send(.fetch) }
    @objc private func push(_ sender: Any?) { send(.push) }
    @objc private func switchBranch(_ sender: Any?) { send(.switchBranch) }
    @objc private func createBranch(_ sender: Any?) { send(.createBranch) }
    @objc private func stash(_ sender: Any?) { send(.stash) }
    @objc private func stashPop(_ sender: Any?) { send(.stashPop) }
    @objc private func add(_ sender: Any?) { send(.add) }
    @objc private func revert(_ sender: Any?) { send(.revert) }
    @objc private func clone(_ sender: Any?) { send(.clone) }
    @objc private func createRepository(_ sender: Any?) { send(.createRepository) }

    private func send(_ command: Command) {
        let controller = FIFinderSyncController.default()
        let selected = controller.selectedItemURLs() ?? []
        let urls = selected.isEmpty ? [controller.targetedURL()].compactMap { $0 } : selected

        guard let link = GitViewDeepLink(paths: urls.map(\.path), action: command.action), let url = link.url else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration) { _, error in
            if let error {
                log.error("Could not open \(url.absoluteString, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The right-clicked items, or the folder being viewed.
    private func targetURLs(for menuKind: FIMenuKind) -> [URL] {
        let controller = FIFinderSyncController.default()
        if menuKind == .contextualMenuForItems, let selected = controller.selectedItemURLs(), !selected.isEmpty {
            return selected
        }
        return [controller.targetedURL()].compactMap { $0 }
    }
}

private typealias Command = GitViewDeepLink.Action

private extension GitViewDeepLink.Action {
    var action: GitViewDeepLink.Action { self }
    var symbol: String { systemImage }
}

/// Finds the repository that contains a Finder item by looking for `.git`.
/// Pure file-system checks: fast enough to run while Finder builds the menu.
enum RepositoryLocator {
    struct Repository {
        let root: URL
        let branchName: String?
    }

    static func repository(containing url: URL) -> Repository? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        var current = url.standardizedFileURL
        if fileManager.fileExists(atPath: current.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            current.deleteLastPathComponent()
        }

        while true {
            let dotGit = current.appendingPathComponent(".git")
            if fileManager.fileExists(atPath: dotGit.path) {
                return Repository(root: current, branchName: branchName(dotGit: dotGit))
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path || current.path == "/" {
                return nil
            }
            current = parent
        }
    }

    /// Branch from `.git/HEAD`; `.git` may also be a file pointing at the real
    /// git directory (worktrees, submodules).
    private static func branchName(dotGit: URL) -> String? {
        var gitDirectory = dotGit
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            guard let text = readSmallFile(dotGit),
                  let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else {
                return nil
            }
            let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            gitDirectory = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : dotGit.deletingLastPathComponent().appendingPathComponent(path)
        }

        guard let head = readSmallFile(gitDirectory.appendingPathComponent("HEAD")) else {
            return nil
        }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        guard trimmed.hasPrefix(prefix) else { return nil }
        return menuSafe(String(trimmed.dropFirst(prefix.count)))
    }

    /// Reads a small regular file without ever blocking Finder: a hostile
    /// repository could make `.git` or `HEAD` a FIFO, a device or a huge file.
    static func readSmallFile(_ url: URL, limit: Int = 4096) -> String? {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= limit,
              let data = try? handle.read(upToCount: limit) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// A branch name as shown in the menu: no control or bidirectional-override
    /// characters (which could disguise it), and not absurdly long.
    static func menuSafe(_ name: String) -> String? {
        let hidden: Set<UInt32> = [0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]
        let clean = String(String.UnicodeScalarView(name.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !hidden.contains($0.value)
        }))
        guard !clean.isEmpty else { return nil }
        return clean.count > 60 ? String(clean.prefix(57)) + "…" : clean
    }
}
