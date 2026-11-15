import AppKit
import SwiftUI
#if canImport(Shared)
import Shared
#endif

/// Home screen shown when no repository is open.
struct WelcomeView: View {
    let model: RepositoryViewModel
    let isDropTargeted: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 18) {
                Spacer()
                AppGlyph(size: 88)
                VStack(spacing: 6) {
                    Text("GitView")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Everyday Git for your Mac")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                Button {
                    model.chooseRepository()
                } label: {
                    Label("Open Repository…", systemImage: "folder")
                        .frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("o")

                Text("Or drop a folder here, or right-click a folder in Finder and choose GitView.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)

                Spacer()

                if let version = model.gitVersion {
                    Label(version, systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity)

            Divider()

            RecentRepositoriesList(model: model)
                .frame(width: 340)
        }
        .overlay {
            if model.isOpening {
                ProgressView("Opening…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                    .padding(10)
                    .overlay(Label("Drop to open", systemImage: "arrow.down.doc").font(.title2.weight(.semibold)).foregroundStyle(Color.accentColor))
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct RecentRepositoriesList: View {
    let model: RepositoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent Repositories")
                    .font(.headline)
                Spacer()
                if !model.recents.urls.isEmpty {
                    Button("Clear") { model.recents.clear() }
                        .buttonStyle(.borderless)
                        .font(.callout)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 8)

            if model.recents.urls.isEmpty {
                ContentUnavailableView("No Recent Repositories", systemImage: "clock", description: Text("Repositories you open appear here."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.recents.urls, id: \.self) { url in
                            RecentRepositoryRow(url: url) {
                                model.open(url)
                            }
                            .contextMenu {
                                Button("Open") { model.open(url) }
                                Button("Reveal in Finder") { ExternalApps.revealInFinder(url) }
                                Divider()
                                Button("Remove from Recents") { model.recents.remove(url) }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }
}

private struct RecentRepositoryRow: View {
    let url: URL
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(url.abbreviatedPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(isHovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(url.path)
    }
}

struct AppGlyph: View {
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.45, blue: 0.24), Color(red: 0.86, green: 0.2, blue: 0.32)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .shadow(color: .black.opacity(0.18), radius: size * 0.08, y: size * 0.04)
    }
}

/// Shown when no usable Git executable is found.
struct GitMissingView: View {
    let model: RepositoryViewModel

    var body: some View {
        ContentUnavailableView {
            Label("Git Is Not Installed", systemImage: "exclamationmark.triangle")
        } description: {
            Text("GitView requires Git to perform repository operations. Install the Xcode Command Line Tools or Git from Homebrew, then check again.")
        } actions: {
            HStack {
                Button("Install Command Line Tools") {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
                    process.arguments = ["--install"]
                    try? process.run()
                }
                Button("Install Instructions") {
                    if let url = URL(string: "https://git-scm.com/download/mac") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Check Again", action: model.detectGit)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
