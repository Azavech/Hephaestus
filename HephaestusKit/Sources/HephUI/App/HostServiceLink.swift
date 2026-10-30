#if os(macOS)
import HephClient
import HephHost
import HephNet

/// The in-process link of this Mac's Workspace to its `HostService` (docs/ui/shell.md §3.3).
struct HostServiceLink: LocalHostLink {
    let host: HostService

    /// The client end of a new loopback channel whose server end the host serves.
    func makeChannel() async throws -> any MessageChannel {
        await host.makeLoopbackChannel()
    }
}
#endif
