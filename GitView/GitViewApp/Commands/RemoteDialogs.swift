import SwiftUI
#if canImport(Shared)
import Shared
#endif

// MARK: - Shared pieces

/// Text field with a drop-down of suggestions (branch names).
struct SuggestionField: View {
    let placeholder: String
    @Binding var text: String
    let suggestions: [String]

    /// Names containing the typed words (all names while the field is empty or
    /// already holds a full name), so long lists stay usable.
    private var shown: [String] {
        let query = text.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty || suggestions.contains(query)
            ? suggestions
            : suggestions.filter { BranchSearch.matches($0, query: query) }
        return Array(matching.prefix(100))
    }

    var body: some View {
        HStack(spacing: 4) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
            Menu {
                ForEach(shown, id: \.self) { name in
                    Button(name) { text = name }
                }
                if shown.isEmpty {
                    Text("No branches contain “\(text)”")
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(suggestions.isEmpty)
        }
    }
}

/// Titled list of commits, used for incoming (pull) and outgoing (push) commits.
struct CommitPreviewList: View {
    let title: String
    let commits: [GitCommit]?
    let emptyText: String
    var isLoading = false
    var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let commits, !commits.isEmpty {
                    Text("\(commits.count)\(commits.count >= 200 ? "+" : "")")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()

            Group {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let commits, !commits.isEmpty {
                    List(commits) { commit in
                        CommitRow(commit: commit)
                    }
                    .listStyle(.inset)
                } else if commits != nil {
                    Text(emptyText)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color.clear
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// Label column + control column form layout.
struct DialogForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            content
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

struct FormRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Branch names of the repository, loaded once per dialog.
@MainActor
@Observable
final class BranchCatalog {
    private(set) var local: [GitBranch] = []
    private(set) var remote: [GitBranch] = []

    func load(_ session: CommandSession) async {
        guard let service = session.service, let root = session.root, let branches = try? await service.branches(in: root) else {
            return
        }
        local = branches.filter { !$0.isRemote }
        remote = branches.filter(\.isRemote)
    }

    /// Branch names on the server, including ones not fetched yet, per remote.
    private(set) var serverNames: [String: [String]] = [:]

    /// Fetched branches first, then the rest of the server's branches.
    func remoteBranchNames(on remoteName: String) -> [String] {
        let fetched = remote.filter { $0.remoteName == remoteName }.map(\.localTrackingName)
        let known = Set(fetched)
        let others = (serverNames[remoteName] ?? [])
            .filter { !known.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return fetched + others
    }

    /// Lists the server's branches (cached), for suggestions; failures are ignored.
    func loadServerBranches(_ session: CommandSession, remote remoteName: String) async {
        guard !remoteName.isEmpty, serverNames[remoteName] == nil, let service = session.service, let root = session.root,
              let names = try? await RemoteBranchDirectory.shared.branchNames(remote: remoteName, in: root, service: service) else {
            return
        }
        serverNames[remoteName] = names
    }
}

private extension GitRepositorySnapshot {
    /// ("origin", "main") from an upstream like "origin/main".
    var upstreamParts: (remote: String, branch: String)? {
        guard let upstreamBranch else { return nil }
        let remote = remotes.first { upstreamBranch.hasPrefix($0 + "/") }
        guard let remote else { return nil }
        return (remote, String(upstreamBranch.dropFirst(remote.count + 1)))
    }
}

// MARK: - Pull

struct PullDialog: View {
    let session: CommandSession

    @State private var remote = ""
    @State private var branch = ""
    @State private var strategy: GitPullStrategy = .merge
    @State private var catalog = BranchCatalog()
    @State private var incoming: [GitCommit]?
    @State private var preview: GitPullPreview?
    @State private var previewError: String?
    @State private var isLoadingPreview = false
    @State private var didInitialize = false

    private var snapshot: GitRepositorySnapshot? { session.snapshot }

    private var problem: String? {
        guard let snapshot else { return nil }
        if snapshot.remotes.isEmpty { return "This repository has no remotes." }
        if snapshot.isDetachedHead { return "Switch to a branch before pulling." }
        if branch.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the remote branch to pull." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            DialogHeader(session: session, subtitle: "Pull into \(snapshot?.branchDisplayName ?? "")")
            Divider()

            DialogForm {
                FormRow(label: "Remote") {
                    Picker("", selection: $remote) {
                        ForEach(snapshot?.remotes ?? [], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                FormRow(label: "Remote branch") {
                    SuggestionField(placeholder: "main", text: $branch, suggestions: catalog.remoteBranchNames(on: remote))
                }
                FormRow(label: "Integrate by") {
                    Picker("", selection: $strategy) {
                        ForEach(GitPullStrategy.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }

            if let preview, preview.hasPossibleConflicts {
                Label(
                    "Possible conflicts with your local changes: \(preview.possibleConflictFiles.prefix(5).joined(separator: ", "))\(preview.possibleConflictFiles.count > 5 ? "…" : "")",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let preview, preview.isDiverged {
                Label("Your branch has \(preview.aheadCount) local commits that are not on \(preview.target); Git will \(strategy == .rebase ? "replay them on top" : strategy == .merge ? "create a merge commit" : "refuse to pull").", systemImage: "arrow.triangle.merge")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            CommitPreviewList(
                title: "Incoming Commits",
                commits: incoming,
                emptyText: "Already up to date with \(remote)/\(branch).",
                isLoading: isLoadingPreview,
                error: previewError
            )

            DialogFooter(session: session) {
                if let problem {
                    Text(problem).font(.callout).foregroundStyle(.secondary)
                }
                Button("Fetch & Preview") { Task { await loadPreview() } }
                    .disabled(problem != nil || isLoadingPreview)
                Button("Pull", action: pull)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
        }
        .task {
            guard !didInitialize, let snapshot else { return }
            didInitialize = true
            if let upstream = snapshot.upstreamParts {
                remote = upstream.remote
                branch = upstream.branch
            } else {
                remote = snapshot.defaultRemote ?? ""
                branch = snapshot.isDetachedHead ? "" : snapshot.branch
            }
            await catalog.load(session)
            await loadPreview()
            await catalog.loadServerBranches(session, remote: remote)
        }
    }

    private func loadPreview() async {
        guard problem == nil, let service = session.service, let snapshot else { return }
        let root = snapshot.rootPath
        let ref = "\(remote)/\(branch)"
        isLoadingPreview = true
        previewError = nil
        defer { isLoadingPreview = false }
        do {
            preview = try await service.pullPreview(sourceBranch: ref, localFiles: snapshot.files, remote: remote, in: root)
            // The preview fetched exactly this branch into FETCH_HEAD.
            incoming = try await service.commits(inRange: "HEAD..FETCH_HEAD", in: root)
        } catch {
            preview = nil
            incoming = nil
            previewError = error.localizedDescription
        }
    }

    private func pull() {
        guard let service = session.service, let root = session.root else { return }
        let ref = "\(remote)/\(branch)"
        let remote = remote
        let strategy = strategy
        Task {
            await session.run("Pulling \(ref)…", success: "Pulled \(ref)", followUps: [
                CommandFollowUp(title: "Show Log", systemImage: "clock.arrow.circlepath") {
                    session.openCommand(.log, paths: [root.path])
                },
            ]) {
                try await service.pull(sourceBranch: ref, strategy: strategy, remote: remote, in: root)
            }
        }
    }
}

// MARK: - Fetch

struct FetchDialog: View {
    let session: CommandSession

    private static let allRemotes = "\u{0}all"

    @State private var remote = ""
    @State private var prune = true
    @State private var tags = false

    var body: some View {
        VStack(spacing: 0) {
            DialogHeader(session: session)
            Divider()

            DialogForm {
                FormRow(label: "From") {
                    Picker("", selection: $remote) {
                        ForEach(session.snapshot?.remotes ?? [], id: \.self) { Text($0).tag($0) }
                        if (session.snapshot?.remotes.count ?? 0) > 1 {
                            Divider()
                            Text("All Remotes").tag(Self.allRemotes)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                FormRow(label: "Options") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Prune branches deleted on the remote", isOn: $prune)
                        Toggle("Fetch all tags", isOn: $tags)
                    }
                    .toggleStyle(.checkbox)
                }
            }

            Text("Fetching downloads new commits and branches without changing your files.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            DialogFooter(session: session) {
                if session.snapshot?.remotes.isEmpty == true {
                    Text("This repository has no remotes.").font(.callout).foregroundStyle(.secondary)
                }
                Button("Fetch", action: fetch)
                    .keyboardShortcut(.defaultAction)
                    .disabled(remote.isEmpty)
            }
        }
        .onAppear {
            if remote.isEmpty {
                remote = session.snapshot?.defaultRemote ?? ""
            }
        }
    }

    private func fetch() {
        guard let service = session.service, let root = session.root else { return }
        let remote = remote == Self.allRemotes ? nil : remote
        let prune = prune
        let tags = tags
        Task {
            await session.run("Fetching from \(remote ?? "all remotes")…", success: "Fetched from \(remote ?? "all remotes")", followUps: [
                CommandFollowUp(title: "Pull…", systemImage: "arrow.down.circle") {
                    session.openCommand(.pull, paths: [root.path])
                    session.close()
                },
                CommandFollowUp(title: "Show Log", systemImage: "clock.arrow.circlepath") {
                    session.openCommand(.log, paths: [root.path])
                },
            ]) {
                try await service.fetch(remote: remote, prune: prune, tags: tags, in: root)
            }
        }
    }
}

// MARK: - Push

struct PushDialog: View {
    let session: CommandSession

    @State private var localBranch = ""
    @State private var remote = ""
    @State private var remoteBranch = ""
    @State private var setUpstream = false
    @State private var forceWithLease = false
    @State private var includeTags = false
    @State private var catalog = BranchCatalog()
    @State private var outgoing: [GitCommit]?
    @State private var isNewRemoteBranch = false
    @State private var isLoadingOutgoing = false
    @State private var didInitialize = false

    private var problem: String? {
        guard let snapshot = session.snapshot else { return nil }
        if snapshot.remotes.isEmpty { return "This repository has no remotes." }
        if !snapshot.hasCommits { return "Commit something before pushing." }
        if localBranch.isEmpty { return "Choose a local branch." }
        if remoteBranch.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the remote branch name." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            DialogHeader(session: session)
            Divider()

            DialogForm {
                FormRow(label: "Local branch") {
                    Picker("", selection: $localBranch) {
                        ForEach(catalog.local) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                FormRow(label: "Remote") {
                    Picker("", selection: $remote) {
                        ForEach(session.snapshot?.remotes ?? [], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                FormRow(label: "Remote branch") {
                    SuggestionField(placeholder: localBranch, text: $remoteBranch, suggestions: catalog.remoteBranchNames(on: remote))
                }
                FormRow(label: "Options") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Set as upstream (track this remote branch)", isOn: $setUpstream)
                        Toggle("Force (with lease) — overwrite remote changes", isOn: $forceWithLease)
                        Toggle("Include annotated tags", isOn: $includeTags)
                    }
                    .toggleStyle(.checkbox)
                }
            }

            if isNewRemoteBranch, outgoing != nil {
                Label("\(remote)/\(remoteBranch) does not exist yet; it will be created.", systemImage: "sparkles")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            CommitPreviewList(
                title: isNewRemoteBranch ? "Commits on \(localBranch)" : "Outgoing Commits",
                commits: outgoing,
                emptyText: "\(remote)/\(remoteBranch) already has every commit on \(localBranch).",
                isLoading: isLoadingOutgoing
            )

            DialogFooter(session: session) {
                if let problem {
                    Text(problem).font(.callout).foregroundStyle(.secondary)
                }
                Button(forceWithLease ? "Force Push" : "Push", action: push)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
        }
        .task {
            guard !didInitialize, let snapshot = session.snapshot else { return }
            didInitialize = true
            await catalog.load(session)
            localBranch = snapshot.isDetachedHead ? (catalog.local.first?.name ?? "") : snapshot.branch
            applyDefaults(for: localBranch)
            await loadOutgoing()
            await catalog.loadServerBranches(session, remote: remote)
        }
        .onChange(of: localBranch) { old, new in
            if !old.isEmpty { applyDefaults(for: new) }
        }
        .task(id: "\(localBranch)|\(remote)|\(remoteBranch)") {
            guard didInitialize else { return }
            try? await Task.sleep(for: .milliseconds(250))
            await loadOutgoing()
        }
    }

    /// Remote and remote branch from the branch's upstream, else same name on the default remote.
    private func applyDefaults(for branchName: String) {
        let branch = catalog.local.first { $0.name == branchName }
        let snapshot = session.snapshot
        if let upstream = branch?.upstream, let upstreamRemote = snapshot?.remotes.first(where: { upstream.hasPrefix($0 + "/") }) {
            remote = upstreamRemote
            remoteBranch = String(upstream.dropFirst(upstreamRemote.count + 1))
            setUpstream = false
        } else {
            remote = snapshot?.defaultRemote ?? ""
            remoteBranch = branchName
            setUpstream = true
        }
    }

    private func loadOutgoing() async {
        guard let service = session.service, let root = session.root, !localBranch.isEmpty, !remote.isEmpty, !remoteBranch.isEmpty else {
            outgoing = nil
            return
        }
        isLoadingOutgoing = true
        defer { isLoadingOutgoing = false }
        let remoteRef = "refs/remotes/\(remote)/\(remoteBranch)"
        let exists = await service.refExists(remoteRef, in: root)
        isNewRemoteBranch = !exists
        let range = exists ? "\(remoteRef)..refs/heads/\(localBranch)" : "refs/heads/\(localBranch)"
        outgoing = try? await service.commits(inRange: range, limit: exists ? 200 : 50, in: root)
    }

    private func push() {
        guard let service = session.service, let root = session.root else { return }
        let localBranch = localBranch
        let remote = remote
        let remoteBranch = remoteBranch.trimmingCharacters(in: .whitespaces)
        let setUpstream = setUpstream
        let forceWithLease = forceWithLease
        let includeTags = includeTags
        Task {
            await session.run("Pushing \(localBranch) to \(remote)/\(remoteBranch)…", success: "Pushed to \(remote)/\(remoteBranch)") {
                try await service.push(
                    localBranch: localBranch,
                    remote: remote,
                    remoteBranch: remoteBranch,
                    setUpstream: setUpstream,
                    forceWithLease: forceWithLease,
                    includeTags: includeTags,
                    in: root
                )
            }
        }
    }
}
