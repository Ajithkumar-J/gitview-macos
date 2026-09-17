import SwiftUI

struct CommitPanelView: View {
    @ObservedObject var viewModel: RepositoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Commit")
                    .font(.headline)

                Spacer()

                Text("\(viewModel.selectedCommitFilesCount) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Commit message", text: $viewModel.commitMessage, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)

            HStack {
                Spacer()

                Button {
                    viewModel.commitSelectedFiles()
                } label: {
                    Label("Commit Selected", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canCommitSelectedFiles)
            }
        }
    }
}
