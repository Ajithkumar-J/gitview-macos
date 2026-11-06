import SwiftUI
#if canImport(Shared)
import Shared
#endif

/// Content column: commit list with filter and paging.
struct HistoryListView: View {
    @Bindable var model: RepositoryViewModel

    var body: some View {
        VStack(spacing: 0) {
            FilterField(prompt: "Filter by message, author or hash", text: $model.historyFilter)
                .padding(10)
            Divider()

            if model.commits.isEmpty {
                if model.isLoadingHistory {
                    ProgressView().frame(maxHeight: .infinity)
                } else {
                    ContentUnavailableView("No Commits Yet", systemImage: "clock", description: Text("Commits on this branch will appear here."))
                        .frame(maxHeight: .infinity)
                }
            } else {
                list
            }
        }
        .task(id: model.snapshot?.rootPath) {
            model.loadHistoryIfNeeded()
        }
    }

    private var list: some View {
        let commits = model.filteredCommits
        return List(selection: $model.selectedCommitID) {
            ForEach(commits) { commit in
                CommitRow(commit: commit)
                    .tag(commit.id)
            }

            if model.canLoadMoreHistory {
                HStack {
                    Spacer()
                    if model.isLoadingHistory {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Load More", action: model.loadMoreHistory)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
                .onAppear {
                    if model.historyFilter.isEmpty {
                        model.loadMoreHistory()
                    }
                }
            }

            if commits.isEmpty {
                Text("No loaded commits match “\(model.historyFilter)”.")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: GitCommit.ID.self) { ids in
            if let hash = ids.first, let commit = model.commits.first(where: { $0.id == hash }) {
                Button("Copy Commit Hash") { ExternalApps.copyToPasteboard(commit.hash) }
                Button("Copy Short Hash") { ExternalApps.copyToPasteboard(commit.shortHash) }
                Button("Copy Message") { ExternalApps.copyToPasteboard(commit.subject) }
            }
        }
    }
}

struct CommitRow: View {
    let commit: GitCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(commit.subject.isEmpty ? "(no message)" : commit.subject)
                .fontWeight(.medium)
                .lineLimit(2)

            HStack(spacing: 6) {
                Text(commit.shortHash)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(commit.authorName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(GitDateFormatter.short(commit.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(GitDateFormatter.long(commit.date))
            }

            if !commit.refs.isEmpty {
                RefChipsView(refs: commit.refs)
            }
        }
        .padding(.vertical, 3)
    }
}

struct RefChipsView: View {
    let refs: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(refs.prefix(4), id: \.self) { ref in
                RefChip(ref: ref)
            }
            if refs.count > 4 {
                Text("+\(refs.count - 4)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(refs.dropFirst(4).joined(separator: "\n"))
            }
        }
    }
}

/// Detail column: commit metadata, changed files and the selected file's diff.
struct CommitDetailView: View {
    @Bindable var model: RepositoryViewModel

    var body: some View {
        switch model.commitDetail {
        case .none:
            ContentUnavailableView("No Commit Selected", systemImage: "clock.arrow.circlepath", description: Text("Select a commit to see its details and changes."))
        case .loading:
            ProgressView().controlSize(.small)
        case .failed(let message):
            ContentUnavailableView {
                Label("Unable to Load Commit", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).textSelection(.enabled)
            }
        case .loaded(let detail):
            VSplitView {
                VStack(spacing: 0) {
                    CommitHeaderView(detail: detail)
                    Divider()
                    fileList(detail)
                }
                .frame(minHeight: 180, idealHeight: 280)

                diff(detail)
                    .frame(minHeight: 160)
            }
        }
    }

    private func fileList(_ detail: GitCommitDetail) -> some View {
        List(selection: $model.selectedCommitFileID) {
            Section {
                ForEach(detail.files) { file in
                    HStack(spacing: 8) {
                        FileTypeIcon(path: file.path)
                        FilePathLabel(path: file.path, originalPath: file.originalPath)
                        Spacer()
                        ChangeKindBadge(kind: file.kind)
                    }
                    .tag(file.id)
                }
            } header: {
                ListSectionHeader(title: "Files Changed", count: detail.files.count) { EmptyView() }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: GitCommitFile.ID.self) { ids in
            if let file = detail.files.first(where: { ids.contains($0.id) }) {
                Button("Open in VS Code") { model.openInVSCode(file.path) }
                Button("Reveal in Finder") { model.revealInFinder(file.path) }
                Button("Copy Path") { model.copyPath(file.path) }
            }
        }
    }

    @ViewBuilder
    private func diff(_ detail: GitCommitDetail) -> some View {
        let file = detail.files.first { $0.id == model.selectedCommitFileID }
        DiffPane(
            path: file?.path,
            originalPath: file?.originalPath,
            subtitle: file.map { "\($0.kind.title) in \(detail.commit.shortHash)" },
            state: model.commitFileDiff
        )
    }
}

struct CommitHeaderView: View {
    let detail: GitCommitDetail

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(detail.commit.subject)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !detail.body.isEmpty {
                    Text(detail.body)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if !detail.commit.refs.isEmpty {
                    RefChipsView(refs: detail.commit.refs)
                }

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        label("Commit")
                        HStack(spacing: 6) {
                            Text(detail.commit.hash)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                            Button {
                                ExternalApps.copyToPasteboard(detail.commit.hash)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy commit hash")
                        }
                    }
                    GridRow {
                        label("Author")
                        Text("\(detail.commit.authorName) <\(detail.commit.authorEmail)>")
                            .textSelection(.enabled)
                    }
                    GridRow {
                        label("Date")
                        Text(GitDateFormatter.long(detail.commit.date))
                    }
                    if detail.committerName != detail.commit.authorName {
                        GridRow {
                            label("Committer")
                            Text(detail.committerName)
                        }
                    }
                    if !detail.commit.parentHashes.isEmpty {
                        GridRow {
                            label(detail.commit.isMerge ? "Parents" : "Parent")
                            Text(detail.commit.parentHashes.map { String($0.prefix(7)) }.joined(separator: "  "))
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
                .font(.callout)

                if detail.commit.isMerge {
                    Label("Merge commit — changes are shown against the first parent.", systemImage: "arrow.triangle.merge")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }
}
