import SwiftUI
#if canImport(Shared)
import Shared
#endif

struct CommitPanelView: View {
    @Bindable var model: RepositoryViewModel
    let snapshot: GitRepositorySnapshot
    @FocusState private var isMessageFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                Text(snapshot.branchDisplayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(model.stagedCount == 1 ? "1 file staged" : "\(model.stagedCount) files staged")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.callout)

            ZStack(alignment: .topLeading) {
                if model.commitMessage.isEmpty {
                    Text("Commit message")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.commitMessage)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($isMessageFocused)
                    .frame(minHeight: 54, maxHeight: 120)
            }
            .padding(4)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isMessageFocused ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor), lineWidth: isMessageFocused ? 2 : 1)
            )

            HStack(spacing: 8) {
                if let reason = model.commitDisabledReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                if model.stagedCount == 0, !snapshot.files.isEmpty, !snapshot.hasConflicts {
                    Button("Stage All", action: model.stageAll)
                        .help("git add -A")
                }

                Button(action: model.commit) {
                    Text("Commit")
                        .frame(minWidth: 70)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canCommit)
                .help("Commit staged changes (⌘↩)")
            }
        }
        .padding(12)
        .background(.bar)
    }
}
