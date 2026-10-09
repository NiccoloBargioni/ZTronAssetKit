import Foundation
import Testing
import ZTronAssetKit
import ZTronAssetTestSupport
import ZTronAssetTransport

extension ZTronAssetKitBenchmarks {
    /// P-10 (WP-D): connection reuse of the one foreground session against the loopback server, release
    /// configuration (ADR-010). The thresholds are `budgets.P-10.assets` and `budgets.P-10.connections_max`, read
    /// through `QualityBudgets`.
    @Suite("TransportBenchmarks")
    struct TransportBenchmarks {
        @available(macOS 15.0, iOS 18.0, *)
        @Test("P-10: 500 small assets over a loopback server use at most connections_max TCP connections", .timeLimit(.minutes(1)))
        func connectionReuse() async throws {
            let budgets = try QualityBudgets()
            let assets = Int(try #require(budgets.value("P-10", "assets")))
            let connectionsMax = Int(try #require(budgets.value("P-10", "connections_max")))
            let body = Data(repeating: 0x5a, count: 1_024)

            let server = LoopbackHTTPServer { _ in LoopbackResponse(body: body) }
            let port = try await server.start()
            let base = try #require(URL(string: "http://127.0.0.1:\(port)/"))
            let staging = FakeStagingSink()
            let policy = TransportSecurityPolicy.loopbackTesting(allowedHosts: ["127.0.0.1"])
            // The most connections a configuration can ask for (clamped to 8), and twice as many transfers in flight
            // as connections: the session's cap, not the caller's restraint, bounds the connection count (E-1b).
            let configuration = HTTPSourceConfiguration(baseURL: base, maxConnectionsPerHost: 64, requestTimeout: 10)
            let source = HTTPRemoteSource(
                configuration: configuration,
                staging: staging,
                policy: policy,
                foreground: ForegroundTransferBackend(
                    delegate: SessionDelegate(mode: .foreground, staging: staging, policy: policy),
                    maxConnectionsPerHost: configuration.maxConnectionsPerHost,
                    requestTimeout: configuration.requestTimeout,
                    appKey: AppKey("bench-key"),
                    log: .tapOnly(nil)
                ),
                background: nil,
                log: .tapOnly(nil)
            )

            let started = ContinuousClock.now
            let staged = await withTaskGroup(of: Bool.self) { group in
                var next = 0
                var staged = 0
                func add() {
                    let index = next
                    next += 1
                    group.addTask {
                        let request = TransferRequest(
                            id: .content(ContentHash.sha256(of: Data("p10-\(index)".utf8))),
                            attempt: TransferAttempt(epoch: 1, sequence: UInt32(index)),
                            remotePath: "p10/\(index).bin",
                            expectedBytes: Int64(body.count),
                            maxBytes: 1 << 20,
                            priority: .bulk
                        )
                        let handle = await source.transfer(request)
                        for await update in handle.updates {
                            if case .staged = update {
                                return true
                            }
                        }
                        return false
                    }
                }
                for _ in 0..<min(16, assets) {
                    add()
                }
                for await success in group {
                    staged += success ? 1 : 0
                    if next < assets {
                        add()
                    }
                }
                return staged
            }
            let elapsed = ContinuousClock.now - started
            let connections = await server.acceptedConnections
            let requests = await server.requests.count
            print("P-10 \(assets) assets: \(connections) TCP connections (max \(connectionsMax)), \(requests) requests, \(elapsed)")
            #expect(staged == assets)
            #expect(requests == assets)
            #expect(connections >= 1 && connections <= connectionsMax)
            await source.invalidate()
            await server.stop()
        }
    }
}
