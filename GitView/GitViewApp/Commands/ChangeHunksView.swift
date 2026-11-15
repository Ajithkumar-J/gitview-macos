import SwiftUI
#if canImport(Shared)
import Shared
#endif

// MARK: - Model

/// A file's changes split into hunks, reverting chosen ones and undoing that.
/// Owned by the dialog, so Undo survives the file leaving the list once all
/// of its changes are reverted.
@MainActor
@Observable
final class HunkRevertModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded(GitFilePatch)
        /// Binary or otherwise not splittable: show the plain diff instead.
        case unavailable
    }

    struct UndoEntry: Identifiable {
        let id = UUID()
        let path: String
        let revert: GitService.PartialRevert
    }

    private(set) var state: State = .idle
    private(set) var file: GitFileStatus?
    var checked = Set<Int>()
    private(set) var isWorking = false
    private(set) var undoStack = [UndoEntry]()
    var errorMessage: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func load(_ file: GitFileStatus?, session: CommandSession) {
        task?.cancel()
        guard let file, file.allowsPartialRevert, let service = session.service, let root = session.root else {
            self.file = file
            state = .idle
            return
        }
        if self.file?.path != file.path {
            checked = []
            state = .loading
        }
        self.file = file
        task = Task {
            let patch = try? await service.changes(in: file, in: root)
            guard !Task.isCancelled else { return }
            state = patch.map(State.loaded) ?? .unavailable
            // Hunk numbers change after a revert, so earlier ticks no longer apply.
            if case .loaded(let patch) = state {
                checked.formIntersection(patch.hunks.map(\.id))
            }
        }
    }

    func revert(_ ids: Set<Int>, session: CommandSession) {
        guard case .loaded(let patch) = state, let file, let service = session.service, let root = session.root else { return }
        run(session) {
            let revert = try await service.revertChanges(ids, of: patch, in: root)
            self.undoStack.append(UndoEntry(path: file.path, revert: revert))
            self.checked = []
        }
    }

    func undo(session: CommandSession) {
        guard let entry = undoStack.last, let service = session.service, let root = session.root else { return }
        run(session) {
            try await service.undoRevert(entry.revert, in: root)
            self.undoStack.removeLast()
        }
    }

    private func run(_ session: CommandSession, _ body: @escaping () async throws -> Void) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await body()
            } catch {
                let hint = (error as? LocalizedError)?.recoverySuggestion
                errorMessage = [error.localizedDescription, hint].compactMap { $0 }.joined(separator: "\n\n")
            }
            // Status may not change (still modified), so reload the hunks too.
            session.repositoryDidChange()
            if let file { load(file, session: session) }
        }
    }
}

// MARK: - Pane

/// Diff area of Commit, Check for Modifications and Revert Specific Changes.
/// Modified files show each change with its own Revert button; anything
/// else (new, deleted, renamed, binary) shows the plain diff.
struct ChangesPane: View {
    let session: CommandSession
    let file: GitFileStatus?
    @Bindable var hunks: HunkRevertModel
    let diff: FileDiffLoader
    var subtitle: String?
    /// Checkboxes and "Revert Selected" for picking several changes at once.
    var selectable = false

    var body: some View {
        VStack(spacing: 0) {
            if let entry = hunks.undoStack.last {
                undoBar(entry)
                Divider()
            }
            content
        }
        .task(id: file) { hunks.load(file, session: session) }
        .alert("Couldn’t Revert", isPresented: Binding(
            get: { hunks.errorMessage != nil },
            set: { if !$0 { hunks.errorMessage = nil } }
        )) {
            Button("OK") { hunks.errorMessage = nil }
        } message: {
            Text(hunks.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let file, file.allowsPartialRevert, hunks.file?.path == file.path {
            switch hunks.state {
            case .loaded(let patch):
                HunkListView(file: file, patch: patch, subtitle: subtitle, selectable: selectable, hunks: hunks) { ids in
                    hunks.revert(ids, session: session)
                }
                .disabled(hunks.isWorking || session.isRunning)
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .idle, .unavailable:
                plainDiff
            }
        } else {
            plainDiff
        }
    }

    private var plainDiff: some View {
        DiffPane(path: file?.path, originalPath: file?.originalPath, subtitle: subtitle ?? file?.combinedKind.title, state: diff.state)
    }

    private func undoBar(_ entry: HunkRevertModel.UndoEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Reverted \(entry.revert.count == 1 ? "1 change" : "\(entry.revert.count) changes") in \((entry.path as NSString).lastPathComponent)")
                    .font(.callout.weight(.medium))
                Text("Undo is available until you close this window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                hunks.undo(session: session)
            } label: {
                Label(hunks.undoStack.count > 1 ? "Undo (\(hunks.undoStack.count))" : "Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(hunks.isWorking)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
    }
}

// MARK: - Hunk list

/// Each change of one file as its own block: what it adds and removes, and a
/// button that puts just that block back to the last commit.
struct HunkListView: View {
    let file: GitFileStatus
    let patch: GitFilePatch
    var subtitle: String?
    let selectable: Bool
    @Bindable var hunks: HunkRevertModel
    let onRevert: (Set<Int>) -> Void

    private var numberWidth: CGFloat {
        let largest = patch.hunks.flatMap(\.lines).reduce(0) { max($0, $1.oldLineNumber ?? 0, $1.newLineNumber ?? 0) }
        return CGFloat(max(3, String(largest).count)) * 7.5 + 6
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(patch.hunks) { hunk in
                        Section {
                            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                                lineRow(line)
                            }
                            Color.clear.frame(height: 10)
                        } header: {
                            hunkHeader(hunk)
                        }
                    }
                }
                .textSelection(.enabled)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            FileTypeIcon(path: file.path)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(DisplayText.visible((file.path as NSString).lastPathComponent, keepNewlines: false))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(patch.hunks.count == 1 ? "1 change" : "\(patch.hunks.count) changes") · \(subtitle ?? "compared with the last commit")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if selectable {
                HStack(spacing: 10) {
                    Button("All") { hunks.checked = Set(patch.hunks.map(\.id)) }
                    Button("None") { hunks.checked = [] }
                }
                .buttonStyle(.link)
                .font(.callout)
                Button("Revert Selected (\(hunks.checked.count))") { onRevert(hunks.checked) }
                    .buttonStyle(.borderedProminent)
                    .disabled(hunks.checked.isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func hunkHeader(_ hunk: GitHunk) -> some View {
        HStack(spacing: 8) {
            if selectable {
                Toggle("", isOn: Binding(
                    get: { hunks.checked.contains(hunk.id) },
                    set: { isOn in
                        if isOn { hunks.checked.insert(hunk.id) } else { hunks.checked.remove(hunk.id) }
                    }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
            }
            Text("Change \(hunk.id + 1) of \(patch.hunks.count)")
                .font(.callout.weight(.semibold))
            Text("· \(hunk.lineDescription)")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !hunk.context.isEmpty {
                Text("· \(DisplayText.visible(hunk.context, keepNewlines: false))")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Text("+\(hunk.additions)").foregroundStyle(.green)
                Text("−\(hunk.deletions)").foregroundStyle(.red)
            }
            .font(.caption.monospacedDigit().weight(.medium))
            Button {
                onRevert([hunk.id])
            } label: {
                Label("Revert", systemImage: "arrow.uturn.backward")
            }
            .controlSize(.small)
            .help("Put these lines back to the last commit. Other changes in the file stay.")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func lineRow(_ line: GitDiffLine) -> some View {
        let (marker, background): (String, Color) = switch line.kind {
        case .addition: ("+", .green.opacity(0.14))
        case .deletion: ("−", .red.opacity(0.13))
        default: (" ", .clear)
        }
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(line.oldLineNumber.map(String.init) ?? "")
                .frame(width: numberWidth, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(line.newLineNumber.map(String.init) ?? "")
                .frame(width: numberWidth, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(marker)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(DisplayText.visible(line.text.replacingOccurrences(of: "\t", with: "    "), keepNewlines: false))
                .foregroundStyle(line.kind == .noNewline ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1)
        .background(background)
    }
}
