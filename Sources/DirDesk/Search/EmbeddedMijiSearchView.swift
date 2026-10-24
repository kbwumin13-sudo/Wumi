import SwiftUI

/// Desktop and Floating Files share Miji's view and read-only query session.
/// Only the available width changes; neither surface owns another index host.
struct EmbeddedMijiSearchView: View {
    let context: URL?
    var currentFolderOnly = false
    let onReveal: (URL) -> Void
    let onDismiss: () -> Void
    @StateObject private var model = MijiSearchModel()

    var body: some View {
        MijiSearchView(model: configuredModel(), onDismiss: onDismiss, onAdvanced: {
            onDismiss()
            FileOpenRouter.delegate?.windows.showAdvancedSearch(scope: context, controller: FileOpenRouter.delegate?.activeController)
        }, onSettings: {
            onDismiss()
            FileOpenRouter.delegate?.windows.showSettings(section: "lightningSearch")
        }, embedded: true)
        .onAppear {
            model.context = context
            model.currentFolderOnly = currentFolderOnly
            model.onReveal = onReveal
            model.onDismiss = onDismiss
            model.setSearchVisible(true)
            model.focusSearch = UUID()
        }
        .onDisappear { model.setSearchVisible(false) }
        .onChange(of: context) { _, value in model.context = value }
    }

    private func configuredModel() -> MijiSearchModel {
        // These callbacks capture the current desktop widget and container state.
        // Refresh them with the view so resizing never restores an earlier frame.
        model.onReveal = onReveal
        model.onDismiss = onDismiss
        return model
    }
}
