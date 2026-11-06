import AppKit
import Foundation
#if canImport(Shared)
import Shared
#endif

enum ExternalAppError: LocalizedError {
    case terminalNotFound
    case vsCodeNotFound

    var errorDescription: String? {
        switch self {
        case .terminalNotFound:
            "Terminal could not be found on this Mac."
        case .vsCodeNotFound:
            "Visual Studio Code could not be found. Install it from code.visualstudio.com, or run “Shell Command: Install 'code' command in PATH” from VS Code."
        }
    }
}

/// Opens the repository in other apps. Views never launch processes directly.
@MainActor
enum ExternalApps {
    private static let terminalBundleID = "com.apple.Terminal"
    private static let vsCodeBundleID = "com.microsoft.VSCode"

    static func openTerminal(at directory: URL) async throws {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalBundleID) else {
            throw ExternalAppError.terminalNotFound
        }

        // Opening a folder with Terminal starts a new shell with that folder as the working directory.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([directory], withApplicationAt: terminal, configuration: configuration)
    }

    /// Tries the `code` command first, then falls back to opening the VS Code app bundle.
    static func openInVSCode(_ urls: [URL]) async throws {
        if let cli = vsCodeCommandLineTool() {
            let process = Process()
            process.executableURL = cli
            process.arguments = urls.map(\.path)
            process.environment = ProcessExecutor.gitProcessEnvironment()
            // Do not attach pipes: the editor may outlive this call and keep them open.
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil {
                return
            }
        }

        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: vsCodeBundleID) else {
            throw ExternalAppError.vsCodeNotFound
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration)
    }

    static func revealInFinder(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func vsCodeCommandLineTool() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = AppConstants.executableSearchPaths.map { "\($0)/code" } + [
            "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
            "\(home)/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
        ]

        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}
