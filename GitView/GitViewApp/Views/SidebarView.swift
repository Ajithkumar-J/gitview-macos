import SwiftUI
#if canImport(Shared)
import Shared
#endif

struct SidebarView: View {
    @Bindable var model: RepositoryViewModel
    let snapshot: GitRepositorySnapshot

    private var selection: Binding<AppSection?> {
        Binding(
            get: { model.section },
            set: { if let section = $0 { model.section = section } }
        )
    }

    var body: some View {
        List(selection: selection) {
            Section {
                RepositorySummaryView(snapshot: snapshot)
                    .padding(.vertical, 4)
            }

            Section("Repository") {
                Label(AppSection.changes.title, systemImage: AppSection.changes.systemImage)
                    .badge(snapshot.files.count)
                    .tag(AppSection.changes)
                Label(AppSection.history.title, systemImage: AppSection.history.systemImage)
                    .tag(AppSection.history)
                Label(AppSection.branches.title, systemImage: AppSection.branches.systemImage)
                    .badge(model.branches.filter { !$0.isRemote }.count)
                    .tag(AppSection.branches)
            }

            let others = model.recents.urls.filter { $0.standardizedFileURL.path != snapshot.rootPath.standardizedFileURL.path }
            if !others.isEmpty {
                Section("Recent") {
                    ForEach(others.prefix(6), id: \.self) { url in
                        Button {
                            model.open(url)
                        } label: {
                            Label(url.lastPathComponent, systemImage: "folder")
                        }
                        .buttonStyle(.plain)
                        .help(url.abbreviatedPath)
                        .contextMenu {
                            Button("Remove from Recents") { model.recents.remove(url) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    model.chooseRepository()
                } label: {
                    Label("Open Repository…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(10)
        }
    }
}

private struct RepositorySummaryView: View {
    let snapshot: GitRepositorySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(Color.accentColor)
                Text(snapshot.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(snapshot.rootPath.path)

            HStack(spacing: 6) {
                Image(systemName: snapshot.isDetachedHead ? "exclamationmark.triangle.fill" : "arrow.triangle.branch")
                    .foregroundStyle(snapshot.isDetachedHead ? .orange : .secondary)
                    .imageScale(.small)
                Text(snapshot.branchDisplayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                AheadBehindView(ahead: snapshot.aheadCount, behind: snapshot.behindCount)
            }
            .font(.callout)

            Text(remoteDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var remoteDescription: String {
        if let upstream = snapshot.upstreamBranch {
            return "Tracking \(upstream)"
        }
        if let remote = snapshot.defaultRemote {
            return "Remote: \(remote) · not published"
        }
        return "No remote configured"
    }
}
