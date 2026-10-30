import Foundation
import HephCore
import Network

/// A browser of _hephaestus._tcp. NWBrowser and state confined to one serial queue.
///
/// `@unchecked Sendable`: the NWBrowser and the mutable state are touched only on `queue`
/// (`ca.azavech.hephaestus.browser`).
public final class BonjourBrowser: @unchecked Sendable {
    public init() {}

    /// Starts browsing; onChange receives the full list after every change, on the browser's queue.
    public func start(onChange: @escaping @Sendable ([BonjourAdvert]) -> Void) {
        queue.async {
            self.onChange = onChange
            self.running = true
            self.makeBrowser()
        }
    }

    public func stop() {
        queue.async {
            self.running = false
            self.onChange = nil
            self.restart?.cancel()
            self.restart = nil
            self.browser?.cancel()
            self.browser = nil
        }
    }

    // MARK: - State

    private let queue = DispatchQueue(label: "ca.azavech.hephaestus.browser")

    // Confined to `queue`.
    private var browser: NWBrowser?
    private var onChange: (@Sendable ([BonjourAdvert]) -> Void)?
    private var running = false
    private var restart: Task<Void, Never>?

    deinit {
        restart?.cancel()
        browser?.cancel()
    }

    /// On the queue.
    private func makeBrowser() {
        restart?.cancel()
        restart = nil
        browser?.cancel()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: MeshConstants.serviceType, domain: nil),
                                using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser, self.browser === browser else { return }
            self.resultsChanged(results)
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser, self.browser === browser else { return }
            self.stateChanged(state)
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    /// On the queue. `.failed`: the browser is recreated after 5 s. `.waiting` (for example local network access
    /// denied) is logged; the browser keeps running and delivers results once access is granted.
    private func stateChanged(_ state: NWBrowser.State) {
        switch state {
        case .failed(let error):
            Log.net.error("Bonjour browsing failed: \(error.debugDescription)")
            browser?.cancel()
            browser = nil
            restart = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                guard let self else { return }
                self.queue.async {
                    guard self.running, self.browser == nil else { return }
                    self.makeBrowser()
                }
            }
        case .waiting(let error):
            Log.net.notice("Bonjour browsing is waiting: \(error.debugDescription)")
        default:
            break
        }
    }

    /// On the queue: the list rebuilt from all current results. Results that do not parse are dropped; when two
    /// results carry the same id, the later one in iteration order wins.
    private func resultsChanged(_ results: Set<NWBrowser.Result>) {
        var adverts: [BonjourAdvert] = []
        var indexByID: [UUID: Int] = [:]
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint,
                  case .bonjour(let txt) = result.metadata,
                  let advert = BonjourTXT.parse(name: name, txt: txt)
            else { continue }
            if let index = indexByID[advert.id] {
                adverts[index] = advert
            } else {
                indexByID[advert.id] = adverts.count
                adverts.append(advert)
            }
        }
        onChange?(adverts)
    }
}
