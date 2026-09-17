import SwiftUI
#if canImport(Shared)
import Shared
#endif

struct DiffView: View {
    @ObservedObject var viewModel: RepositoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.selectedFile?.path ?? "Diff")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(viewModel.selectedFile?.shortStatus ?? "No file selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("Diff Mode", selection: Binding(
                    get: { viewModel.selectedDiffMode },
                    set: { viewModel.changeDiffMode($0) }
                )) {
                    ForEach(GitDiffMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .disabled(viewModel.selectedFile == nil || viewModel.selectedFile?.state == .untracked)
            }

            ZStack(alignment: .topLeading) {
                ScrollView([.vertical, .horizontal]) {
                    DiffTextView(diffText: viewModel.diffText)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor))
                )

                if viewModel.isLoadingDiff {
                    ZStack {
                        Color.black.opacity(0.04)
                        ProgressView()
                    }
                }
            }
        }
    }
}

private struct DiffTextView: View {
    let diffText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(diffText.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                Text(String(line))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(color(for: String(line)))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 1)
            }
        }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
            return .green
        }

        if line.hasPrefix("-") && !line.hasPrefix("---") {
            return .red
        }

        if line.hasPrefix("@@") {
            return .blue
        }

        if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("---") || line.hasPrefix("+++") {
            return .secondary
        }

        return .primary
    }
}
