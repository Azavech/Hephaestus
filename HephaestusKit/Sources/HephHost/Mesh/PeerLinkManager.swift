#if os(macOS)
import Foundation
import HephCore
import HephNet

/// The outgoing peer links of a Main (docs/devices/mesh.md, "Peer links"): one link per Main to reach, dialed with
/// backoff, carrying hello, mesh.sync and the events of the other Main. Owned by MeshService and used only on its
/// actor: every method runs isolated to the MeshService it is given.
final class PeerLinkManager {
    private final class Link {
        let mainID: UUID
        /// Changes when the link is torn down or redialed; a loop of an older generation stops.
        var generation = 0
        var loop: Task<Void, Never>?
        var sleeper: Task<Void, Never>?
        var failures = 0
        var blockedUntilCredentialsChange = false
        var blockedUntilRecordChange = false
        /// The peer of the attempt in progress.
        var dialing: RPCPeer?
        var established: Established?
        var syncTask: Task<Void, Never>?

        init(mainID: UUID) {
            self.mainID = mainID
        }
    }

    private struct Established {
        let peer: RPCPeer
        let device: DeviceInfo
        let connectionID: UUID
    }

    private enum Outcome {
        case established(Established, closed: Task<Void, Never>, relayed: [Presence])
        case failed
        case unauthorized
        case badRequest
    }

    private var started = false
    private var links: [UUID: Link] = [:]

    // MARK: - Lifecycle

    /// startPeerLinks(): a link per Main to reach; each tries at once.
    func start(mesh: isolated MeshService) {
        started = true
        reconcile(changedIDs: [], mesh: mesh)
    }

    /// stopPeerLinks(): closes every link and cancels the attempts.
    func stopAll(mesh: isolated MeshService) {
        started = false
        for link in links.values {
            tearDown(link, mesh: mesh)
        }
        links.removeAll()
    }

    /// After a registry change: a link for each new Main to reach; the link of a Main revoked or no longer a Main is
    /// closed and removed; a Main whose record changed tries at once.
    func reconcile(changedIDs: Set<UUID>, mesh: isolated MeshService) {
        guard started else { return }
        let targets = mesh.mainsToReach()
        for (mainID, link) in links where !targets.contains(mainID) {
            tearDown(link, mesh: mesh)
            links[mainID] = nil
        }
        for mainID in targets {
            if let link = links[mainID] {
                if changedIDs.contains(mainID) {
                    link.blockedUntilRecordChange = false
                    if link.established == nil {
                        link.sleeper?.cancel()
                    }
                }
            } else {
                let link = Link(mainID: mainID)
                links[mainID] = link
                launch(link, mesh: mesh)
            }
        }
    }

    /// The Bonjour advert of these Mains appeared or changed: their links try at once.
    func advertsChanged(_ mainIDs: Set<UUID>, mesh: isolated MeshService) {
        for mainID in mainIDs {
            guard let link = links[mainID], link.established == nil, !link.blockedUntilCredentialsChange,
                  !link.blockedUntilRecordChange
            else { continue }
            link.sleeper?.cancel()
        }
    }

    /// The key in use changed: every link is closed and redialed at once.
    func redialAll(mesh: isolated MeshService) {
        guard started else { return }
        for link in links.values {
            tearDown(link, mesh: mesh)
            link.failures = 0
            link.blockedUntilCredentialsChange = false
            launch(link, mesh: mesh)
        }
    }

    /// Closes the link to a revoked device; the reconciliation removes it.
    func close(_ mainID: UUID, mesh: isolated MeshService) {
        guard let link = links[mainID] else { return }
        tearDown(link, mesh: mesh)
        links[mainID] = nil
    }

    // MARK: - Queries

    func connectedMains() -> [DeviceInfo] {
        links.values.compactMap { $0.established?.device }
    }

    func establishedPeer(_ mainID: UUID) -> RPCPeer? {
        links[mainID]?.established?.peer
    }

    // MARK: - mesh.sync

    /// A mesh.sync on that link, `coalescingDelay` later.
    func scheduleSync(_ mainID: UUID, mesh: isolated MeshService) {
        guard let link = links[mainID], link.established != nil, link.syncTask == nil else { return }
        let generation = link.generation
        link.syncTask = Task {
            do {
                try await Task.sleep(for: MeshConstants.coalescingDelay)
            } catch {
                return
            }
            await mesh.sendLinkSync(mainID, generation: generation)
        }
    }

    func scheduleSyncAll(mesh: isolated MeshService) {
        for mainID in links.keys {
            scheduleSync(mainID, mesh: mesh)
        }
    }

    /// The coalesced mesh.sync of one link; its result is merged and stored as the Main's relayed entries.
    func sendSync(_ mainID: UUID, generation: Int, mesh: isolated MeshService) async {
        guard let link = links[mainID], link.generation == generation else { return }
        link.syncTask = nil
        guard let established = link.established else { return }
        let params = MeshSyncParams(devices: mesh.allRecords(), presence: mesh.directEntries())
        do {
            let result = try await established.peer.request(.meshSync, params, as: MeshSyncResult.self)
            guard link.generation == generation else { return }
            mesh.mergeRecords(result.devices)
            mesh.storeRelayed(result.presence, from: mainID)
        } catch {
            Log.host.error("mesh.sync with \(mainID.uuidString, privacy: .public) failed: \(ProjectRegistry.protocolError(error).message)")
        }
    }

    /// mesh.sync on every established link, in parallel, waiting at most `timeout` each (resignMain, revocation).
    func syncAll(timeout: Duration, mesh: isolated MeshService) async {
        let targets = links.values.compactMap { link -> (UUID, Int, RPCPeer)? in
            guard let established = link.established else { return nil }
            return (link.mainID, link.generation, established.peer)
        }
        guard !targets.isEmpty else { return }
        let params = MeshSyncParams(devices: mesh.allRecords(), presence: mesh.directEntries())
        let results = await withTaskGroup(of: (UUID, Int, MeshSyncResult?).self) { group in
            for (mainID, generation, peer) in targets {
                group.addTask {
                    do {
                        return (mainID, generation, try await peer.request(.meshSync, params, as: MeshSyncResult.self,
                                                                           timeout: timeout))
                    } catch {
                        Log.host.error("mesh.sync with \(mainID.uuidString, privacy: .public) failed: \(ProjectRegistry.protocolError(error).message)")
                        return (mainID, generation, nil)
                    }
                }
            }
            var results: [(UUID, Int, MeshSyncResult?)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        for (mainID, generation, result) in results {
            guard let result, links[mainID]?.generation == generation else { continue }
            mesh.mergeRecords(result.devices)
            mesh.storeRelayed(result.presence, from: mainID)
        }
    }

    // MARK: - Dialing

    /// The dial loop of one link, for one generation.
    func run(_ mainID: UUID, generation: Int, mesh: isolated MeshService) async {
        guard let link = links[mainID] else { return }
        while link.generation == generation, !Task.isCancelled {
            if link.blockedUntilCredentialsChange || link.blockedUntilRecordChange {
                await wait(link, for: nil, mesh: mesh)
                continue
            }
            let outcome = await attempt(link, generation: generation, mesh: mesh)
            guard link.generation == generation else { return }
            switch outcome {
            case .established(let established, let closed, let relayed):
                link.failures = 0
                link.established = established
                mesh.linkEstablished(established.device, connectionID: established.connectionID,
                                     peer: established.peer, relayed: relayed)
                await closed.value
                guard link.generation == generation else { return }
                link.established = nil
                link.syncTask?.cancel()
                link.syncTask = nil
                mesh.linkClosed(mainID, connectionID: established.connectionID)
                link.failures += 1
            case .failed:
                link.failures += 1
            case .unauthorized:
                link.blockedUntilCredentialsChange = true
                continue
            case .badRequest:
                link.blockedUntilRecordChange = true
                continue
            }
            let backoff = MeshConstants.backoff
            await wait(link, for: .seconds(backoff[min(link.failures, backoff.count) - 1]), mesh: mesh)
        }
    }

    /// One attempt: the addresses in order (docs/devices/mesh.md, "Dialing").
    private func attempt(_ link: Link, generation: Int, mesh: isolated MeshService) async -> Outcome {
        guard let credentials = mesh.credentials else { return .failed }
        let mainID = link.mainID
        for address in mesh.dialAddresses(for: mainID) {
            guard link.generation == generation, !Task.isCancelled else { return .failed }
            guard let url = WebSocketChannel.url(host: address.host, port: address.port,
                                                 path: MeshConstants.transportPath)
            else { continue }
            // 1. The channel.
            let channel: WebSocketChannel
            do {
                channel = try await WebSocketChannel.connect(url: url, credentials: credentials,
                                                             timeout: MeshConstants.addressTimeout)
            } catch MeshTransportError.authenticationFailed {
                return .failed
            } catch {
                continue
            }
            guard link.generation == generation else {
                channel.close()
                return .failed
            }
            // 2. The peer: it serves mesh.rekey and passes its events on.
            let peer = RPCPeer(channel: channel)
            await peer.setRequestHandler { [weak mesh] request in
                guard let mesh else { throw ProtocolError(.unavailable, "Not connected.") }
                return try await mesh.serveLinkRequest(request, from: mainID)
            }
            Task { [weak mesh] in
                for await event in peer.events {
                    await mesh?.linkEvent(event, mainID: mainID)
                }
            }
            let closed = Task { await peer.run() }
            link.dialing = peer
            defer { link.dialing = nil }
            do {
                // 3. hello.
                let reply = try await peer.request(.hello, HelloParams(device: mesh.localDeviceInfo(),
                                                                       protocolVersion: WireCoding.protocolVersion),
                                                   as: HelloResult.self)
                guard link.generation == generation else {
                    peer.close()
                    return .failed
                }
                // 4. The outcome.
                guard reply.device.id == mainID else {
                    peer.close()
                    continue
                }
                mesh.mergeRecords(reply.mesh.devices)
                guard link.generation == generation else {
                    peer.close()
                    return .failed
                }
                // 5. mesh.sync.
                let sync = try await peer.request(.meshSync, MeshSyncParams(devices: mesh.allRecords(),
                                                                            presence: mesh.directEntries()),
                                                  as: MeshSyncResult.self)
                guard link.generation == generation else {
                    peer.close()
                    return .failed
                }
                mesh.mergeRecords(sync.devices)
                guard link.generation == generation else {
                    peer.close()
                    return .failed
                }
                return .established(Established(peer: peer, device: reply.device, connectionID: UUID()),
                                    closed: closed, relayed: sync.presence)
            } catch let error as ProtocolError where error.code == .unauthorized {
                peer.close()
                return .unauthorized
            } catch let error as ProtocolError where error.code == .badRequest {
                peer.close()
                return .badRequest
            } catch {
                peer.close()
                continue
            }
        }
        return .failed
    }

    // MARK: - Private

    /// Starts a new loop for the link.
    private func launch(_ link: Link, mesh: isolated MeshService) {
        link.generation += 1
        let generation = link.generation
        let mainID = link.mainID
        link.loop = Task {
            await mesh.runPeerLink(mainID, generation: generation)
        }
    }

    /// Closes the link: its loop stops, its attempt or established connection closes.
    private func tearDown(_ link: Link, mesh: isolated MeshService) {
        link.generation += 1
        link.loop?.cancel()
        link.loop = nil
        link.sleeper?.cancel()
        link.sleeper = nil
        link.syncTask?.cancel()
        link.syncTask = nil
        link.dialing?.close()
        link.dialing = nil
        if let established = link.established {
            link.established = nil
            established.peer.close()
            mesh.linkClosed(link.mainID, connectionID: established.connectionID)
        }
    }

    /// Waits `delay` (nil: until woken); `sleeper.cancel()` wakes the link.
    private func wait(_ link: Link, for delay: Duration?, mesh: isolated MeshService) async {
        let sleeper = Task {
            if let delay {
                try? await Task.sleep(for: delay)
            } else {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3_600))
                }
            }
        }
        link.sleeper = sleeper
        await sleeper.value
        if link.sleeper == sleeper {
            link.sleeper = nil
        }
    }
}
#endif
