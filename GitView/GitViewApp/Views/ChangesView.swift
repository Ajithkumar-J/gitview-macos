import SwiftUI
#if canImport(Shared)
import Shared
#endif

struct ChangesView: View {
    let snapshot: GitRepositorySnapshot
    @ObservedObject var viewModel: RepositoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(snapshot.branch, systemImage: "arrow.triangle.branch")
                    .font(.headline)
                Spacer()
                Text("\(snapshot.files.count) changed \(snapshot.files.count == 1 ? "file" : "files")")
                    .foregroundStyle(.secondary)
            }

            if snapshot.files.isEmpty {
                ContentUnavailableView(
                    "Working Tree Clean",
                    systemImage: "checkmark.circle",
                    description: Text("There are no modified, staged, or untracked files.")
                )
            } else {
                HSplitView {
                    VStack(spacing: 12) {
                        HStack {
                            Button {
                                viewModel.selectAllCommitFiles()
                            } label: {
                                Label("Select All", systemImage: "checklist.checked")
                            }

                            Button {
                                viewModel.clearCommitSelection()
                            } label: {
                                Label("Clear", systemImage: "xmark.circle")
                            }

                            Spacer()

                            Text("\(viewModel.selectedCommitFilesCount) selected")
                                .foregroundStyle(.secondary)
                        }

                        List {
                            ForEach(snapshot.groupedFiles, id: \.state) { group in
                                Section(group.state.rawValue) {
                                    ForEach(group.files) { file in
                                        FileStatusRow(
                                            file: file,
                                            isCommitSelected: viewModel.selectedCommitFileIDs.contains(file.id),
                                            isDiffSelected: viewModel.selectedFile?.id == file.id,
                                            canCommit: viewModel.canCommit(file),
                                            toggleCommitSelection: {
                                                viewModel.toggleCommitSelection(for: file)
                                            },
                                            selectFile: {
                                                viewModel.selectFile(file)
                                            },
                                            revertFile: {
                                                viewModel.requestRevert(file: file)
                                            }
                                        )
                                    }
                                }
                            }
                        }
                        .listStyle(.inset)
                    }
                    .frame(minWidth: 330, idealWidth: 460)

                    VStack(spacing: 14) {
                        DiffView(viewModel: viewModel)

                        Divider()

                        CommitPanelView(viewModel: viewModel)
                    }
                    .frame(minWidth: 460)
                }
            }
        }
        .padding()
    }
}
