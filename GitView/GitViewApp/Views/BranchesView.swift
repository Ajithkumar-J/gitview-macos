import SwiftUI
#if canImport(Shared)
import Shared
#endif

/// Content column: local and remote branches. Double-click switches.
struct BranchListView: View {
    @Bindable var model: RepositoryViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                FilterField(prompt: "Filter branches", text: $model.branchFilter, onSubmit: model.searchRemoteBranches)
                if model.remoteName != nil {
                    Button {
                        model.searchRemoteBranches()
                    } label: {
                        if model.isSearchingRemote {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "network")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.branchFilter.trimmingCharacters(in: .whitespaces).isEmpty || model.isSearchingRemote)
                    .help("Branches on \(model.remoteName ?? "the remote") are searched as you type. Click to refresh the list from the server.")
                }
            }
            .padding(10)
            Divider()

            List(selection: $model.selectedBranchID) {
                let local = model.localBranches
                Section {
                    ForEach(local) { branch in
                        BranchRow(branch: branch).tag(branch.id)
                    }
                    if local.isEmpty {
                        emptyRow(model.branchFilter.isEmpty ? "No local branches yet." : "No local branches match.")
                    }
                } header: {
                    ListSectionHeader(title: "Local", count: local.count) { EmptyView() }
                }

                let remote = model.remoteBranches
                if !remote.isEmpty || model.snapshot?.remotes.isEmpty == false {
                    Section {
                        ForEach(remote) { branch in
                            BranchRow(branch: branch).tag(branch.id)
                        }
                        if remote.isEmpty {
                            emptyRow(model.branchFilter.isEmpty ? "Fetch to see remote branches, or type to search the server." : model.isSearchingRemote ? "Searching \(model.remoteName ?? "the server")…" : "No fetched remote branches match.")
                        }
                    } header: {
                        ListSectionHeader(title: "Remote", count: remote.count) {
                            Button(action: model.fetch) {
                                Label("Fetch", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .help("Fetch from remote")
                            .disabled(model.isBusy)
                        }
                    }
                }

                let unfetched = model.unfetchedRemoteBranches
                if !unfetched.isEmpty {
                    Section {
                        ForEach(unfetched) { branch in
                            BranchRow(branch: branch).tag(branch.id)
                        }
                    } header: {
                        ListSectionHeader(title: "On \(model.remoteName ?? "Remote") — Not Fetched", count: unfetched.count) { EmptyView() }
                    }
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: GitBranch.ID.self) { ids in
                if let branch = branch(for: ids) {
                    BranchActions(model: model, branch: branch)
                }
            } primaryAction: { ids in
                if let branch = branch(for: ids) {
                    model.switchBranch(to: branch)
                }
            }

            Divider()
            Text("Double-click a branch to switch to it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(6)
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func branch(for ids: Set<GitBranch.ID>) -> GitBranch? {
        guard let id = ids.first else { return nil }
        return (model.branches + model.remoteSearchResults).first { $0.id == id }
    }
}

struct BranchRow: View {
    let branch: GitBranch

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(branch.isCurrent ? Color.green : Color.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(branch.name)
                    .fontWeight(branch.isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if branch.isUpstreamGone {
                Text("gone")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .help("The upstream branch was deleted on the remote")
            }
            AheadBehindView(ahead: branch.aheadCount, behind: branch.behindCount)
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        if branch.isCurrent { return "checkmark.circle.fill" }
        if branch.isUnfetched { return "icloud.and.arrow.down" }
        return branch.isRemote ? "cloud" : "arrow.triangle.branch"
    }

    private var subtitle: String? {
        if branch.isUnfetched {
            return "Will be fetched when you switch to it"
        }
        let parts = [branch.lastCommitSubject, branch.lastCommitDate.map { GitDateFormatter.short($0) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct BranchActions: View {
    let model: RepositoryViewModel
    let branch: GitBranch

    var body: some View {
        if !branch.isCurrent {
            Button(branch.isRemote ? "Check Out “\(branch.localTrackingName)”" : "Switch to “\(branch.name)”") {
                model.switchBranch(to: branch)
            }
            Divider()
        }
        Button("Copy Branch Name") { ExternalApps.copyToPasteboard(branch.name) }
    }
}

/// Detail column for the Branches section.
struct BranchDetailView: View {
    let model: RepositoryViewModel

    var body: some View {
        if let branch = model.selectedBranch {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: branch.isRemote ? "cloud" : "arrow.triangle.branch")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(branch.isCurrent ? Color.green : Color.accentColor)
                            .frame(width: 52, height: 52)
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(branch.name)
                                .font(.title2.weight(.semibold))
                                .textSelection(.enabled)
                            Text(kindDescription(branch))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                        if let upstream = branch.upstream {
                            GridRow {
                                label("Upstream")
                                HStack(spacing: 8) {
                                    Text(upstream).font(.body.monospaced())
                                    if branch.isUpstreamGone {
                                        Text("deleted on remote").foregroundStyle(.orange)
                                    }
                                }
                            }
                            GridRow {
                                label("Status")
                                Text(trackingDescription(branch))
                            }
                        } else if !branch.isRemote {
                            GridRow {
                                label("Upstream")
                                Text("None — Push will offer to publish this branch.").foregroundStyle(.secondary)
                            }
                        }
                        if let subject = branch.lastCommitSubject {
                            GridRow {
                                label("Last commit")
                                Text(subject).textSelection(.enabled)
                            }
                        }
                        if let date = branch.lastCommitDate {
                            GridRow {
                                label("Updated")
                                Text(GitDateFormatter.long(date))
                            }
                        }
                    }

                    if !branch.isCurrent {
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                model.switchBranch(to: branch)
                            } label: {
                                Label(
                                    branch.isRemote ? "Check Out as “\(branch.localTrackingName)”" : "Switch to Branch",
                                    systemImage: "arrow.right.circle"
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(model.isBusy)

                            Text("If your local changes conflict with this branch, Git refuses to switch and GitView shows its message. Nothing is forced or stashed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("No Branch Selected", systemImage: "arrow.triangle.branch", description: Text("Select a branch to see details. Double-click to switch."))
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func kindDescription(_ branch: GitBranch) -> String {
        if branch.isCurrent { return "Current branch" }
        if branch.isUnfetched { return "Remote branch on \(branch.remoteName ?? "remote"), not fetched yet" }
        if branch.isRemote { return "Remote-tracking branch on \(branch.remoteName ?? "remote")" }
        return "Local branch"
    }

    private func trackingDescription(_ branch: GitBranch) -> String {
        switch (branch.aheadCount, branch.behindCount) {
        case (0, 0): return "Up to date"
        case (let ahead, 0): return "\(ahead) commit\(ahead == 1 ? "" : "s") ahead"
        case (0, let behind): return "\(behind) commit\(behind == 1 ? "" : "s") behind"
        case (let ahead, let behind): return "\(ahead) ahead, \(behind) behind"
        }
    }
}
