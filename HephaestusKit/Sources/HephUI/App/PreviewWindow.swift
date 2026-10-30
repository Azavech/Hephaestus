import HephClient
import SwiftUI

extension View {
    /// The environment of a window around a preview (docs/ui/shell.md §5.4): the `AppModel` and the environment of
    /// `RootView` with one `WindowContext` of `selection`.
    public func previewWindow(_ appModel: AppModel, selection: Selection) -> some View {
        modifier(PreviewWindowModifier(appModel: appModel, selection: selection))
    }
}

/// Keeps the window context of a preview.
private struct PreviewWindowModifier: ViewModifier {
    let appModel: AppModel
    @State private var context: WindowContext

    init(appModel: AppModel, selection: Selection) {
        self.appModel = appModel
        _context = State(initialValue: WindowContext(selection: selection))
    }

    func body(content: Content) -> some View {
        content
            .environment(appModel)
            .environment(context)
            .environment(context.selection)
            .environment(context.banners)
            .environment(appModel.workspace)
            .environment(appModel.settings)
            #if os(macOS)
            .environment(appModel.updateModel)
            #endif
    }
}
