import HephClient
import HephCore
import SwiftUI

/// The card of a permission request in a transcript: pending, resolved or expired (docs/ui/sessions.md, "Permission
/// cards").
struct PermissionCard: View {
    let item: PermissionItem
    let model: SessionModel
    let projectRoot: String?

    @Environment(Workspace.self) private var workspace
    @Environment(WindowBanners.self) private var banners
    @State private var isResponding = false
    /// An answer failed with `conflict` or `notFound`: the card shows as expired until a decision arrives.
    @State private var isNoLongerPending = false
    @State private var isDenyMessagePresented = false
    @State private var denyMessage = ""

    private enum CardState {
        case pending, resolved(PermissionDecisionItem), expired
    }

    private var cardState: CardState {
        if let decision = item.decision {
            return .resolved(decision)
        }
        if !isNoLongerPending,
           model.info?.pendingPermissions.contains(where: { $0.requestID == item.requestID }) == true {
            return .pending
        }
        return .expired
    }

    private var isPending: Bool {
        if case .pending = cardState {
            return true
        }
        return false
    }

    var body: some View {
        let summary = ToolSummary.summary(toolName: item.toolName, inputJSON: item.input, projectRoot: projectRoot)
        let suggestions = PermissionSuggestions.summary(item.suggestions)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text("Claude wants to use \(ToolSummary.displayName(toolName: item.toolName))")
                    .font(.headline)
            }
            if !summary.isEmpty {
                Text(summary)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            if let description = item.description, !description.isEmpty, description != summary {
                Text(description)
                    .foregroundStyle(.secondary)
            }
            if let blockedPath = item.blockedPath {
                Text("Path: \(blockedPath)")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            DisclosureGroup("Input") {
                Text(ToolSummary.prettyPrinted(inputJSON: item.input))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            switch cardState {
            case .pending:
                pendingControls(suggestions: suggestions)
            case .resolved(let decision):
                outcome(decision)
            case .expired:
                Text("No longer pending")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isPending ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.separator), lineWidth: 1)
        )
        .onChange(of: item.decision) { _, decision in
            if decision != nil {
                isNoLongerPending = false
            }
        }
    }

    @ViewBuilder private func pendingControls(suggestions: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if isDenyMessagePresented {
                TextField("Message to Claude", text: $denyMessage)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    Button("Deny") {
                        let message = denyMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                        respond(.deny, message: message.isEmpty ? nil : message)
                    }
                    Button("Cancel") {
                        isDenyMessagePresented = false
                        denyMessage = ""
                    }
                    if isResponding {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .disabled(isResponding)
            } else {
                HStack(spacing: 8) {
                    Button("Allow Once") {
                        respond(.allow, message: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    if !suggestions.isEmpty {
                        Button("Always Allow") {
                            respond(.allowAlways, message: nil)
                        }
                        .buttonStyle(.bordered)
                    }
                    Menu {
                        Button("Deny with Message…") {
                            isDenyMessagePresented = true
                        }
                    } label: {
                        Text("Deny")
                    } primaryAction: {
                        respond(.deny, message: nil)
                    }
                    .fixedSize()
                    if isResponding {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .disabled(isResponding)
            }
            if !suggestions.isEmpty {
                Text("Always Allow adds: \(suggestions)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func outcome(_ decision: PermissionDecisionItem) -> some View {
        let device = ClaudeNames.deviceName(decision.deviceID, in: workspace) ?? "another device"
        let time = decision.at.formatted(date: .omitted, time: .shortened)
        let suffix = " from \(device) · \(time)"
        return Group {
            switch decision.decision {
            case .allow:
                Label {
                    Text("Allowed once" + suffix)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            case .allowAlways:
                Label {
                    Text("Always allowed" + suffix)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            case .deny:
                Label {
                    Text("Denied" + suffix)
                } icon: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    /// `model.respond(requestID:decision:message:)`; `conflict` and `notFound` show the card as expired until a
    /// decision arrives; every error shows the error banner.
    private func respond(_ decision: PermissionDecision, message: String?) {
        guard !isResponding else { return }
        isResponding = true
        let requestID = item.requestID
        Task {
            await banners.perform {
                do {
                    try await model.respond(requestID: requestID, decision: decision, message: message)
                    isDenyMessagePresented = false
                    denyMessage = ""
                } catch let error as ProtocolError where error.code == .conflict || error.code == .notFound {
                    isNoLongerPending = true
                    throw error
                }
            }
            isResponding = false
        }
    }
}

/// The suggestions summary of a permission request: one part per element of the list of each `addRules` or
/// `addDirectories` object of the `suggestions` JSON array, in order; an element of another shape gives no part. Parts
/// are joined with " · " (docs/ui/sessions.md, "Permission cards").
enum PermissionSuggestions {
    static func summary(_ suggestions: String?) -> String {
        guard let suggestions, let data = suggestions.data(using: .utf8),
              let objects = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return "" }
        var parts: [String] = []
        for case let object as [String: Any] in objects {
            switch object["type"] as? String {
            case "addRules":
                for case let rule as [String: Any] in (object["rules"] as? [Any]) ?? [] {
                    guard let toolName = rule["toolName"] as? String else { continue }
                    if let content = rule["ruleContent"] as? String {
                        parts.append("\(toolName)(\(content))")
                    } else {
                        parts.append(toolName)
                    }
                }
            case "addDirectories":
                for case let directory as String in (object["directories"] as? [Any]) ?? [] {
                    parts.append("access to \(directory)")
                }
            default:
                continue
            }
        }
        return parts.joined(separator: " · ")
    }
}
