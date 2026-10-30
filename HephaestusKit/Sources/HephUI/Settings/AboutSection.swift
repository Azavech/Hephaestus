import Foundation
import HephCore
import SwiftUI

/// The version of the app and the docs hash it was generated from, in the iOS and iPadOS settings
/// (docs/ui/settings.md, "About").
struct AboutSection: View {
    init() {}

    var body: some View {
        Section("About") {
            LabeledContent("Version", value: Self.version)
            LabeledContent("Docs") {
                Text(DocsHash.embedded)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
        }
    }

    /// "<CFBundleShortVersionString> (build <CFBundleVersion>)" of the main bundle.
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "\(shortVersion) (build \(build))"
    }
}
