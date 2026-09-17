import SwiftUI
#if canImport(Shared)
import Shared
#endif

struct FileStatusRow: View {
    let file: GitFileStatus
    let isCommitSelected: Bool
    let isDiffSelected: Bool
    let canCommit: Bool
    let toggleCommitSelection: () -> Void
    let selectFile: () -> Void
    let revertFile: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggleCommitSelection) {
                Image(systemName: isCommitSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isCommitSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canCommit)
            .help(canCommit ? "Include in commit" : "Conflicted files cannot be committed")

            Text(file.shortStatus)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .frame(width: 32, alignment: .leading)
                .foregroundStyle(statusColor)

            Button(action: selectFile) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.path)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let originalPath = file.originalPath {
                        Text("from \(originalPath)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isDiffSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button(role: .destructive) {
                revertFile()
            } label: {
                Label("Revert", systemImage: "arrow.uturn.backward")
            }
        }
    }

    private var statusColor: Color {
        switch file.state {
        case .staged:
            .blue
        case .modified:
            .orange
        case .added:
            .green
        case .deleted:
            .red
        case .renamed:
            .purple
        case .untracked:
            .gray
        case .conflicted:
            .pink
        }
    }
}
