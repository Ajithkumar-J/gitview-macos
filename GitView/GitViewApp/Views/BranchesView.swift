import SwiftUI
#if canImport(Shared)
import Shared
#endif

struct BranchesView: View {
    let snapshot: GitRepositorySnapshot
    @ObservedObject var viewModel: RepositoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Branches", systemImage: "arrow.triangle.branch")
                    .font(.headline)
                Spacer()
                Text("Current: \(snapshot.branch)")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Enter branch name", text: $viewModel.branchSearchText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            viewModel.searchRemoteBranches()
                        }

                    Button {
                        viewModel.searchRemoteBranches()
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .disabled(viewModel.branchSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isSearchingBranches)
                }

                Text("Search checks remote origin for matching branch names. GitView fetches only the selected branch when you switch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewModel.isSearchingBranches {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if viewModel.remoteBranchSearchResults.isEmpty {
                ContentUnavailableView(
                    "Search for a Branch",
                    systemImage: "magnifyingglass",
                    description: Text("Enter a branch name above to find remote branches.")
                )
            } else {
                List(viewModel.remoteBranchSearchResults) { branch in
                HStack {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(Color.accentColor)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(branch.displayName)
                            .font(.system(.body, design: .monospaced))

                        Text("Switch creates local tracking branch \(branch.localTrackingName).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        viewModel.switchBranch(to: branch)
                    } label: {
                        Label("Switch", systemImage: "arrow.right.circle")
                    }
                    .disabled(branch.isCurrent || viewModel.isLoading)
                }
                .padding(.vertical, 5)
                }
                .listStyle(.inset)
            }
        }
        .padding()
    }
}
