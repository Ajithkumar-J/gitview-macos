import SwiftUI
#if canImport(Shared)
import Shared
#endif

/// Content column: staged / unstaged / untracked lists plus the commit box.
struct ChangesListView: View {
    @Bindable var model: RepositoryViewModel
    let snapshot: GitRepositorySnapshot

    var body: some View {
        VStack(spacing: 0) {
            if snapshot.files.isEmpty {
                ContentUnavailableView {
                    Label("Working Tree Clean", systemImage: "checkmark.seal")
                } description: {
                    Text("There is nothing to commit on \(snapshot.branchDisplayName).")
                } actions: {
                    Button("Refresh", action: model.refresh)
                }
                .frame(maxHeight: .infinity)
            } else {
                list
            }

            Divider()
            CommitPanelView(model: model, snapshot: snapshot)
        }
    }

    private var list: some View {
        List(selection: $model.selectedChangeID) {
            let conflicts = snapshot.changes(in: .conflicted)
            if !conflicts.isEmpty {
                section(.conflicted, conflicts) {
                    Button {
                        model.stage(conflicts)
                    } label: {
                        Label("Mark All Resolved", systemImage: "checkmark.circle")
                    }
                    .help("Stage all conflicted files to mark them resolved")
                }
            }

            let staged = snapshot.changes(in: .staged)
            if !staged.isEmpty {
                section(.staged, staged) {
                    Button(action: model.unstageAll) {
                        Label("Unstage All", systemImage: "minus.circle")
                    }
                    .help("Unstage all changes")
                }
            }

            let unstaged = snapshot.changes(in: .unstaged)
            if !unstaged.isEmpty {
                section(.unstaged, unstaged) {
                    Button {
                        model.stage(unstaged)
                    } label: {
                        Label("Stage All Changes", systemImage: "plus.circle")
                    }
                    .help("Stage all tracked changes")
                }
            }

            let untracked = snapshot.changes(in: .untracked)
            if !untracked.isEmpty {
                section(.untracked, untracked) {
                    Button {
                        model.stage(untracked)
                    } label: {
                        Label("Stage All Untracked", systemImage: "plus.circle")
                    }
                    .help("Stage all untracked files")
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .onKeyPress(.space) {
            guard let change = model.selectedChange else { return .ignored }
            model.toggleStage(change)
            return .handled
        }
        .contextMenu(forSelectionType: GitChange.ID.self) { ids in
            if let change = changes(for: ids).first {
                ChangeContextMenu(model: model, change: change)
            }
        } primaryAction: { ids in
            if let change = changes(for: ids).first {
                model.openInVSCode(change.path)
            }
        }
    }

    private func section<Actions: View>(_ area: GitChangeArea, _ changes: [GitChange], @ViewBuilder actions: () -> Actions) -> some View {
        Section {
            ForEach(changes) { change in
                ChangeRow(model: model, change: change)
                    .tag(change.id)
            }
        } header: {
            ListSectionHeader(title: area.title, count: changes.count, actions: actions)
        }
    }

    private func changes(for ids: Set<GitChange.ID>) -> [GitChange] {
        RepositoryViewModel.allChanges(in: snapshot).filter { ids.contains($0.id) }
    }
}

struct ChangeRow: View {
    let model: RepositoryViewModel
    let change: GitChange
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            FileTypeIcon(path: change.path)
            FilePathLabel(path: change.path, originalPath: change.area == .staged ? change.file.originalPath : nil)
                .strikethrough(change.kind == .deleted, color: .secondary)
            Spacer(minLength: 4)

            if isHovering {
                hoverActions
            }

            ChangeKindBadge(kind: change.kind)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var hoverActions: some View {
        HStack(spacing: 2) {
            if change.area == .unstaged || change.area == .untracked {
                Button {
                    model.requestDiscard(change)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("Discard changes…")
            }

            if change.area == .staged {
                Button {
                    model.unstage([change])
                } label: {
                    Image(systemName: "minus")
                }
                .help("Unstage")
            } else {
                Button {
                    model.stage(change)
                } label: {
                    Image(systemName: change.area == .conflicted ? "checkmark" : "plus")
                }
                .help(change.area == .conflicted ? "Mark resolved (stage)" : "Stage")
            }
        }
        .buttonStyle(.borderless)
        .imageScale(.medium)
        .fontWeight(.semibold)
    }
}

struct ChangeContextMenu: View {
    let model: RepositoryViewModel
    let change: GitChange

    var body: some View {
        if change.area == .staged {
            Button("Unstage") { model.unstage([change]) }
        } else {
            Button(change.area == .conflicted ? "Mark Resolved" : "Stage") { model.stage(change) }
        }

        if change.area == .unstaged || change.area == .untracked {
            Divider()
            Button(change.area == .untracked ? "Delete File…" : "Discard Changes…", role: .destructive) {
                model.requestDiscard(change)
            }
        }

        Divider()
        Button("Open in VS Code") { model.openInVSCode(change.path) }
        Button("Reveal in Finder") { model.revealInFinder(change.path) }
        Button("Copy Path") { model.copyPath(change.path) }
    }
}

/// Detail column for the Changes section.
struct ChangeDetailView: View {
    let model: RepositoryViewModel

    var body: some View {
        if let change = model.selectedChange {
            DiffPane(
                path: change.path,
                originalPath: change.area == .staged ? change.file.originalPath : nil,
                subtitle: "\(change.kind.title) · \(change.area == .staged ? "Staged" : "Not staged")",
                state: model.changeDiff
            ) {
                HStack(spacing: 4) {
                    if change.area == .staged {
                        Button("Unstage") { model.unstage([change]) }
                    } else {
                        Button(change.area == .conflicted ? "Mark Resolved" : "Stage") { model.stage(change) }
                    }

                    Menu {
                        ChangeContextMenu(model: model, change: change)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .controlSize(.small)
            }
        } else {
            ContentUnavailableView {
                Label("No File Selected", systemImage: "doc.text.magnifyingglass")
            } description: {
                if model.snapshot?.files.isEmpty == true {
                    Text("Your working tree is clean.")
                } else {
                    Text("Select a file to see its changes. Press Space to stage or unstage it.")
                }
            }
        }
    }
}
