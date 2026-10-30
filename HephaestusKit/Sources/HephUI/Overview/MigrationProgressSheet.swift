import HephClient
import HephCore
import SwiftUI

/// The progress of one migration, from the latest `migration.progress` payload of `migrationID` that the window's
/// presenter keeps (docs/ui/overview.md, "Progress sheet"). There is no cancel: Hide dismisses the sheet and the move
/// continues.
struct MigrationProgressSheet: View {
    let migrationID: UUID
    let model: MigrationProgressPresenterModel
    /// Hide, Done and Close.
    let onClose: () -> Void

    var body: some View {
        let payload = model.payloads[migrationID]
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Moving “\(model.projectName(of: migrationID))”")
                    .font(.headline)
                if let payload {
                    Text(verbatim: "\(model.mainName(payload.fromDeviceID)) → \(model.mainName(payload.toDeviceID))")
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                progress(payload)
                if let payload {
                    Text(verbatim: "\(Self.bytes(payload.bytesDone)) of \(Self.bytes(payload.bytesTotal))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            stateLines(payload)
            HStack {
                Spacer()
                Button(buttonTitle(payload), action: onClose)
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(minWidth: 360, idealWidth: 420)
        #endif
    }

    /// `bytesDone` of `bytesTotal`; indeterminate while no payload has arrived or `bytesTotal` is 0.
    @ViewBuilder
    private func progress(_ payload: MigrationProgressPayload?) -> some View {
        if let payload, payload.bytesTotal > 0 {
            ProgressView(value: Double(min(max(payload.bytesDone, 0), payload.bytesTotal)),
                         total: Double(payload.bytesTotal))
        } else {
            ProgressView()
                .progressViewStyle(.linear)
        }
    }

    @ViewBuilder
    private func stateLines(_ payload: MigrationProgressPayload?) -> some View {
        if let payload {
            switch payload.state {
            case .preparing:
                Text("Preparing…")
            case .transferring:
                Text("Copying files…")
            case .committing:
                Text(verbatim: "Installing on \(model.mainName(payload.toDeviceID))…")
            case .completed:
                Text(verbatim: "Moved to \(model.mainName(payload.toDeviceID)).")
                    .foregroundStyle(.green)
            case .failed:
                Text(verbatim: "Move failed: \(payload.error ?? "")")
                    .foregroundStyle(.red)
                Text(verbatim: "The project stays on \(model.mainName(payload.fromDeviceID)).")
            }
        } else {
            Text("Starting…")
        }
    }

    /// Hide while the move runs, Done after `completed`, Close after `failed`.
    private func buttonTitle(_ payload: MigrationProgressPayload?) -> String {
        switch payload?.state {
        case .completed:
            return "Done"
        case .failed:
            return "Close"
        case .preparing, .transferring, .committing, nil:
            return "Hide"
        }
    }

    private static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
