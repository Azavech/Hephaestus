import HephClient
import SwiftUI

/// The shell of a window (docs/ui/shell.md §6.1): the sidebar and the detail of the selected section, the search
/// palette and the shell sheets.
struct MainShell: View {
    @Environment(WindowContext.self) private var context
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        @Bindable var context = context
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            DetailView()
        }
        .overlay {
            if !context.isCompact && context.isSearchPresented {
                SearchPalette()
            }
        }
        .sheet(item: $context.sheet) { sheet in
            sheetContent(sheet)
        }
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 500)
        #endif
        .onAppear(perform: updateCompact)
        #if os(iOS)
        .onChange(of: horizontalSizeClass) {
            updateCompact()
        }
        #endif
    }

    /// `context.isCompact` from the horizontal size class; always false on macOS.
    private func updateCompact() {
        #if os(iOS)
        let isCompact = horizontalSizeClass == .compact
        #else
        let isCompact = false
        #endif
        if context.isCompact != isCompact {
            context.isCompact = isCompact
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: ShellSheet) -> some View {
        switch sheet {
        case .pathPicker:
            PathPickerSheet()
        case .newProject(let mainDeviceID):
            NewProjectSheet(mainDeviceID: mainDeviceID, parentID: nil)
        case .addExistingFolder(let mainDeviceID):
            AddExistingFolderSheet(mainDeviceID: mainDeviceID)
        case .search:
            SearchScreen()
        }
    }
}

#Preview {
    let appModel = AppModel.preview()
    let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    MainShell()
        .previewWindow(appModel, selection: Selection(mainDeviceID: studio))
}
