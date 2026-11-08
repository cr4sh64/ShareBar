import Network
import XCTest
@testable import ShareBar

/// Tests réseau 100 % locaux (127.0.0.1) : ils passent sans NAS, y compris en CI.
final class NetworkTests: XCTestCase {
    func testRouteToLoopback() {
        XCTAssertEqual(Route.source(to: "127.0.0.1"), "127.0.0.1")
    }

    func testNoRouteForUnresolvableHost() {
        XCTAssertNil(Route.source(to: "nom-inexistant.invalid"))
    }

    func testProbeSucceedsOnListeningPort() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        let ready = expectation(description: "listener prêt")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .main)
        defer { listener.cancel() }
        wait(for: [ready], timeout: 2)

        let probed = expectation(description: "sonde")
        Probe.tcp(host: "127.0.0.1", port: listener.port!.rawValue) { ok in
            XCTAssertTrue(ok)
            probed.fulfill()
        }
        wait(for: [probed], timeout: 3)
    }

    func testProbeFailsFastOnClosedPort() {
        let start = Date()
        let probed = expectation(description: "sonde")
        Probe.tcp(host: "127.0.0.1", port: 1) { ok in // port 1 : rien n'écoute
            XCTAssertFalse(ok)
            probed.fulfill()
        }
        wait(for: [probed], timeout: 3)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5)
    }

    func testProbeTimesOut() {
        let probed = expectation(description: "sonde")
        // 192.0.2.0/24 (TEST-NET-1) n'est jamais attribuée : pas de réponse, ou pas de route.
        Probe.tcp(host: "192.0.2.1", port: 445, timeout: 0.5) { ok in
            XCTAssertFalse(ok)
            probed.fulfill()
        }
        wait(for: [probed], timeout: 2)
    }
}
