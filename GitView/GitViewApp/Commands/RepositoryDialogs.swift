import AppKit
import SwiftUI
#if canImport(Shared)
import Shared
#endif

// MARK: - Show Log

/// Standalone log window, limited to the selected files/folders when there are any.
struct LogDialog: View {
    let session: CommandSession
    @State private var model = RepositoryViewModel()

    var body: some View {
        VStack(spacing: 0) {
            DialogHeader(session: session, subtitle: session.scopePaths.isEmpty ? session.snapshot?.name : "History of \(session.scopeDescription)")
            Divider()
            if model.snapshot == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    HistoryListView(model: model)
                        .frame(minWidth: 300, idealWidth: 420, maxWidth: 640)
                    CommitDetailView(model: model)
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task {
            guard let root = session.root, model.snapshot == nil else { return }
            model.historyPaths = session.scopePaths
            model.open(root)
        }
        .onReceive(NotificationCenter.default.publisher(for: .gitViewRepositoryDidChange)) { _ in
            model.refresh()
        }
        .onChange(of: model.commits.first?.id) { _, first in
            // Like TortoiseGit, start with the newest commit selected.
            if model.selectedCommitID == nil {
                model.selectedCommitID = first
            }
        }
    }
}

// MARK: - Switch / Checkout

struct SwitchBranchDialog: View {
    let session: CommandSession

    @State private var catalog = BranchCatalog()
    @State private var filter = ""
    @State private var serverMatches: [GitBranch] = []
    @State private var isSearchingServer = false
    @State private var selection: GitBranch.ID?
    @State private var createNew = false
    @State private var newName = ""
    @State private var nameProblem: String?

    private var allBranches: [GitBranch] {
        catalog.local + catalog.remote + unfetched
    }

    /// Server branches matching the filter that are not fetched yet.
    private var unfetched: [GitBranch] {
        let known = Set(catalog.remote.map(\.name))
        return serverMatches.filter { !known.contains($0.name) }
    }

    private var selected: GitBranch? {
        allBranches.first { $0.id == selection }
    }

    private func filtered(_ branches: [GitBranch]) -> [GitBranch] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? branches : branches.filter { BranchSearch.matches($0.name, query: query) }
    }

    private var problem: String? {
        guard let selected else { return "Choose a branch." }
        if createNew { return nameProblem }
        if selected.isCurrent { return "\(selected.name) is already checked out." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            DialogHeader(session: session, subtitle: "Currently on \(session.snapshot?.branchDisplayName ?? "")")
            Divider()
            FilterField(prompt: "Filter branches", text: $filter)
                .padding(10)
            Divider()

            List(selection: $selection) {
                let local = filtered(catalog.local)
                if !local.isEmpty {
                    Section("Local Branches") {
                        ForEach(local) { branchRow($0).tag($0.id) }
                    }
                }
                let remote = filtered(catalog.remote)
                if !remote.isEmpty {
                    Section("Remote Branches") {
                        ForEach(remote) { branchRow($0).tag($0.id) }
                    }
                }
                if !unfetched.isEmpty {
                    Section("On the Server — Not Fetched Yet") {
                        ForEach(unfetched) { branchRow($0).tag($0.id) }
                    }
                }
                if isSearchingServer {
                    Label("Searching the server…", systemImage: "network")
                        .foregroundStyle(.secondary)
                } else if !filter.trimmingCharacters(in: .whitespaces).isEmpty, filtered(catalog.local).isEmpty, remote.isEmpty, unfetched.isEmpty {
                    Text("No branches contain “\(filter)”.")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Create a new branch from the selected one", isOn: $createNew)
                    .toggleStyle(.checkbox)
                if createNew {
                    TextField("New branch name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                }
                if session.scopedFiles.contains(where: { !$0.isUntracked }) {
                    Label("You have uncommitted changes. Git keeps them when it can, and refuses to switch if they would be overwritten.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)

            DialogFooter(session: session) {
                if let problem {
                    Text(problem).font(.callout).foregroundStyle(.secondary)
                }
                Button(createNew ? "Create & Switch" : "Switch", action: perform)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
        }
        .task {
            await catalog.load(session)
            selection = catalog.local.first(where: \.isCurrent)?.id
        }
        .task(id: filter) { await searchServer() }
        .onChange(of: selection) { _, _ in
            if let selected, selected.isRemote, newName.isEmpty || catalog.remote.contains(where: { $0.localTrackingName == newName }) {
                newName = selected.localTrackingName
            }
        }
        .task(id: "\(createNew)|\(newName)") {
            guard createNew, let service = session.service, let root = session.root else {
                nameProblem = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
            nameProblem = await service.branchNameProblem(newName, in: root)
        }
    }

    private func branchRow(_ branch: GitBranch) -> some View {
        HStack(spacing: 8) {
            Image(systemName: branch.isRemote ? "network" : "arrow.triangle.branch")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(branch.name)
                .fontWeight(branch.isCurrent ? .semibold : .regular)
            if branch.isCurrent {
                Text("current")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if branch.aheadCount > 0 || branch.behindCount > 0 {
                AheadBehindView(ahead: branch.aheadCount, behind: branch.behindCount)
            }
            if let date = branch.lastCommitDate {
                Text(GitDateFormatter.short(date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Searches the server's branches as you type (the list is fetched once and cached).
    private func searchServer() async {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let service = session.service, let root = session.root,
              let remote = session.snapshot?.defaultRemote else {
            serverMatches = []
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        isSearchingServer = true
        defer { isSearchingServer = false }
        let results = (try? await RemoteBranchDirectory.shared.search(query, remote: remote, in: root, service: service)) ?? []
        guard !Task.isCancelled else { return }
        serverMatches = results
    }

    private func perform() {
        guard let service = session.service, let root = session.root, let selected else { return }
        let createNew = createNew
        let name = newName.trimmingCharacters(in: .whitespaces)
        let target = createNew ? name : selected.isRemote ? selected.localTrackingName : selected.name
        Task {
            await session.run(
                "Switching to \(target)…",
                success: "Switched to \(target)",
                followUps: [
                    // The natural next step after switching: get the branch's latest commits.
                    CommandFollowUp(title: "Pull…", systemImage: "arrow.down.circle") {
                        session.openCommand(.pull, paths: [root.path])
                        session.close()
                    },
                ]
            ) {
                var fetched = ""
                if selected.isUnfetched {
                    fetched = try await service.fetchRemoteBranch(selected, in: root)
                }
                let output = createNew
                    ? try await service.createBranch(named: name, from: selected.name, switchToBranch: true, in: root)
                    : try await service.switchBranch(to: selected, in: root)
                return [fetched, output].filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
        }
    }
}

// MARK: - Create Branch

struct CreateBranchDialog: View {
    let session: CommandSession

    @State private var catalog = BranchCatalog()
    @State private var name = ""
    @State private var base: String?
    @State private var switchToBranch = true
    @State private var nameProblem: String? = "Enter a branch name."
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            DialogHeader(session: session)
            Divider()

            DialogForm {
                FormRow(label: "Branch name") {
                    TextField("feature/my-change", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($isNameFocused)
                        .onSubmit {
                            Task {
                                // Validate the final text before creating; the debounced check may lag.
                                guard let service = session.service, let root = session.root else { return }
                                nameProblem = await service.branchNameProblem(name, in: root)
                                if nameProblem == nil, session.snapshot?.hasCommits == true { perform() }
                            }
                        }
                }
                FormRow(label: "Based on") {
                    Picker("", selection: $base) {
                        Text("Current (\(session.snapshot?.branchDisplayName ?? "HEAD"))").tag(String?.none)
                        if !catalog.local.isEmpty {
                            Divider()
                            ForEach(catalog.local.filter { !$0.isCurrent }) { Text($0.name).tag(Optional($0.name)) }
                        }
                        if !catalog.remote.isEmpty {
                            Divider()
                            ForEach(catalog.remote) { Text($0.name).tag(Optional($0.name)) }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                FormRow(label: "") {
                    Toggle("Switch to the new branch", isOn: $switchToBranch)
                        .toggleStyle(.checkbox)
                }
            }

            Spacer(minLength: 0)

            DialogFooter(session: session) {
                if let nameProblem, !name.isEmpty {
                    Text(nameProblem).font(.callout).foregroundStyle(.secondary)
                }
                Button("Create Branch", action: perform)
                    .keyboardShortcut(.defaultAction)
                    .disabled(nameProblem != nil || session.snapshot?.hasCommits != true)
            }
        }
        .task {
            isNameFocused = true
            await catalog.load(session)
        }
        .task(id: name) {
            guard let service = session.service, let root = session.root else { return }
            try? await Task.sleep(for: .milliseconds(200))
            nameProblem = await service.branchNameProblem(name, in: root)
        }
    }

    private func perform() {
        guard let service = session.service, let root = session.root else { return }
        let name = name.trimmingCharacters(in: .whitespaces)
        let base = base
        let switchToBranch = switchToBranch
        Task {
            await session.run("Creating \(name)…", success: switchToBranch ? "Created and Switched to \(name)" : "Created \(name)", followUps: [
                CommandFollowUp(title: "Push…", systemImage: "arrow.up.circle") {
                    session.openCommand(.push, paths: [root.path])
                    session.close()
                },
            ]) {
                try await service.createBranch(named: name, from: base, switchToBranch: switchToBranch, in: root)
            }
        }
    }
}

// MARK: - Stash

struct StashSaveDialog: View {
    let session: CommandSession

    @State private var message = ""
    @State private var includeUntracked = false

    private var changes: [GitFileStatus] {
        session.snapshot?.files ?? []
    }

    private var canStash: Bool {
        includeUntracked ? !changes.isEmpty : changes.contains { !$0.isUntracked }
    }

    var body: some View {
        VStack(spacing: 0) {
            DialogHeader(session: session, subtitle: session.snapshot?.name)
            Divider()

            DialogForm {
                FormRow(label: "Message") {
                    TextField("Optional description", text: $message)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if canStash { perform() } }
                }
                FormRow(label: "") {
                    Toggle("Include untracked files", isOn: $includeUntracked)
                        .toggleStyle(.checkbox)
                }
            }

            Text("Stashing saves all local changes in the repository and resets the working tree to the last commit. Use Stash Pop to bring them back.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            DialogFooter(session: session) {
                if !canStash {
                    Text("There are no local changes to stash.").font(.callout).foregroundStyle(.secondary)
                }
                Button("Stash", action: perform)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStash)
            }
        }
    }

    private func perform() {
        guard let service = session.service, let root = session.root else { return }
        let message = message
        let includeUntracked = includeUntracked
        Task {
            await session.run("Stashing changes…", success: "Changes Stashed", followUps: [
                CommandFollowUp(title: "Stash List…", systemImage: "tray.full") {
                    session.openCommand(.stashPop, paths: [root.path])
                    session.close()
                },
            ]) {
                try await service.stashSave(message: message, includeUntracked: includeUntracked, in: root)
            }
        }
    }
}

struct StashListDialog: View {
    let session: CommandSession

    @State private var stashes: [GitStash]?
    @State private var selection: GitStash.ID?
    @State private var isConfirmingDrop = false

    private var selected: GitStash? {
        stashes?.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            DialogHeader(session: session, subtitle: session.snapshot?.name)
            Divider()

            if let stashes, stashes.isEmpty {
                ContentUnavailableView("No Stashes", systemImage: "tray", description: Text("Use Stash Changes to set local changes aside."))
                    .frame(maxHeight: .infinity)
            } else if let stashes {
                List(stashes, selection: $selection) { stash in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(stash.message)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            Text(stash.ref).font(.caption.monospaced())
                            if let date = stash.date {
                                Text(GitDateFormatter.short(date)).font(.caption)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(stash.id)
                }
                .listStyle(.inset)
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }

            DialogFooter(session: session) {
                Button("Drop…", role: .destructive) { isConfirmingDrop = true }
                    .disabled(selected == nil)
                Button("Apply") { apply(pop: false) }
                    .disabled(selected == nil)
                Button("Pop") { apply(pop: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
        }
        .task { await load() }
        .confirmationDialog("Drop \(selected?.ref ?? "stash")?", isPresented: $isConfirmingDrop) {
            Button("Drop", role: .destructive) { drop() }
        } message: {
            Text("The stashed changes will be permanently deleted.")
        }
    }

    private func load() async {
        guard let service = session.service, let root = session.root else { return }
        stashes = (try? await service.stashes(in: root)) ?? []
        if selection == nil {
            selection = stashes?.first?.id
        }
    }

    private func apply(pop: Bool) {
        guard let service = session.service, let root = session.root, let selected else { return }
        Task {
            await session.run(pop ? "Popping \(selected.ref)…" : "Applying \(selected.ref)…", success: pop ? "Stash Popped" : "Stash Applied") {
                try await service.stashApply(selected, pop: pop, in: root)
            }
        }
    }

    private func drop() {
        guard let service = session.service, let root = session.root, let selected else { return }
        Task {
            await session.run("Dropping \(selected.ref)…", success: "Stash Dropped") {
                try await service.stashDrop(selected, in: root)
            }
        }
    }
}

// MARK: - Clone

struct CloneDialog: View {
    let session: CommandSession

    @State private var url = ""
    @State private var parentFolder: URL?
    @State private var folderName = ""
    @State private var folderNameEdited = false
    @State private var branch = ""
    @State private var recurseSubmodules = false
    @FocusState private var isURLFocused: Bool

    private var destination: URL? {
        guard let parentFolder, !folderName.isEmpty else { return nil }
        return parentFolder.appendingPathComponent(folderName, isDirectory: true)
    }

    private var problem: String? {
        if url.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the repository URL." }
        guard let destination else { return "Choose where to clone." }
        if FileManager.default.fileExists(atPath: destination.path),
           (try? FileManager.default.contentsOfDirectory(atPath: destination.path))?.isEmpty == false {
            return "“\(folderName)” already exists and is not empty."
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            DialogHeader(session: session, subtitle: "Into \(parentFolder?.abbreviatedPath ?? "")")
            Divider()

            DialogForm {
                FormRow(label: "URL") {
                    TextField("https://github.com/owner/repo.git", text: $url)
                        .textFieldStyle(.roundedBorder)
                        .focused($isURLFocused)
                        .onSubmit { if problem == nil { perform() } }
                }
                FormRow(label: "Directory") {
                    HStack {
                        Text(parentFolder?.abbreviatedPath ?? "")
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Text("/").foregroundStyle(.secondary)
                        TextField("folder", text: Binding(
                            get: { folderName },
                            set: { folderName = $0; folderNameEdited = true }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Button("Choose…", action: chooseParent)
                    }
                }
                FormRow(label: "Branch") {
                    TextField("Default branch", text: $branch)
                        .textFieldStyle(.roundedBorder)
                }
                FormRow(label: "") {
                    Toggle("Clone submodules too", isOn: $recurseSubmodules)
                        .toggleStyle(.checkbox)
                }
            }

            Text("Private repositories use your saved Git credentials (Keychain or SSH agent).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            DialogFooter(session: session) {
                if let problem, !url.isEmpty {
                    Text(problem).font(.callout).foregroundStyle(.secondary)
                }
                Button("Clone", action: perform)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
        }
        .onAppear {
            parentFolder = session.targetFolder
            if let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               Self.looksLikeRepositoryURL(text) {
                url = text
            }
            isURLFocused = true
        }
        .onChange(of: url) { _, newValue in
            if !folderNameEdited {
                folderName = Self.folderName(for: newValue)
            }
        }
    }

    static func looksLikeRepositoryURL(_ text: String) -> Bool {
        !text.contains(" ") && !text.contains("\n")
            && (text.hasPrefix("https://") || text.hasPrefix("http://") || text.hasPrefix("git@") || text.hasPrefix("ssh://"))
    }

    static func folderName(for url: String) -> String {
        var name = url.trimmingCharacters(in: .whitespaces)
        while name.hasSuffix("/") { name.removeLast() }
        name = String(name.split(whereSeparator: { $0 == "/" || $0 == ":" }).last ?? "")
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = parentFolder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let chosen = panel.url {
            parentFolder = chosen
        }
    }

    private func perform() {
        guard let service = session.service, let destination else { return }
        let url = url.trimmingCharacters(in: .whitespaces)
        let branch = branch.trimmingCharacters(in: .whitespaces)
        let recurseSubmodules = recurseSubmodules
        Task {
            await session.run("Cloning \(Self.folderName(for: url))…", success: "Cloned \(destination.lastPathComponent)", followUps: [
                CommandFollowUp(title: "Open in GitView", systemImage: "macwindow") {
                    session.openInMainWindow(destination)
                    session.close()
                },
                CommandFollowUp(title: "Reveal in Finder", systemImage: "folder") {
                    ExternalApps.revealInFinder(destination)
                },
            ]) {
                try await service.clone(url: url, into: destination, branch: branch.isEmpty ? nil : branch, recurseSubmodules: recurseSubmodules)
            }
        }
    }
}

// MARK: - Create Repository

struct CreateRepositoryDialog: View {
    let session: CommandSession

    private var folder: URL { session.targetFolder }

    private var alreadyRepository: Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path)
    }

    var body: some View {
        VStack(spacing: 0) {
            DialogHeader(session: session, subtitle: folder.abbreviatedPath)
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text(folder.abbreviatedPath)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "folder.fill").foregroundStyle(.tint)
                }
                .font(.title3)

                Text(alreadyRepository
                     ? "This folder is already a Git repository."
                     : "Git will start tracking this folder. Nothing is committed yet; existing files appear as unversioned so you can add and commit them.")
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            DialogFooter(session: session) {
                Button("Create Repository", action: perform)
                    .keyboardShortcut(.defaultAction)
                    .disabled(alreadyRepository)
            }
        }
    }

    private func perform() {
        guard let service = session.service else { return }
        let folder = folder
        Task {
            await session.run("Creating repository…", success: "Repository Created", followUps: [
                CommandFollowUp(title: "Commit…", systemImage: "checkmark.circle") {
                    session.openCommand(.commit, paths: [folder.path])
                    session.close()
                },
                CommandFollowUp(title: "Open in GitView", systemImage: "macwindow") {
                    session.openInMainWindow(folder)
                    session.close()
                },
            ]) {
                try await service.initRepository(at: folder)
            }
        }
    }
}
