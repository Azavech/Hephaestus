#if os(macOS)
import Foundation
import HephClient
import HephCore
import SwiftUI

/// Settings ▸ Skills: where the skills library of this Main lives (docs/ui/settings.md, "Skills").
struct SkillsSettingsPane: View {
    @Environment(AppModel.self) private var appModel

    init() {}

    var body: some View {
        if appModel.identity.isMain {
            Form {
                Section {
                    LabeledContent("Library folder") {
                        Text((appModel.appSupport.skillsFolder.path as NSString).abbreviatingWithTildeInPath)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                } footer: {
                    Text("Skills are created and edited in the Skills section. This folder is separate from ~/.claude.")
                }
            }
            .formStyle(.grouped)
        } else {
            EmptyStateView(symbol: "desktopcomputer", title: "This Mac is not a Main",
                           message: "The skills library lives on Mains. Turn on “Use this Mac as a Main” in General.")
        }
    }
}
#endif
