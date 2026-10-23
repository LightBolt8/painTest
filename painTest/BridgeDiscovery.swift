import Combine
import Foundation
import Network

/// Finds the Mac OpenFace bridge on the local network via Bonjour (`_paintest._tcp`),
/// so the app works on home Wi‑Fi without pasting a tunnel URL.
@MainActor
final class BridgeDiscovery: ObservableObject {
    static let shared = BridgeDiscovery()
    static let serviceType = "_paintest._tcp"

    @Published private(set) var lanURL: String?
    @Published private(set) var serviceName: String?
    @Published private(set) var isBrowsing = false

    private var browser: NWBrowser?
    private var resolver: NWConnection?
    private let queue = DispatchQueue(label: "painTest.bridgeDiscovery")

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.handle(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isBrowsing = true
                case .failed:
                    self?.isBrowsing = false
                    self?.restart()
                case .cancelled:
                    self?.isBrowsing = false
                default:
                    break
                }
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func restart() {
        browser?.cancel()
        browser = nil
        resolver?.cancel()
        resolver = nil
        lanURL = nil
        serviceName = nil
        start()
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        guard let result = results.first else {
            resolver?.cancel()
            resolver = nil
            lanURL = nil
            serviceName = nil
            return
        }
        if case let .service(name, _, _, _) = result.endpoint {
            serviceName = name
        }
        resolve(result.endpoint)
    }

    private func resolve(_ endpoint: NWEndpoint) {
        resolver?.cancel()
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let url = Self.httpURL(from: connection.currentPath?.remoteEndpoint)
                connection.cancel()
                Task { @MainActor in self?.lanURL = url }
            case .failed:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        resolver = connection
    }

    nonisolated private static func httpURL(from endpoint: NWEndpoint?) -> String? {
        guard case let .hostPort(host, port) = endpoint else { return nil }
        let hostString: String
        switch host {
        case .ipv4(let address):
            hostString = stripInterface("\(address)")
        case .ipv6(let address):
            hostString = "[\(stripInterface("\(address)"))]"
        case .name(let name, _):
            hostString = name
        @unknown default:
            return nil
        }
        return "http://\(hostString):\(port.rawValue)"
    }

    nonisolated private static func stripInterface(_ address: String) -> String {
        address.split(separator: "%").first.map(String.init) ?? address
    }
}
