#if DEBUG
import AppKit
import SwiftUI
#if canImport(Shared)
import Shared
#endif

/// Debug builds only: opens GitView's main window and command windows on a demo
/// repository and saves each as a PNG for the README. The app draws its own
/// windows, so no screen-recording permission is needed.
/// Started by scripts/take-screenshots.sh, which sets GITVIEW_SCREENSHOTS
/// (output folder) and GITVIEW_SCREENSHOT_REPO (the demo repository).
@MainActor
enum ScreenshotTour {
    private static let recentsKey = "GitView.RecentRepositories"

    static func startIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["GITVIEW_SCREENSHOTS"], let repository = environment["GITVIEW_SCREENSHOT_REPO"] else {
            return
        }
        NSApp.appearance = NSAppearance(named: environment["GITVIEW_SCREENSHOT_DARK"] == "1" ? .darkAqua : .aqua)
        // The demo repository must not stay in the user's Recent list.
        let recents = UserDefaults.standard.object(forKey: recentsKey)
        Task {
            await run(output: URL(fileURLWithPath: output), repository: URL(fileURLWithPath: repository))
            if let recents {
                UserDefaults.standard.set(recents, forKey: recentsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: recentsKey)
            }
            NSApp.terminate(nil)
        }
    }

    private static func run(output: URL, repository: URL) async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApp.activate()

        if let url = GitViewDeepLink(path: repository.path).url {
            DeepLinkRouter.shared.route(url)
        }
        await pause(4)
        // SwiftUI may already have opened the main window at launch, so take
        // the largest window that isn't a command window.
        let main = NSApp.windows
            .filter { $0.isVisible && $0.identifier?.rawValue != "GitViewCommandWindow" && $0.frame.width > 300 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        if let main {
            main.setContentSize(NSSize(width: 1240, height: 760))
            main.makeKeyAndOrderFront(nil)
            await pause(1.5)
            // The translucent sidebar can't be drawn into an image; crop it off.
            let sidebar = sidebarWidth(in: main.contentView)
            let model = DeepLinkRouter.shared.newestModel
            model?.selectedChangeID = "unstaged:src/cart.js"
            await pause(2)
            await save(main, "main-changes", in: output, cropLeading: sidebar)

            model?.section = .history
            await pause(3)
            model?.selectedCommitID = model?.commits.dropFirst().first?.id
            await pause(2)
            await save(main, "main-history", in: output, cropLeading: sidebar)

            model?.section = .branches
            await pause(3)
            await save(main, "main-branches", in: output, cropLeading: sidebar)
            main.close()
        }

        let commands: [(GitViewDeepLink.Action, String?, String)] = [
            (.commit, nil, "commit"),
            (.revertChanges, "src/cart.js", "revert-changes"),
            (.pull, nil, "pull"),
            (.switchBranch, nil, "switch-branch"),
            (.log, nil, "log"),
        ]
        for (action, file, name) in commands {
            let before = visibleWindows()
            let path = file.map { repository.appendingPathComponent($0).path } ?? repository.path
            CommandWindows.shared.show(GitViewDeepLink(path: path, action: action))
            await pause(4)
            if let window = newWindow(since: before) {
                await save(window, name, in: output)
                window.close()
            }
        }
    }

    private static func visibleWindows() -> Set<ObjectIdentifier> {
        Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
    }

    private static func newWindow(since before: Set<ObjectIdentifier>) -> NSWindow? {
        NSApp.windows.last { $0.isVisible && !before.contains(ObjectIdentifier($0)) && $0.frame.width > 300 }
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Width of the first column of the window's three-column split view.
    private static func sidebarWidth(in view: NSView?) -> CGFloat {
        guard let view else { return 0 }
        if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count >= 3 {
            return split.arrangedSubviews[0].frame.width + split.dividerThickness
        }
        for subview in view.subviews {
            let width = sidebarWidth(in: subview)
            if width > 0 { return width }
        }
        return 0
    }

    /// Draws the whole window, title bar included, into a PNG.
    private static func save(_ window: NSWindow, _ name: String, in folder: URL, cropLeading: CGFloat = 0) async {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        // Let lazily built rows appear on screen before drawing the copy.
        view.layoutSubtreeIfNeeded()
        view.display()
        await pause(1)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var image = bitmap
        if cropLeading > 0, let full = bitmap.cgImage {
            let scale = CGFloat(full.width) / view.bounds.width
            let rect = CGRect(x: cropLeading * scale, y: 0, width: CGFloat(full.width) - cropLeading * scale, height: CGFloat(full.height))
            if let cropped = full.cropping(to: rect) { image = NSBitmapImageRep(cgImage: cropped) }
        }
        try? image.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
    }
}
#endif
