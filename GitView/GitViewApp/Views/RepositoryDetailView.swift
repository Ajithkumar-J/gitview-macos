import SwiftUI
#if canImport(Shared)
import Shared
#endif

struct RepositoryDetailView: View {
    @ObservedObject var viewModel: RepositoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            Group {
                if let snapshot = viewModel.snapshot {
                    switch viewModel.selectedSection {
                    case .changes:
                        ChangesView(snapshot: snapshot, viewModel: viewModel)
                    case .branches:
                        BranchesView(snapshot: snapshot, viewModel: viewModel)
                    }
                } else {
                    EmptyRepositoryView(openAction: viewModel.chooseRepository)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            if viewModel.isLoading {
                ZStack {
                    Color.black.opacity(0.08)
                    ProgressView()
                        .controlSize(.large)
                }
            }
        }
        .alert("GitView", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert("GitView", isPresented: Binding(
            get: { viewModel.operationMessage != nil },
            set: { if !$0 { viewModel.operationMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.operationMessage ?? "")
        }
        .alert("Revert File?", isPresented: Binding(
            get: { viewModel.pendingRevertFile != nil },
            set: { if !$0 { viewModel.pendingRevertFile = nil } }
        )) {
            Button("Revert", role: .destructive) {
                viewModel.confirmRevert()
            }
            Button("Cancel", role: .cancel) {
                viewModel.pendingRevertFile = nil
            }
        } message: {
            Text("This will discard local changes in \(viewModel.pendingRevertFile?.path ?? "this file"). This cannot be undone by GitView.")
        }
        .sheet(isPresented: Binding(
            get: { viewModel.pendingRemoteOperation == .pull },
            set: { if !$0 { viewModel.pendingRemoteOperation = nil } }
        )) {
            PullPreviewSheet(viewModel: viewModel)
        }
        .confirmationDialog("Remote Operation", isPresented: Binding(
            get: { viewModel.pendingRemoteOperation != nil && viewModel.pendingRemoteOperation != .pull },
            set: { if !$0 { viewModel.pendingRemoteOperation = nil } }
        )) {
            Button(viewModel.remoteConfirmationButtonTitle) {
                viewModel.confirmRemoteOperation()
            }
            Button("Cancel", role: .cancel) {
                viewModel.pendingRemoteOperation = nil
            }
        } message: {
            Text(viewModel.remoteConfirmationMessage)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.snapshot?.name ?? "No Repository")
                    .font(.title2.weight(.semibold))
                Text(viewModel.snapshot?.rootPath.path ?? "Select a local Git repository to inspect status.")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Label(viewModel.gitExecutablePath, systemImage: "terminal")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                viewModel.requestPull()
            } label: {
                Label("Pull", systemImage: "arrow.down.circle")
            }
            .disabled(viewModel.snapshot == nil || viewModel.isLoading)

            Button {
                viewModel.requestPush()
            } label: {
                Label("Push", systemImage: "arrow.up.circle")
            }
            .disabled(viewModel.snapshot == nil || viewModel.isLoading)

            Button {
                viewModel.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.snapshot == nil || viewModel.isLoading)
        }
        .padding()
    }
}

private struct PullPreviewSheet: View {
    @ObservedObject var viewModel: RepositoryViewModel

    private var preview: GitPullPreview? {
        viewModel.pendingPullPreview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Pull Preview", systemImage: "arrow.down.circle")
                    .font(.title2.weight(.semibold))
                Spacer()
            }

            if let preview {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pull From")
                        .font(.headline)
                    HStack {
                        TextField("development or origin/development", text: $viewModel.pullSourceBranch)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                viewModel.preparePullFromTypedBranch()
                            }

                        Button {
                            viewModel.preparePullFromTypedBranch()
                        } label: {
                            Label("Check", systemImage: "magnifyingglass")
                        }
                        .disabled(viewModel.isLoading)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Target")
                        .font(.headline)
                    Text(preview.target)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    PullCountBadge(title: "Local commits", value: preview.aheadCount)
                    PullCountBadge(title: "Incoming commits", value: preview.behindCount)
                    PullCountBadge(title: "Incoming files", value: preview.incomingChangedFiles.count)
                }

                Picker("Pull Strategy", selection: $viewModel.selectedPullStrategy) {
                    ForEach(GitPullStrategy.allCases) { strategy in
                        Text(strategy.rawValue).tag(strategy)
                    }
                }
                .pickerStyle(.segmented)

                if preview.hasPossibleConflicts {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Possible conflicts found", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)

                        Text("These files have local changes and incoming changes from upstream. Pulling may create merge conflicts that must be resolved before committing.")
                            .foregroundStyle(.secondary)

                        PullFileList(files: preview.possibleConflictFiles)
                    }
                } else {
                    Label("No local file overlap detected after fetch.", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                }

                if preview.isDiverged {
                    Text("This branch has both local and incoming commits. Choose Merge, Rebase, or Fast-Forward Only before pulling.")
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pull From")
                        .font(.headline)
                    HStack {
                        TextField("development or origin/development", text: $viewModel.pullSourceBranch)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                viewModel.preparePullFromTypedBranch()
                            }

                        Button {
                            viewModel.preparePullFromTypedBranch()
                        } label: {
                            Label("Check", systemImage: "magnifyingglass")
                        }
                        .disabled(viewModel.pullSourceBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isLoading)
                    }

                    Text("This branch has no upstream, or no pull source has been selected. Enter a branch name to fetch and preview before pulling.")
                        .foregroundStyle(.secondary)

                    if viewModel.isLoading {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    viewModel.pendingRemoteOperation = nil
                }

                Button(preview?.hasPossibleConflicts == true ? "Pull Anyway" : "Pull") {
                    viewModel.confirmRemoteOperation()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preview == nil)
            }
        }
        .padding(22)
        .frame(minWidth: 560, minHeight: 420)
    }
}

private struct PullCountBadge: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct PullFileList: View {
    let files: [String]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(files, id: \.self) { file in
                    Text(file)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
        }
        .frame(minHeight: 90, maxHeight: 160)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
