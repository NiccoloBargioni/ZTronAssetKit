import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync

@Suite("TMP backoff probe")
struct TmpBackoffProbeTests {
    @Test("TMP: R-SYN-5 the backoff ceiling doubles with every attempt, so some key draws above the previous attempt's ceiling")
    func backoffCeilingDoubles() throws {
        let policy = RetryPolicy.background
        for attempt in 2...6 {
            let ceiling = min(policy.maxDelay, policy.baseDelay * pow(2, Double(attempt - 1)))
            let previous = min(policy.maxDelay, policy.baseDelay * pow(2, Double(attempt - 2)))
            guard ceiling > previous else { continue }
            let draws = try (1...200).map { key in
                try #require(Backoff.delay(attempt: attempt, retryAfter: nil, policy: policy, seed: 0x5EED, key: UInt64(key)))
            }
            #expect(draws.max()! > previous, "attempt \(attempt): no draw above the previous ceiling \(previous)")
            #expect(draws.max()! <= ceiling)
        }
    }
}
