import AppKit
import Observation
import SwiftUI
#if canImport(Shared)
import Shared
#endif

extension Notification.Name {
    /// Posted after a command window changed a repository, so open windows refresh.
    static let gitViewRepositoryDidChange = Notification.Name("GitViewRepositoryDidChange")
}

/// The outcome shown in a command window after its operation ran.
struct CommandResult: Equatable {
    let title: String
    let output: String
    let succeeded: Bool
    /// Plain-language advice for a failure (sign-in, SSH key, network…).
    var hint: String? = nil
}

/// State shared by one TortoiseGit-style command window: the repository and
/// Finder selection it was opened for, and the operation it runs.
@MainActor
@Observable
final class CommandSession {
    enum Phase: Equatable {
        case resolving
        case ready
        case failed(String)
    }

    let action: GitViewDeepLink.Action
    let selectedURLs: [URL]

    private(set) var phase: Phase = .resolving
    private(set) var service: GitService?
    private(set) var snapshot: GitRepositorySnapshot?
    /// Repository-relative paths the command applies to; empty means the whole repository.
    private(set) var scopePaths: [String] = []

    /// Title of the operation currently running, if any.
    private(set) var runningTitle: String?
    var result: CommandResult?
    /// Buttons offered next to the result, e.g. "Push…" after a commit.
    var followUps: [CommandFollowUp] = []

    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored var onTitleChange: (String) -> Void = { _ in }

    init(link: GitViewDeepLink) {
        action = link.action
        selectedURLs = link.paths.map { URL(fileURLWithPath: $0) }
    }

    // MARK: Derived

    var needsRepository: Bool {
        action != .clone && action != .createRepository
    }

    /// The folder the command was invoked on (a selected file resolves to its folder).
    var targetFolder: URL {
        let url = selectedURLs[0]
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return url.deletingLastPathComponent()
        }
        return url
    }

    var root: URL? {
        snapshot?.rootPath
    }

    var isRunning: Bool {
        runningTitle != nil
    }

    /// Changed files inside the selection.
    var scopedFiles: [GitFileStatus] {
        (snapshot?.files ?? []).filter(isInScope)
    }

    func isInScope(_ file: GitFileStatus) -> Bool {
        guard !scopePaths.isEmpty else {
            return true
        }
        return file.allPaths.contains { path in
            scopePaths.contains { scope in path == scope || path.hasPrefix(scope + "/") }
        }
    }

    /// "repo", "repo/Sources/File.swift" or "repo (3 items)".
    var scopeDescription: String {
        guard let snapshot else {
            return targetFolder.lastPathComponent
        }
        switch scopePaths.count {
        case 0: return snapshot.name
        case 1: return "\(snapshot.name)/\(scopePaths[0])"
        default: return "\(snapshot.name) (\(scopePaths.count) items)"
        }
    }

    var windowTitle: String {
        guard let snapshot else {
            return "\(action.title) — \(targetFolder.lastPathComponent)"
        }
        return "\(action.title) — \(scopePaths.count == 1 ? scopeDescription : snapshot.name)"
    }

    // MARK: Loading

    func resolve() async {
        do {
            service = try GitService()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        guard needsRepository, let service else {
            phase = .ready
            onTitleChange(windowTitle)
            return
        }

        do {
            let loaded = try await service.loadRepository(at: targetFolder)
            snapshot = loaded
            scopePaths = Self.relativePaths(for: selectedURLs, root: loaded.rootPath)
            phase = .ready
            RecentRepositories.shared.add(loaded.rootPath)
        } catch {
            phase = .failed(error.localizedDescription)
        }
        onTitleChange(windowTitle)
    }

    func reload() async {
        guard let service, let root else {
            return
        }
        if let loaded = try? await service.loadRepository(at: root) {
            snapshot = loaded
        }
    }

    /// Selected items relative to the repository root. Selecting the root itself
    /// (or anything outside it) means "the whole repository".
    static func relativePaths(for urls: [URL], root: URL) -> [String] {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        var paths = [String]()
        for url in urls {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            if path == rootPath {
                return []
            }
            if path.hasPrefix(rootPath + "/") {
                paths.append(String(path.dropFirst(rootPath.count + 1)))
            }
        }
        return paths
    }

    // MARK: Running

    /// Runs one Git operation, then shows its output in the window.
    @discardableResult
    func run(
        _ title: String,
        success: String? = nil,
        failure: String? = nil,
        followUps: [CommandFollowUp] = [],
        _ body: @escaping () async throws -> String
    ) async -> Bool {
        runningTitle = title
        defer { runningTitle = nil }
        do {
            let output = try await body()
            self.followUps = followUps
            result = CommandResult(title: success ?? "\(action.title) Finished", output: output, succeeded: true)
            repositoryDidChange()
            return true
        } catch {
            self.followUps = []
            result = CommandResult(
                title: failure ?? "\(action.title) Failed",
                output: error.localizedDescription,
                succeeded: false,
                hint: (error as? LocalizedError)?.recoverySuggestion
            )
            repositoryDidChange()
            return false
        }
    }

    func repositoryDidChange() {
        NotificationCenter.default.post(name: .gitViewRepositoryDidChange, object: root?.path)
        Task { await reload() }
    }

    // MARK: Windows

    func close() {
        onClose()
    }

    /// Opens another command window for the same selection, e.g. "Push…" after a commit.
    func openCommand(_ action: GitViewDeepLink.Action, paths: [String]? = nil) {
        let paths = paths ?? selectedURLs.map(\.path)
        guard let link = GitViewDeepLink(paths: paths, action: action) else {
            return
        }
        if action == .open, let url = link.url {
            DeepLinkRouter.shared.route(url)
        } else {
            CommandWindows.shared.show(link)
        }
    }

    func openInMainWindow(_ url: URL) {
        if let link = GitViewDeepLink(path: url.path, action: .open).url {
            DeepLinkRouter.shared.route(link)
        }
    }

    var preferredSize: NSSize {
        switch action {
        case .commit: NSSize(width: 860, height: 700)
        case .status, .diff: NSSize(width: 1000, height: 680)
        case .log: NSSize(width: 1180, height: 740)
        case .add, .revert: NSSize(width: 620, height: 520)
        case .pull, .push: NSSize(width: 620, height: 600)
        case .switchBranch, .stashPop: NSSize(width: 580, height: 560)
        case .fetch, .createBranch, .stash, .clone, .createRepository, .open: NSSize(width: 540, height: 400)
        }
    }
}

/// Opens and tracks command windows. Each Finder command gets its own window,
/// independent of the main GitView window.
@MainActor
final class CommandWindows: NSObject, NSWindowDelegate {
    static let shared = CommandWindows()

    private var sessions = [ObjectIdentifier: (window: NSWindow, session: CommandSession)]()

    func show(_ link: GitViewDeepLink) {
        let session = CommandSession(link: link)
        let host = NSHostingController(rootView: CommandRootView(session: session))
        host.sizingOptions = [.minSize]

        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = session.windowTitle
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("GitViewCommandWindow")
        window.setContentSize(session.preferredSize)
        window.delegate = self

        if let previous = sessions.values.map(\.window).last(where: \.isVisible) {
            window.setFrameTopLeftPoint(previous.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY)))
        } else {
            window.center()
        }

        session.onClose = { [weak window] in window?.close() }
        session.onTitleChange = { [weak window] title in window?.title = title }
        sessions[ObjectIdentifier(window)] = (window, session)

        AppActivation.bringToFront(window)
        // During a cold launch the system can finish activating after this runs; try once more.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak window] in
            if let window, window.isVisible, !NSApp.isActive {
                AppActivation.bringToFront(window)
            }
        }
        Task { await session.resolve() }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }
        sessions[ObjectIdentifier(window)] = nil
    }
}

private extension NSWindow {
    func cascadeTopLeft(from point: NSPoint) -> NSPoint {
        NSPoint(x: point.x + 24, y: point.y - 24)
    }
}
