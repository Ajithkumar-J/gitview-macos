import SwiftUI
#if canImport(Shared)
import Shared
#endif

@main
struct GitViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1240, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            ToolbarCommands()
            GitViewCommands()
        }
    }
}

struct GitViewCommands: Commands {
    @FocusedValue(\.repositoryModel) private var model

    private var hasRepository: Bool {
        model?.snapshot != nil
    }

    private var canRunRemote: Bool {
        guard let snapshot = model?.snapshot else { return false }
        return !(model?.isBusy ?? true) && !snapshot.remotes.isEmpty
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Repository…") { model?.chooseRepository() }
                .keyboardShortcut("o")
                .disabled(model == nil)

            Menu("Open Recent") {
                ForEach(RecentRepositories.shared.urls, id: \.self) { url in
                    Button(url.lastPathComponent) { model?.open(url) }
                }
                Divider()
                Button("Clear Menu") { RecentRepositories.shared.clear() }
                    .disabled(RecentRepositories.shared.urls.isEmpty)
            }
            .disabled(model == nil)

            Button("Close Repository") { model?.closeRepository() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!hasRepository)
        }

        CommandGroup(before: .sidebar) {
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                Button(section.title) { model?.section = section }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                    .disabled(!hasRepository)
            }
            Divider()
        }

        CommandMenu("Repository") {
            Button("Refresh") { model?.refresh() }
                .keyboardShortcut("r")
                .disabled(!hasRepository)

            Divider()

            Button("Stage All") { model?.stageAll() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!hasRepository || model?.snapshot?.files.isEmpty != false)
            Button("Unstage All") { model?.unstageAll() }
                .disabled(!hasRepository || model?.stagedCount == 0)
            Button("Commit") { model?.commit() }
                .disabled(!(model?.canCommit ?? false))

            Divider()

            Button("Fetch") { model?.fetch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!canRunRemote)
            Button("Pull…") { model?.requestPull() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!canRunRemote)
            Button("Push…") { model?.requestPush() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(!canRunRemote)

            Divider()

            Button("Open in Terminal") { model?.openInTerminal() }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(!hasRepository)
            Button("Open in VS Code") { model?.openInVSCode() }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(!hasRepository)
            Button("Reveal in Finder") { model?.revealInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!hasRepository)

            Divider()

            Button("Show Git Output") { model?.isShowingOutputLog = true }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!hasRepository)
        }
    }
}
