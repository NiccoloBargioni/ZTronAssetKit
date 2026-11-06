import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync

@Suite("TMP boundary probe")
struct TmpBoundaryProbeTests {
    @Test("TMP: R-SYN-5 a window whose 5xx share equals serverErrorRatio exactly opens the breaker")
    func ratioBoundary() {
        var breaker = CircuitBreaker(policy: CircuitBreakerPolicy())
        let now = EngineSupportTests.origin
        for n in 0..<3 {
            breaker.record(.objectSuccess(EngineSupportTests.transfer(n)), at: now, seed: 3)
        }
        for n in 10..<12 {
            breaker.record(.failure(EngineSupportTests.transfer(n), .serverErrors, distinctAsset: nil), at: now, seed: 3)
        }
        #expect(breaker.state == .closed, "2 of 5 is 0.4, below the 0.5 ratio")
        breaker.record(.failure(EngineSupportTests.transfer(12), .serverErrors, distinctAsset: nil), at: now, seed: 3)
        #expect(breaker.state == .open(cause: .serverErrors, until: now.adding(seconds: 30), trips: 1), "3 of 6 is exactly the 0.5 ratio")
    }

    @Test("TMP: R-SYN-5 a Retry-After equal to maxRetryAfter is honoured, one above it defers to the next run")
    func retryAfterBoundary() throws {
        let policy = RetryPolicy.background
        let delay = try #require(Backoff.delay(attempt: 1, retryAfter: policy.maxRetryAfter, policy: policy, seed: 1, key: 1))
        #expect(delay >= policy.maxRetryAfter)
        #expect(Backoff.delay(attempt: 1, retryAfter: policy.maxRetryAfter + 1, policy: policy, seed: 1, key: 1) == nil)
    }
}
