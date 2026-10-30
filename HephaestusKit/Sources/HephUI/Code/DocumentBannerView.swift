import Foundation
import HephClient
import SwiftUI

/// The banner of a document: a save refused by a conflict, a change or a deletion on the Main while the document is
/// modified (docs/ui/code.md, "Banner"). Also used by the Docs section.
struct DocumentBannerView: View {
    let document: EditorDocument

    var body: some View {
        if let banner = document.banner {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message(banner))
                    .lineLimit(2)
                Spacer(minLength: 0)
                buttons(banner)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color.yellow.opacity(0.2))
        }
    }

    private func message(_ banner: DocumentBanner) -> String {
        switch banner {
        case .conflict:
            return "This file changed on the Main. Your changes are not saved."
        case .changedOnMain:
            return "Changed on the Main"
        case .deletedOnMain:
            return "Deleted on the Main"
        }
    }

    @ViewBuilder
    private func buttons(_ banner: DocumentBanner) -> some View {
        let isConnected = document.files.isConnected
        switch banner {
        case .conflict:
            Button("Reload") {
                run { await $0.reload() }
            }
            .disabled(!isConnected)
            Button("Overwrite") {
                run { await $0.overwrite() }
            }
            .disabled(!isConnected)
        case .changedOnMain:
            Button("Reload") {
                run { await $0.reload() }
            }
            .disabled(!isConnected)
            Button("Keep Mine") {
                run { await $0.keepMine() }
            }
            .disabled(!isConnected)
        case .deletedOnMain:
            Button("Save") {
                run { await $0.recreate() }
            }
            .disabled(!isConnected)
            Button("Close") {
                // Closes the document without saving, as a deletion on the Main does.
                document.onRemoved?(document)
            }
        }
    }

    private func run(_ action: @escaping @MainActor (EditorDocument) async -> Void) {
        let document = document
        Task {
            await action(document)
        }
    }
}
