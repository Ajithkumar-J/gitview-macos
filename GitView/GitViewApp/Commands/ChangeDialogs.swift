import SwiftUI
#if canImport(Shared)
import Shared
#endif

// MARK: - Commit

/// TortoiseGit-style commit dialog: message, checked files, diff preview.
/// Exactly the checked files are committed, as they are on disk.
struct CommitDialog: View {
    let session: CommandSession

    @State private var message = ""
    @State private var amend = false
    @State private var messageBeforeAmend = ""
    @State private var showUnversioned = true
    @State private var checked = Set<GitFileStatus.ID>()
    @State private var selection: GitFileStatus.ID?
    @State private var didInitialize = false
    @State private var diff = FileDiffLoader()
    @State private var hasIdentity = true
    @FocusState private var isMessageFocused: Bool

    private var files: [GitFileStatus] {
        session.scopedFiles.filter { showUnversioned || !$0.isUntracked }
    }

    private var checkedFiles: [GitFileStatus] {
        files.filter { checked.contains($0.id) }
    }

    private var selectedFile: GitFileStatus? {
        files.first { $0.id == selection }
    }

    private var disabledReason: String? {
        if !hasIdentity {
            return "Enter your name and email first."
        }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a commit message."
        }
        if checkedFiles.isEmpty, !amend {
            return "Select the files to commit."
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            DialogHeader(session: session)
            Divider()

            IdentitySetupView(service: session.service, repositoryURL: session.root, isConfigured: $hasIdentity,
                              padding: EdgeInsets(top: 14, leading: 14, bottom: 0, trailing: 14))

            VSplitView {
                messageEditor
                    .frame(minHeight: 140, idealHeight: 170)
                fileList
                    .frame(minHeight: 150, idealHeight: 250)
                DiffPane(path: selectedFile?.path, originalPath: selectedFile?.originalPath, subtitle: selectedFile?.combinedKind.title, state: diff.state)
                    .frame(minHeight: 100, idealHeight: 220)
            }

            DialogFooter(session: session) {
                if let disabledReason {
                    Text(disabledReason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Commit & Push") { commit(andPush: true) }
                    .disabled(disabledReason != nil || session.snapshot?.remotes.isEmpty != false)
                Button(amend ? "Amend" : "Commit") { commit(andPush: false) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(disabledReason != nil)
            }
        }
        .onAppear(perform: initialize)
        .onChange(of: session.snapshot?.files) { _, _ in
            // Keep choices for files that are still changed; check new tracked files.
            let ids = Set(files.map(\.id))
            checked.formIntersection(ids)
        }
        .onChange(of: selection) { _, _ in diff.load(selectedFile, session: session) }
        .onChange(of: amend) { _, isAmending in
            Task { await toggleAmend(isAmending) }
        }
    }

    private var messageEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Message")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Amend last commit", isOn: $amend)
                    .toggleStyle(.checkbox)
                    .disabled(session.snapshot?.hasCommits != true)
            }

            TextEditor(text: $message)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .overlay(alignment: .topLeading) {
                    if message.isEmpty {
                        Text("Summary of the change\n\nOptional longer description")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .focused($isMessageFocused)
        }
        .padding(14)
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            Divider()
            ChecklistSelectionBar(files: files, checked: $checked, showUnversioned: $showUnversioned)
            Divider()
            if files.isEmpty {
                ContentUnavailableView(
                    amend ? "No New Changes" : "Nothing to Commit",
                    systemImage: "checkmark.seal",
                    description: Text(amend ? "Amending changes only the message of the last commit." : "There are no local changes in \(session.scopeDescription).")
                )
                .frame(maxHeight: .infinity)
            } else {
                FileChecklist(
                    session: session,
                    files: files,
                    checked: $checked,
                    selection: $selection,
                    isCheckable: { !$0.isConflicted }
                )
            }
        }
    }

    private func initialize() {
        guard !didInitialize else { return }
        didInitialize = true
        // Tracked changes start checked; new files only when they were right-clicked.
        let explicit = Set(session.scopePaths)
        checked = Set(files.filter { file in
            !file.isConflicted && (!file.isUntracked || explicit.contains(file.path))
        }.map(\.id))
        selection = files.first?.id
        isMessageFocused = true
    }

    private func toggleAmend(_ isAmending: Bool) async {
        guard let service = session.service, let root = session.root else { return }
        if isAmending {
            messageBeforeAmend = message
            if message.isEmpty, let last = try? await service.lastCommitMessage(in: root) {
                message = last
            }
        } else {
            message = messageBeforeAmend
        }
    }

    private func commit(andPush: Bool) {
        guard let service = session.service, let snapshot = session.snapshot else { return }
        let root = snapshot.rootPath
        let files = checkedFiles
        let message = message
        let amend = amend

        Task {
            var commitText = ""
            let committed = await session.run(
                amend ? "Amending last commit…" : "Committing \(files.count == 1 ? "1 file" : "\(files.count) files")…",
                success: amend ? "Commit Amended" : "Committed",
                followUps: [
                    CommandFollowUp(title: "Push…", systemImage: "arrow.up.circle") {
                        session.openCommand(.push, paths: [root.path])
                        session.close()
                    },
                    CommandFollowUp(title: "Show Log", systemImage: "clock.arrow.circlepath") {
                        session.openCommand(.log, paths: [root.path])
                    },
                ]
            ) {
                let outcome = try await service.commit(message: message, files: files, amend: amend, in: root)
                commitText = outcome.output
                return commitText
            }

            guard committed, andPush else { return }
            await session.run("Pushing to \(snapshot.upstreamBranch ?? snapshot.defaultRemote ?? "remote")…", success: "Committed and Pushed", failure: "Committed, but Push Failed") {
                let pushOutput: String
                if snapshot.upstreamBranch != nil {
                    pushOutput = try await service.push(in: root)
                } else {
                    pushOutput = try await service.pushSetUpstream(branch: snapshot.branch, remote: snapshot.defaultRemote, in: root)
                }
                return commitText + "\n\n" + pushOutput
            }
        }
    }
}

// MARK: - Check for Modifications / Diff

/// Changed files with an inline diff. "Diff" on a single file shows just the diff.
struct StatusDialog: View {
    let session: CommandSession

    @State private var selection: GitFileStatus.ID?
    @State private var showUnversioned = true
    @State private var diff = FileDiffLoader()
    @State private var noChecks = Set<GitFileStatus.ID>()

    private var files: [GitFileStatus] {
        session.scopedFiles.filter { showUnversioned || !$0.isUntracked }
    }

    private var selectedFile: GitFileStatus? {
        files.first { $0.id == selection }
    }

    private var isSingleFileDiff: Bool {
        session.action == .diff && files.count == 1
    }

    var body: some View {
        VStack(spacing: 0) {
            DialogHeader(session: session) {
                HStack {
                    if !isSingleFileDiff {
                        Toggle("Show unversioned files", isOn: $showUnversioned)
                            .toggleStyle(.checkbox)
                    }
                    Button {
                        Task { await session.reload() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r")
                }
            }
            Divider()

            if files.isEmpty {
                ContentUnavailableView(
                    "No Local Changes",
                    systemImage: "checkmark.seal",
                    description: Text("\(session.scopeDescription) matches the last commit.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isSingleFileDiff {
                diffPane
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        FileChecklist(session: session, files: files, checked: $noChecks, selection: $selection, showsCheckboxes: false)
                        Divider()
                        Text("\(files.count) changed \(files.count == 1 ? "file" : "files")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(6)
                    }
                    .frame(minWidth: 260, idealWidth: 340, maxWidth: 520)
                    diffPane
                        .frame(minWidth: 360)
                }
            }

            DialogFooter(session: session, cancelTitle: "Close") {
                Button("Revert…") { session.openCommand(.revert) }
                    .disabled(!files.contains { !$0.isUntracked })
                Button("Add…") { session.openCommand(.add) }
                    .disabled(!files.contains(where: \.isUntracked))
                Button("Commit…") {
                    session.openCommand(.commit)
                    session.close()
                }
                .buttonStyle(.borderedProminent)
                .disabled(files.isEmpty)
            }
        }
        .onAppear {
            if selection == nil {
                selection = files.first?.id
            }
            diff.load(selectedFile, session: session)
        }
        .onChange(of: selection) { _, _ in diff.load(selectedFile, session: session) }
        .onChange(of: session.snapshot?.files) { _, _ in
            if selectedFile == nil {
                selection = files.first?.id
            }
            diff.load(selectedFile, session: session)
        }
        .onReceive(NotificationCenter.default.publisher(for: .gitViewRepositoryDidChange)) { _ in
            Task { await session.reload() }
        }
    }

    private var diffPane: some View {
        DiffPane(
            path: selectedFile?.path,
            originalPath: selectedFile?.originalPath,
            subtitle: selectedFile.map { "\($0.combinedKind.title) · working tree compared with HEAD" },
            state: diff.state
        )
    }
}

// MARK: - Add / Revert

struct FileActionDialog: View {
    enum Kind {
        case add
        case revert
    }

    let session: CommandSession
    let kind: Kind

    @State private var checked = Set<GitFileStatus.ID>()
    @State private var selection: GitFileStatus.ID?
    @State private var didInitialize = false
    @State private var isConfirmingRevert = false

    private var files: [GitFileStatus] {
        switch kind {
        case .add: session.scopedFiles.filter(\.isUntracked)
        case .revert: session.scopedFiles.filter { !$0.isUntracked }
        }
    }

    private var checkedFiles: [GitFileStatus] {
        files.filter { checked.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            DialogHeader(session: session)
            Divider()
            Text(kind == .add
                 ? "Choose the new files to add to Git. They will be included in the next commit."
                 : "Choose the files to revert. All local changes to them, staged or not, are thrown away.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            ChecklistSelectionBar(files: files, checked: $checked)
            Divider()

            if files.isEmpty {
                ContentUnavailableView(
                    kind == .add ? "No Unversioned Files" : "Nothing to Revert",
                    systemImage: "checkmark.seal",
                    description: Text("There are no \(kind == .add ? "new" : "changed") files in \(session.scopeDescription).")
                )
                .frame(maxHeight: .infinity)
            } else {
                FileChecklist(session: session, files: files, checked: $checked, selection: $selection)
            }

            DialogFooter(session: session) {
                Button(kind == .add ? "Add" : "Revert…", role: kind == .revert ? .destructive : nil) {
                    if kind == .revert {
                        isConfirmingRevert = true
                    } else {
                        perform()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(checkedFiles.isEmpty)
            }
        }
        .onAppear {
            guard !didInitialize else { return }
            didInitialize = true
            checked = Set(files.map(\.id))
        }
        .confirmationDialog(
            "Revert \(checkedFiles.count == 1 ? "1 file" : "\(checkedFiles.count) files")?",
            isPresented: $isConfirmingRevert
        ) {
            Button("Revert", role: .destructive, action: perform)
        } message: {
            Text("Local changes to these files will be permanently lost.")
        }
    }

    private func perform() {
        guard let service = session.service, let root = session.root else { return }
        let files = checkedFiles
        Task {
            switch kind {
            case .add:
                await session.run("Adding files…", success: "Files Added", followUps: [
                    CommandFollowUp(title: "Commit…", systemImage: "checkmark.circle") {
                        session.openCommand(.commit)
                        session.close()
                    },
                ]) {
                    let output = try await service.add(paths: files.map(\.path), in: root)
                    return output + "\n\n" + files.map { "added  \($0.path)" }.joined(separator: "\n")
                }
            case .revert:
                await session.run("Reverting files…", success: "Files Reverted") {
                    let output = try await service.revert(files, in: root)
                    return output + "\n\n" + files.map { "reverted  \($0.path)" }.joined(separator: "\n")
                }
            }
        }
    }
}
