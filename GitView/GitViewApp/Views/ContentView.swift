import SwiftUI
#if canImport(Shared)
import Shared
#endif

struct ContentView: View {
    @StateObject private var viewModel = RepositoryViewModel()

    var body: some View {
        NavigationSplitView {
            SidebarView(
                snapshot: viewModel.snapshot,
                selectedSection: $viewModel.selectedSection,
                openAction: viewModel.chooseRepository,
                refreshAction: viewModel.refresh
            )
        } detail: {
            RepositoryDetailView(viewModel: viewModel)
        }
        .onOpenURL { url in
            viewModel.openRepository(fromDeepLink: url)
        }
    }
}
