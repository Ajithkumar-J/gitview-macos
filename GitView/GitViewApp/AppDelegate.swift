import AppKit
#if canImport(Shared)
import Shared
#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let servicesProvider = FinderServiceProvider()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Do not restore windows: after a Finder command GitView quits with no
        // windows, and restoring "no windows" would leave Open GitView with nothing to show.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Launched from Finder just to run one command: behave like a dialog and quit with it.
        MainActor.assumeIsolated { DeepLinkRouter.shared.isCommandOnlySession }
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

/// Brings GitView and one of its windows to the front, even when the request
/// came from another app (Finder) that is currently active.
@MainActor
enum AppActivation {
    static func bringToFront(_ window: NSWindow?) {
        NSApp.unhide(nil)
        if let window {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        NSApp.activate()
        // Since macOS 14 `activate()` is only a request that the system may decline
        // while Finder is active. A Finder menu command is an explicit user request
        // to show GitView, so fall back to the forcing variant (deprecated, hence
        // called by selector to keep the build warning-free).
        let forceActivate = NSSelectorFromString("activateIgnoringOtherApps:")
        if NSApp.responds(to: forceActivate), let implementation = NSApp.method(for: forceActivate) {
            typealias ActivateFunction = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
            unsafeBitCast(implementation, to: ActivateFunction.self)(NSApp, forceActivate, true)
        }
    }
}

/// Sends deep links to the right place: `open` goes to a main window (opening
/// one when none is visible); every other action opens a command window.
@MainActor
final class DeepLinkRouter {
    static let shared = DeepLinkRouter()

    private final class Entry {
        weak var model: RepositoryViewModel?
        weak var window: NSWindow?
        init(model: RepositoryViewModel, window: NSWindow?) {
            self.model = model
            self.window = window
        }
    }

    private var entries = [Entry]()
    private var pending = [URL]()
    private let launchDate = Date()
    /// True while GitView only shows command windows it was launched for.
    private(set) var isCommandOnlySession = false
    /// Opens a new main window; set by the first main window that appears.
    var openMainWindow: (() -> Void)?

    private var isWithinLaunch: Bool {
        Date().timeIntervalSince(launchDate) < 5
    }

    func register(_ model: RepositoryViewModel, window: NSWindow?) {
        entries.removeAll { $0.model == nil || $0.model === model }
        entries.append(Entry(model: model, window: window))

        if isCommandOnlySession, pending.isEmpty, model.snapshot == nil, let window {
            // SwiftUI opened its default window while launching for a command; it is not wanted.
            DispatchQueue.main.async { window.close() }
            return
        }

        isCommandOnlySession = false
        let queued = pending
        pending.removeAll()
        queued.forEach { model.handle(deepLink: $0) }
        if !queued.isEmpty {
            AppActivation.bringToFront(window)
        }
    }

    func route(_ url: URL) {
        guard let link = GitViewDeepLink(url: url) else {
            return
        }

        if link.action == .open {
            routeToMainWindow(url)
            return
        }

        let visibleMain = entries.first { $0.model != nil && $0.window?.isVisible == true }
        if visibleMain == nil, isWithinLaunch {
            isCommandOnlySession = true
        } else if let visibleMain, isWithinLaunch, visibleMain.model?.snapshot == nil {
            isCommandOnlySession = true
            visibleMain.window?.close()
        }
        CommandWindows.shared.show(link)
    }

    private func routeToMainWindow(_ url: URL) {
        isCommandOnlySession = false
        if let entry = entries.last(where: { $0.model != nil && $0.window?.isVisible == true }), let model = entry.model {
            model.handle(deepLink: url)
            AppActivation.bringToFront(entry.window)
            return
        }

        pending.append(url)
        // No visible main window (closed, or not created yet on a cold launch).
        if openMainWindow != nil, !isWithinLaunch || !entries.isEmpty {
            openNewMainWindow()
        } else {
            // Give SwiftUI a moment to create its launch window; open one if it does not.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.pending.isEmpty else { return }
                self.openNewMainWindow()
            }
        }
        NSApp.activate()
    }

    private func openNewMainWindow() {
        if let openMainWindow {
            openMainWindow()
            return
        }
        // No SwiftUI view has appeared yet, so no openWindow action: use File ▸ New Window.
        guard let mainMenu = NSApp.mainMenu, let (menu, index) = Self.find(title: "New Window", in: mainMenu) else {
            return
        }
        menu.update()
        menu.performActionForItem(at: index)
    }

    private static func find(title: String, in menu: NSMenu) -> (NSMenu, Int)? {
        for (index, item) in menu.items.enumerated() {
            if item.title == title, item.action != nil {
                return (menu, index)
            }
            if let submenu = item.submenu, let found = find(title: title, in: submenu) {
                return found
            }
        }
        return nil
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

/// The sign-in dialog Git and SSH show through GIT_ASKPASS / SSH_ASKPASS: they
/// run GitView's binary with the question as its only argument, and GitView sets
/// GITVIEW_ASKPASS=1 for the Git processes it starts. Runs as a short-lived
/// process with no Dock icon, prints the answer on standard output and exits
/// (status 1 when cancelled). The answer is never logged or stored.
@MainActor
enum AskPassPrompt {
    nonisolated static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard ProcessInfo.processInfo.environment["GITVIEW_ASKPASS"] == "1", arguments.count == 2 else {
            return
        }
        let question = arguments[1]
        let answer = MainActor.assumeIsolated { ask(question) }
        guard let answer else {
            exit(1)
        }
        FileHandle.standardOutput.write(Data((answer + "\n").utf8))
        exit(0)
    }

    private static func ask(_ question: String) -> String? {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let prompt = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = Self.host(in: prompt)
        let alert = NSAlert()

        if prompt.contains("(yes/no") {
            alert.alertStyle = .warning
            alert.messageText = "Trust \(host ?? "this server")?"
            alert.informativeText = prompt + "\n\nChoose Connect only if you expected to connect to this server."
            alert.addButton(withTitle: "Connect")
            alert.addButton(withTitle: "Cancel")
            // Return must not trust a server by reflex: make Cancel the default button.
            alert.buttons[0].keyEquivalent = ""
            alert.buttons[1].keyEquivalent = "\r"
            return show(alert) ? "yes" : nil
        }

        let lowercased = prompt.lowercased()
        let isPassphrase = lowercased.contains("passphrase")
        let isSecret = isPassphrase || lowercased.contains("password") || prompt.contains("PIN")
        let field: NSTextField = isSecret ? NSSecureTextField() : NSTextField()
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)

        if isPassphrase {
            alert.messageText = "Unlock SSH Key"
            alert.informativeText = prompt
            field.placeholderString = "Passphrase"
        } else if lowercased.hasPrefix("username") {
            alert.messageText = "Sign in to \(host ?? "the Git server")"
            alert.informativeText = "Enter your user name for \(host ?? "this server")."
            field.placeholderString = "User name"
        } else if lowercased.hasPrefix("password") {
            alert.messageText = "Sign in to \(host ?? "the Git server")"
            alert.informativeText = "Paste a personal access token (or app password). GitHub, GitLab, Azure DevOps and Bitbucket don't accept your account password here. It is saved in your Keychain."
            field.placeholderString = "Personal access token"
        } else {
            alert.messageText = "Git Needs Information"
            alert.informativeText = prompt
        }
        alert.accessoryView = field
        alert.addButton(withTitle: isSecret && !isPassphrase ? "Sign In" : "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return show(alert) ? field.stringValue : nil
    }

    private static func show(_ alert: NSAlert) -> Bool {
        alert.layout()
        AppActivation.bringToFront(alert.window)
        alert.window.level = .floating
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// "github.com" from prompts like "Password for 'https://me@github.com': ".
    static func host(in prompt: String) -> String? {
        guard let quoteStart = prompt.firstIndex(of: "'") else { return nil }
        let rest = prompt[prompt.index(after: quoteStart)...]
        guard let quoteEnd = rest.firstIndex(of: "'") else { return nil }
        var target = String(rest[..<quoteEnd])
        if let scheme = target.range(of: "://") {
            target = String(target[scheme.upperBound...])
        } else if target.contains("/") {
            return nil   // a file path (SSH key), not a server
        }
        if let at = target.lastIndex(of: "@") {
            target = String(target[target.index(after: at)...])
        }
        target = String(target.prefix { $0 != "/" && $0 != ":" })
        if let space = target.firstIndex(of: " ") {
            target = String(target[..<space])
        }
        return target.isEmpty ? nil : target
    }
}

/// Asks before GitView runs Git in a repository whose own settings or hooks
/// would run programs (see `RepositorySafety`). "Don't Open" is the default.
enum RepositoryTrustPrompt {
    @Sendable static func confirm(_ report: RepositorySafetyReport) async -> Bool {
        await MainActor.run { ask(report) }
    }

    @MainActor
    private static func ask(_ report: RepositorySafetyReport) -> Bool {
        let shown = report.risks.prefix(10).map { risk -> String in
            let value = DisplayText.visible(String(risk.value.prefix(160)), keepNewlines: false)
            let place = risk.location == "this repository" ? "" : " (\(DisplayText.visible(risk.location, keepNewlines: false)))"
            return "• \(risk.setting)\(place) = \(value)\n   \(risk.effect)"
        }
        let more = report.risks.count > 10 ? "\n…and \(report.risks.count - 10) more." : ""

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Trust “\(DisplayText.visible(report.root.lastPathComponent, keepNewlines: false))”?"
        alert.informativeText = """
        This repository's own settings make Git run programs on your Mac:

        \(shown.joined(separator: "\n"))\(more)

        A repository from someone else can use this to run harmful code. Open it only if you know where it came from. GitView asks again if these settings change.
        """
        alert.addButton(withTitle: "Don't Open")
        alert.addButton(withTitle: "Trust and Open")
        AppActivation.bringToFront(nil)
        return alert.runModal() == .alertSecondButtonReturn
    }
}

