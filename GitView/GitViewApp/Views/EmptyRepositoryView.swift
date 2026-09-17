import SwiftUI

struct EmptyRepositoryView: View {
    let openAction: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("Open a Repository")
                    .font(.title2.weight(.semibold))
                Text("Choose an existing Git working copy on this Mac.")
                    .foregroundStyle(.secondary)
            }

            Button(action: openAction) {
                Label("Open Repository", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
