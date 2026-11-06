import AppKit
import SwiftUI
#if canImport(Shared)
import Shared
#endif

struct ContentView: View {
    @State private var model = RepositoryViewModel()
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if model.gitService == nil {
                GitMissingView(model: model)
            } else if let snapshot = model.snapshot {
                RepositoryView(model: model, snapshot: snapshot)
            } else {
                WelcomeView(model: model, isDropTargeted: isDropTargeted)
                    .navigationTitle("GitView")
            }
        }
        .frame(minWidth: 980, minHeight: 620)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.hasDirectoryPath) ?? urls.first else {
                return false
            }
            model.open(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .onAppear {
            DeepLinkRouter.shared.register(model)
        }
        .background(WindowKeyObserver { DeepLinkRouter.shared.register(model) })
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Pick up changes made in an editor or Terminal while GitView was in the background.
            model.refresh()
        }
        .focusedSceneValue(\.repositoryModel, model)
        .alert(
            model.alert?.title ?? "GitView",
            isPresented: Binding(
                get: { model.alert != nil },
                set: { if !$0 { model.alert = nil } }
            ),
            presenting: model.alert
        ) { _ in
            Button("OK", role: .cancel) {}
            if !model.outputLog.isEmpty, model.snapshot != nil {
                Button("Show Output") { model.isShowingOutputLog = true }
            }
        } message: { alert in
            Text(alert.message)
        }
    }
}

/// Calls `onBecomeKey` whenever this view's window becomes the key window.
private struct WindowKeyObserver: NSViewRepresentable {
    let onBecomeKey: () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onBecomeKey = onBecomeKey
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onBecomeKey = onBecomeKey
    }

    final class ObserverView: NSView {
        var onBecomeKey: () -> Void = {}

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey), name: NSWindow.didBecomeKeyNotification, object: window)
            }
        }

        @objc private func windowDidBecomeKey() {
            onBecomeKey()
        }
    }
}

// MARK: - Focused model for menu commands

private struct RepositoryModelKey: FocusedValueKey {
    typealias Value = RepositoryViewModel
}

extension FocusedValues {
    var repositoryModel: RepositoryViewModel? {
        get { self[RepositoryModelKey.self] }
        set { self[RepositoryModelKey.self] = newValue }
    }
}
