import SwiftUI
#if canImport(Shared)
import Shared
#endif

struct SidebarView: View {
    let snapshot: GitRepositorySnapshot?
    @Binding var selectedSection: AppSection
    let openAction: () -> Void
    let refreshAction: () -> Void

    var body: some View {
        List {
            Section {
                Button(action: openAction) {
                    Label("Open Repository", systemImage: "folder")
                }

                Button(action: refreshAction) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(snapshot == nil)
            }

            if let snapshot {
                Section("Repository") {
                    Label(snapshot.name, systemImage: "shippingbox")
                    Label(snapshot.branch, systemImage: "point.3.connected.trianglepath.dotted")
                    Label("\(snapshot.files.count) Changes", systemImage: "doc.text.magnifyingglass")
                }

                Section("Views") {
                    Button {
                        selectedSection = .changes
                    } label: {
                        Label("Changes", systemImage: "list.bullet.rectangle")
                    }

                    Label("History", systemImage: "clock")

                    Button {
                        selectedSection = .branches
                    } label: {
                        Label("Branches", systemImage: "arrow.triangle.branch")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("GitView")
    }
}
