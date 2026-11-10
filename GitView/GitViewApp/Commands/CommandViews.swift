import AppKit
import SwiftUI
#if canImport(Shared)
import Shared
#endif

/// Button offered on the result screen, e.g. "Push…" after a commit.
struct CommandFollowUp: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let perform: @MainActor () -> Void
}

// MARK: - Root

/// Root of every command window: resolves the repository, then shows the
/// command's dialog, a progress overlay while Git runs, and finally the result.
struct CommandRootView: View {
    @Bindable var session: CommandSession

    var body: some View {
        Group {
            switch session.phase {
            case .resolving:
                ProgressView("Opening repository…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                NotARepositoryView(session: session, message: message)
            case .ready:
                if let result = session.result {
                    CommandResultView(session: session, result: result)
                } else {
                    dialog
                        .disabled(session.isRunning)
                }
            }
        }
        .overlay {
            if let title = session.runningTitle {
                RunningOverlay(title: title)
            }
        }
        .frame(minWidth: 460, minHeight: 300)
    }

    @ViewBuilder
    private var dialog: some View {
        switch session.action {
        case .commit: CommitDialog(session: session)
        case .status, .diff: StatusDialog(session: session)
        case .add: FileActionDialog(session: session, kind: .add)
        case .revert: FileActionDialog(session: session, kind: .revert)
        case .log: LogDialog(session: session)
        case .pull: PullDialog(session: session)
        case .fetch: FetchDialog(session: session)
        case .push: PushDialog(session: session)
        case .switchBranch: SwitchBranchDialog(session: session)
        case .createBranch: CreateBranchDialog(session: session)
        case .stash: StashSaveDialog(session: session)
        case .stashPop: StashListDialog(session: session)
        case .clone: CloneDialog(session: session)
        case .createRepository: CreateRepositoryDialog(session: session)
        case .open: EmptyView()
        }
    }
}

private struct RunningOverlay: View {
    let title: String

    var body: some View {
        ZStack {
            Rectangle().fill(.background.opacity(0.55))
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(title)
                    .font(.headline)
                Text("Waiting for Git…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .transition(.opacity)
    }
}

private struct NotARepositoryView: View {
    let session: CommandSession
    let message: String

    var body: some View {
        VStack(spacing: 0) {
            ContentUnavailableView {
                Label("Not a Git Repository", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                HStack {
                    Button("Create Repository Here…") { switchTo(.createRepository) }
                    Button("Clone…") { switchTo(.clone) }
                }
                .fixedSize()
            }
            .frame(maxHeight: .infinity)
            DialogFooter(session: session) {
                EmptyView()
            }
        }
        .frame(minHeight: 380)
    }

    private func switchTo(_ action: GitViewDeepLink.Action) {
        session.openCommand(action, paths: [session.targetFolder.path])
        session.close()
    }
}

// MARK: - Result

struct CommandResultView: View {
    let session: CommandSession
    let result: CommandResult

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(result.succeeded ? .green : .red)
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.title)
                        .font(.title3.weight(.semibold))
                    Text(session.scopeDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            if let hint = result.hint {
                Label {
                    Text(hint)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.yellow)
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            ScrollView {
                Text(result.output.isEmpty ? "Git reported no output." : DisplayText.visible(result.output))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            HStack {
                if !result.succeeded {
                    Button("Back") { session.result = nil }
                }
                ForEach(session.followUps) { followUp in
                    Button {
                        followUp.perform()
                    } label: {
                        Label(followUp.title, systemImage: followUp.systemImage)
                    }
                }
                Spacer()
                Button("Close") { session.close() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
    }
}

// MARK: - Scaffolding

/// Icon, command name and repository/branch line at the top of a dialog.
struct DialogHeader<Accessory: View>: View {
    let session: CommandSession
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.action.systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(session.action.title)
                    .font(.headline)
                HStack(spacing: 6) {
                    if let snapshot = session.snapshot {
                        Label(snapshot.branchDisplayName, systemImage: "arrow.triangle.branch")
                            .labelStyle(CompactLabelStyle())
                        Text("·")
                    }
                    Text(subtitle ?? session.scopeDescription)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Spacer()
            accessory
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

extension DialogHeader where Accessory == EmptyView {
    init(session: CommandSession, subtitle: String? = nil) {
        self.init(session: session, subtitle: subtitle) { EmptyView() }
    }
}

/// Bottom button row: optional leading content, Cancel, then the primary buttons.
struct DialogFooter<Content: View>: View {
    let session: CommandSession
    var cancelTitle = "Cancel"
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .overlay(alignment: .leading) {
                Button(cancelTitle) { session.close() }
                    .keyboardShortcut(.cancelAction)
                    .padding(.leading, 14)
            }
        }
    }
}

/// Grouped form section with a small caption, used by the simpler dialogs.
struct DialogSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Files

extension GitFileStatus {
    /// One status for the file as a whole, preferring the working-tree side.
    var combinedKind: GitChangeKind {
        if isUntracked { return .untracked }
        if isConflicted { return .conflicted }
        return GitChangeKind(statusCode: workingTreeStatus != " " ? workingTreeStatus : indexStatus)
    }
}

/// File list with optional checkboxes, used by Commit, Add, Revert and Status.
struct FileChecklist: View {
    let session: CommandSession
    let files: [GitFileStatus]
    @Binding var checked: Set<GitFileStatus.ID>
    @Binding var selection: GitFileStatus.ID?
    var showsCheckboxes = true
    var isCheckable: (GitFileStatus) -> Bool = { _ in true }

    var body: some View {
        List(selection: $selection) {
            ForEach(files) { file in
                row(file)
                    .tag(file.id)
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: GitFileStatus.ID.self) { ids in
            if let file = files.first(where: { ids.contains($0.id) }), let root = session.root {
                Button("Diff") { session.openCommand(.diff, paths: [root.appendingPathComponent(file.path).path]) }
                Button("Show Log") { session.openCommand(.log, paths: [root.appendingPathComponent(file.path).path]) }
                Divider()
                Button("Open") { NSWorkspace.shared.open(root.appendingPathComponent(file.path)) }
                Button("Reveal in Finder") { ExternalApps.revealInFinder(root.appendingPathComponent(file.path)) }
                Button("Copy Path") { ExternalApps.copyToPasteboard(file.path) }
            }
        } primaryAction: { ids in
            if let file = files.first(where: { ids.contains($0.id) }), let root = session.root, session.action != .diff, session.action != .status {
                session.openCommand(.diff, paths: [root.appendingPathComponent(file.path).path])
            }
        }
    }

    private func row(_ file: GitFileStatus) -> some View {
        HStack(spacing: 8) {
            if showsCheckboxes {
                Toggle("", isOn: Binding(
                    get: { checked.contains(file.id) },
                    set: { isOn in
                        if isOn { checked.insert(file.id) } else { checked.remove(file.id) }
                    }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!isCheckable(file))
            }
            FileTypeIcon(path: file.path)
            FilePathLabel(path: file.path, originalPath: file.originalPath)
            Spacer(minLength: 8)
            Text(file.combinedKind.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            ChangeKindBadge(kind: file.combinedKind)
        }
        .padding(.vertical, 1)
    }
}

/// "Select: All · None · …" row above a checklist.
struct ChecklistSelectionBar: View {
    let files: [GitFileStatus]
    @Binding var checked: Set<GitFileStatus.ID>
    var showUnversioned: Binding<Bool>?

    var body: some View {
        HStack(spacing: 12) {
            Text("Select:")
                .foregroundStyle(.secondary)
            Button("All") { checked = Set(files.map(\.id)) }
            Button("None") { checked.removeAll() }
            Button("Tracked") { checked = Set(files.filter { !$0.isUntracked }.map(\.id)) }
            Spacer()
            if let showUnversioned {
                Toggle("Show unversioned files", isOn: showUnversioned)
                    .toggleStyle(.checkbox)
            }
            Text("\(checked.count) of \(files.count) selected")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .buttonStyle(.link)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

// MARK: - Diff preview

/// Loads "working tree vs last commit" diffs for the selected file in a dialog.
@MainActor
@Observable
final class FileDiffLoader {
    private(set) var state: DiffState = .placeholder("Select a file to see its changes.")
    @ObservationIgnored private var task: Task<Void, Never>?

    func load(_ file: GitFileStatus?, session: CommandSession) {
        task?.cancel()
        guard let file, let service = session.service, let root = session.root else {
            state = .placeholder("Select a file to see its changes.")
            return
        }

        state = .loading
        task = Task {
            do {
                let text = try await service.diffAgainstHead(file, in: root)
                let diff = await Task.detached(priority: .userInitiated) { GitDiffParser.parse(text) }.value
                guard !Task.isCancelled else { return }
                state = .loaded(diff)
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Identity

/// Asks for a name and email when Git has none, so commits are not recorded
/// under an automatic identity such as "you@Mac.local".
struct IdentitySetupView: View {
    let service: GitService?
    let repositoryURL: URL?
    @Binding var isConfigured: Bool
    /// Space around the banner, applied only while it is shown.
    var padding = EdgeInsets()

    @State private var hasLoaded = false
    @State private var name = ""
    @State private var email = ""
    @State private var errorText: String?
    @State private var isSaving = false

    private var candidate: GitIdentity {
        GitIdentity(name: name, email: email)
    }

    var body: some View {
        // A container that always exists, so the check runs even while nothing is shown.
        VStack(spacing: 0) {
            if hasLoaded, !isConfigured {
                form.padding(padding)
            }
        }
        .task(id: repositoryURL) { await load() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Tell Git who you are", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.headline)
            Text("Every commit records a name and email. Use the email of your GitHub, GitLab or Azure DevOps account so your commits are linked to you. This is saved for all repositories.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Full name", text: $name)
                TextField("Email address", text: $email)
                Button("Save", action: save)
                    .disabled(!candidate.isComplete || isSaving)
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit(save)
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.orange.opacity(0.35)))
    }

    private func load() async {
        guard let service else { return }
        let identity = await service.identity(in: repositoryURL)
        isConfigured = identity.isComplete
        if name.isEmpty {
            name = identity.name.isEmpty ? NSFullUserName() : identity.name
        }
        if email.isEmpty {
            email = identity.email
        }
        hasLoaded = true
    }

    private func save() {
        guard let service, candidate.isComplete, !isSaving else { return }
        isSaving = true
        Task {
            do {
                try await service.saveIdentity(candidate)
                // A repository-level setting can still override the global one.
                isConfigured = await service.identity(in: repositoryURL).isComplete
                errorText = isConfigured ? nil : "This repository's own Git settings override the name or email. Run git config --unset user.email in it."
            } catch {
                errorText = error.localizedDescription
            }
            isSaving = false
        }
    }
}
