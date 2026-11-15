import SwiftUI
#if canImport(Shared)
import Shared
#endif

/// Fetches the pull source first and shows what the pull would bring in.
struct PullPreviewSheet: View {
    @Bindable var model: RepositoryViewModel

    private var preview: GitPullPreview? {
        model.pendingPullPreview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pull").font(.title2.weight(.semibold))
                    Text("into \(model.snapshot?.branch ?? "current branch")")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Pull from").font(.headline)
                HStack {
                    TextField(model.snapshot?.upstreamBranch ?? "development or origin/development", text: $model.pullSourceBranch)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(model.preparePull)
                    Button("Check", action: model.preparePull)
                        .disabled(model.pullSourceBranch.trimmingCharacters(in: .whitespaces).isEmpty || model.isPreparingPull)
                }
                if model.snapshot?.upstreamBranch == nil {
                    Text("This branch has no upstream. Enter a remote branch to fetch and preview before pulling.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.isPreparingPull {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Fetching and comparing…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else if let preview {
                previewContent(preview)
            } else {
                Spacer(minLength: 60)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.cancelRemoteOperation()
                }
                .keyboardShortcut(.cancelAction)

                Button(preview?.hasPossibleConflicts == true ? "Pull Anyway" : "Pull") {
                    model.confirmRemoteOperation()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preview == nil || model.isPreparingPull)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    @ViewBuilder
    private func previewContent(_ preview: GitPullPreview) -> some View {
        HStack(spacing: 10) {
            CountTile(title: "Incoming commits", value: preview.behindCount, systemImage: "arrow.down")
            CountTile(title: "Local commits", value: preview.aheadCount, systemImage: "arrow.up")
            CountTile(title: "Incoming files", value: preview.incomingChangedFiles.count, systemImage: "doc.on.doc")
        }

        if preview.behindCount == 0 {
            Label("Already up to date with \(preview.target).", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Strategy").font(.headline)
                Picker("Strategy", selection: $model.selectedPullStrategy) {
                    ForEach(GitPullStrategy.allCases) { strategy in
                        Text(strategy.rawValue).tag(strategy)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if preview.isDiverged {
                    Text("Your branch and \(preview.target) have both moved. Merge creates a merge commit, Rebase replays your commits on top, Fast-Forward Only stops instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if preview.hasPossibleConflicts {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Possible conflicts", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text("These files have local changes and incoming changes. Git may stop the pull or create conflicts you will need to resolve.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(preview.possibleConflictFiles, id: \.self) { file in
                                Text(file)
                                    .font(.callout.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(10)
                    }
                    .frame(maxHeight: 130)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            } else {
                Label("No overlap between your local changes and incoming files.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}

private struct CountTile: View {
    let title: String
    let value: Int
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title2.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
