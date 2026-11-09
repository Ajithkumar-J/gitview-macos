import SwiftUI
#if canImport(Shared)
import Shared
#endif

/// Three-column window for an open repository: sections | list | detail.
struct RepositoryView: View {
    @Bindable var model: RepositoryViewModel
    let snapshot: GitRepositorySnapshot

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, snapshot: snapshot)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } content: {
            Group {
                switch model.section {
                case .changes:
                    ChangesListView(model: model, snapshot: snapshot)
                case .history:
                    HistoryListView(model: model)
                case .branches:
                    BranchListView(model: model)
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 600)
        } detail: {
            Group {
                switch model.section {
                case .changes:
                    ChangeDetailView(model: model)
                case .history:
                    CommitDetailView(model: model)
                case .branches:
                    BranchDetailView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusBarView(model: model)
            }
        }
        .navigationTitle(snapshot.name)
        .navigationSubtitle(snapshot.branchDisplayName)
        .toolbar {
            RepositoryToolbar(model: model, snapshot: snapshot)
        }
        .sheet(isPresented: Binding(
            get: { model.pendingRemoteOperation == .pull },
            set: { if !$0 { model.cancelRemoteOperation() } }
        )) {
            PullPreviewSheet(model: model)
        }
        .confirmationDialog(
            model.remoteConfirmationTitle,
            isPresented: Binding(
                get: { model.pendingRemoteOperation == .push || model.pendingRemoteOperation == .pushSetUpstream },
                set: { if !$0 { model.cancelRemoteOperation() } }
            )
        ) {
            Button(model.pendingRemoteOperation == .pushSetUpstream ? "Publish Branch" : "Push") {
                model.confirmRemoteOperation()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                model.cancelRemoteOperation()
            }
        } message: {
            Text(model.remoteConfirmationMessage)
        }
        .confirmationDialog(
            model.pendingDiscard?.area == .untracked ? "Delete Untracked File?" : "Discard Changes?",
            isPresented: Binding(
                get: { model.pendingDiscard != nil },
                set: { if !$0 { model.pendingDiscard = nil } }
            )
        ) {
            Button(model.pendingDiscard?.area == .untracked ? "Delete File" : "Discard Changes", role: .destructive) {
                model.confirmDiscard()
            }
            Button("Cancel", role: .cancel) {
                model.pendingDiscard = nil
            }
        } message: {
            if let change = model.pendingDiscard {
                Text(change.area == .untracked
                     ? "“\(change.path)” will be permanently deleted. This cannot be undone."
                     : "Unstaged changes in “\(change.path)” will be lost. Staged changes are kept. This cannot be undone.")
            }
        }
        .sheet(isPresented: $model.isShowingOutputLog) {
            OutputLogView(model: model)
        }
    }
}

struct RepositoryToolbar: ToolbarContent {
    @Bindable var model: RepositoryViewModel
    let snapshot: GitRepositorySnapshot

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            BranchMenu(model: model, snapshot: snapshot)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: model.fetch) {
                Label("Fetch", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Fetch from \(snapshot.defaultRemote ?? "remote") (⇧⌘F)")
            .disabled(model.isBusy || snapshot.remotes.isEmpty)

            Button(action: model.requestPull) {
                CountedLabel(title: "Pull", systemImage: "arrow.down", count: snapshot.behindCount)
            }
            .help(snapshot.upstreamBranch.map { "Pull from \($0) (⇧⌘P)" } ?? "Pull (⇧⌘P)")
            .disabled(model.isBusy || snapshot.isDetachedHead || snapshot.remotes.isEmpty)

            Button(action: model.requestPush) {
                CountedLabel(title: "Push", systemImage: "arrow.up", count: snapshot.aheadCount)
            }
            .help(snapshot.upstreamBranch.map { "Push to \($0) (⇧⌘U)" } ?? "Publish branch (⇧⌘U)")
            .disabled(model.isBusy || snapshot.isDetachedHead || snapshot.remotes.isEmpty)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: model.refresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh (⌘R)")

            Button(action: model.openInTerminal) {
                Label("Terminal", systemImage: "terminal")
            }
            .help("Open in Terminal (⌥⌘T)")

            Button {
                model.openInVSCode()
            } label: {
                Label("VS Code", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .help("Open in VS Code (⌥⌘V)")
        }
    }
}

/// Toolbar button content with a numeric badge, e.g. ↓ 3.
private struct CountedLabel: View {
    let title: String
    let systemImage: String
    let count: Int

    var body: some View {
        Label {
            Text(title)
        } icon: {
            HStack(spacing: 2) {
                Image(systemName: systemImage)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
            }
        }
    }
}

private struct BranchMenu: View {
    let model: RepositoryViewModel
    let snapshot: GitRepositorySnapshot

    var body: some View {
        Menu {
            let local = model.branches.filter { !$0.isRemote }
            Section("Switch Branch") {
                ForEach(local.prefix(15)) { branch in
                    Button {
                        model.switchBranch(to: branch)
                    } label: {
                        if branch.isCurrent {
                            Label(branch.name, systemImage: "checkmark")
                        } else {
                            Text(DisplayText.visible(branch.name, keepNewlines: false))
                        }
                    }
                    .disabled(branch.isCurrent)
                }
            }
            Divider()
            Button("Show All Branches…") {
                model.section = .branches
            }
        } label: {
            Label(snapshot.branchDisplayName, systemImage: "arrow.triangle.branch")
                .labelStyle(.titleAndIcon)
        }
        .menuIndicator(.visible)
        .help("Current branch — click to switch")
        .disabled(model.isBusy)
    }
}

// MARK: - Status bar

struct StatusBarView: View {
    let model: RepositoryViewModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if let activity = model.activity {
                    ProgressView().controlSize(.small)
                    Text(activity)
                } else if let message = model.statusMessage {
                    Image(systemName: icon(for: message.kind))
                        .foregroundStyle(color(for: message.kind))
                    Text(message.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                    Text(message.date, style: .relative)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                } else {
                    Text("Ready").foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if model.isRefreshing && model.activity == nil {
                    ProgressView().controlSize(.mini)
                }

                Button {
                    model.isShowingOutputLog = true
                } label: {
                    Label("Output", systemImage: "text.alignleft")
                }
                .buttonStyle(.borderless)
                .help("Show Git command output")
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .frame(height: 28)
        }
        .background(.bar)
    }

    private func icon(for kind: StatusMessage.Kind) -> String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle"
        case .error: "xmark.octagon.fill"
        }
    }

    private func color(for kind: StatusMessage.Kind) -> Color {
        switch kind {
        case .success: .green
        case .info: .secondary
        case .error: .red
        }
    }
}

struct OutputLogView: View {
    let model: RepositoryViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Git Output").font(.headline)
                Spacer()
                Button("Clear", action: model.clearOutputLog)
                    .disabled(model.outputLog.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()

            if model.outputLog.isEmpty {
                ContentUnavailableView("No Output Yet", systemImage: "text.alignleft", description: Text("Output from fetch, pull, push, commit and branch switches appears here."))
            } else {
                ScrollViewReader { proxy in
                    List(model.outputLog) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: entry.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                                    .foregroundStyle(entry.isError ? .red : .green)
                                Text(entry.title).fontWeight(.medium)
                                Spacer()
                                Text(entry.date.formatted(date: .omitted, time: .standard))
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                            Text(DisplayText.visible(entry.text))
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 4)
                        .id(entry.id)
                    }
                    .onAppear {
                        if let last = model.outputLog.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 420)
    }
}
