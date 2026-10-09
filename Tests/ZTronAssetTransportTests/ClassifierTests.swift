import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTransport

/// R-NET-6: the pure status, URL-error and `Retry-After` classification (transport.md §3.4.1–3.4.2 as amended by
/// ADR-031 and transport-1 TR1-4/6/7/11).
@Suite("Transfer classification")
struct ClassifierTests {
    /// One row of the status table.
    struct StatusRow: Sendable, CustomTestStringConvertible {
        var status: Int
        var purpose: TransferPurpose = .asset
        var sentConditional = false
        var resumed = false
        var keyWithheld = false
        var bodyBytes: Int64 = 0
        var xml = false
        var retryAfter: RetryAfter?
        var contentRangeStart: Int64?
        var expected: TransferError?

        var testDescription: String {
            "\(self.status) resumed=\(self.resumed) conditional=\(self.sentConditional) withheld=\(self.keyWithheld)"
        }

        var facts: ResponseFacts {
            ResponseFacts(
                status: self.status,
                bodyBytes: self.bodyBytes,
                contentTypeIsXML: self.xml,
                retryAfter: self.retryAfter,
                etag: nil,
                contentRangeStart: self.contentRangeStart,
                keyPresented: !self.keyWithheld
            )
        }
    }

    static let statusRows: [StatusRow] = [
        StatusRow(status: 200, expected: nil),
        StatusRow(status: 200, resumed: true, expected: nil),
        StatusRow(status: 206, resumed: true, contentRangeStart: 1_024, expected: nil),
        StatusRow(status: 206, resumed: true, contentRangeStart: nil, expected: .transient(.resumeRejected, retryAfter: nil)),
        StatusRow(status: 206, expected: .rejected(.unexpectedStatus(206))),
        StatusRow(status: 304, purpose: .manifest, sentConditional: true, expected: nil),
        StatusRow(status: 304, purpose: .manifest, expected: .rejected(.unexpectedNotModified)),
        StatusRow(status: 301, expected: .rejected(.redirectRefused(.invalidLocation))),
        StatusRow(status: 302, expected: .rejected(.redirectRefused(.invalidLocation))),
        StatusRow(status: 307, expected: .rejected(.redirectRefused(.invalidLocation))),
        StatusRow(status: 401, expected: .transient(.authenticationChallenge(httpStatus: 401), retryAfter: nil)),
        StatusRow(
            status: 403,
            bodyBytes: 0,
            expected: .authentication(.forbiddenAmbiguous(ForbiddenEvidence(
                purpose: .asset, bodyBytes: 0, contentTypeIsXML: false, keyPresented: true, resumed: false)))
        ),
        StatusRow(
            status: 403,
            purpose: .manifest,
            resumed: false,
            bodyBytes: 40,
            xml: true,
            expected: .authentication(.forbiddenAmbiguous(ForbiddenEvidence(
                purpose: .manifest, bodyBytes: 40, contentTypeIsXML: true, keyPresented: true, resumed: false)))
        ),
        StatusRow(status: 403, keyWithheld: true, expected: .rejected(.keyWithheldOnRedirect)),
        StatusRow(status: 404, expected: .permanentMissing(httpStatus: 404)),
        StatusRow(status: 410, expected: .permanentMissing(httpStatus: 410)),
        StatusRow(status: 408, retryAfter: .seconds(3), expected: .transient(.timedOut, retryAfter: .seconds(3))),
        StatusRow(status: 416, resumed: true, expected: .transient(.resumeRejected, retryAfter: nil)),
        StatusRow(status: 416, expected: .rejected(.unexpectedStatus(416))),
        StatusRow(status: 429, retryAfter: .seconds(7), expected: .transient(.throttled, retryAfter: .seconds(7))),
        StatusRow(status: 429, expected: .transient(.throttled, retryAfter: nil)),
        StatusRow(status: 500, expected: .transient(.serverError(httpStatus: 500), retryAfter: nil)),
        StatusRow(
            status: 503,
            retryAfter: .date(Date(timeIntervalSince1970: 1_792_567_680)),
            expected: .transient(.serverError(httpStatus: 503), retryAfter: .date(Date(timeIntervalSince1970: 1_792_567_680)))
        ),
        StatusRow(status: 599, expected: .transient(.serverError(httpStatus: 599), retryAfter: nil)),
        StatusRow(status: 400, expected: .rejected(.unexpectedStatus(400))),
        StatusRow(status: 201, expected: .rejected(.unexpectedStatus(201))),
        StatusRow(status: 100, expected: .rejected(.unexpectedStatus(100))),
    ]

    @Test("R-NET-6: HTTP statuses map to the closed taxonomy", arguments: ClassifierTests.statusRows)
    func statusTable(_ row: StatusRow) {
        let result = TransferClassifier.classify(
            row.facts,
            purpose: row.purpose,
            sentConditional: row.sentConditional,
            resumed: row.resumed,
            keyWithheld: row.keyWithheld
        )
        #expect(result == row.expected)
    }

    @Test("R-NET-6: a 403 is reported as forbiddenAmbiguous with evidence, never as notFound or a confirmed rejection")
    func forbiddenIsAmbiguous() throws {
        for purpose in TransferPurpose.allCases {
            for bodyBytes: Int64 in [0, 1, 40] {
                for xml in [false, true] {
                    let facts = ResponseFacts(
                        status: 403, bodyBytes: bodyBytes, contentTypeIsXML: xml, retryAfter: nil, etag: nil,
                        contentRangeStart: nil, keyPresented: true)
                    let result = TransferClassifier.classify(facts, purpose: purpose, sentConditional: false, resumed: false, keyWithheld: false)
                    guard case .authentication(.forbiddenAmbiguous(let evidence)) = result else {
                        Issue.record("403 \(purpose) \(bodyBytes) \(xml) → \(String(describing: result))")
                        continue
                    }
                    #expect(evidence.bodyBytes == bodyBytes && evidence.contentTypeIsXML == xml && evidence.purpose == purpose)
                    #expect(evidence.keyPresented)
                }
            }
        }
    }

    @Test("R-NET-6: an XML 403 on the manifest is object-missing-likely, never key rejection")
    func xmlManifestForbiddenIsObjectMissing() throws {
        let facts = ResponseFacts(
            status: 403, bodyBytes: 243, contentTypeIsXML: true, retryAfter: nil, etag: nil, contentRangeStart: nil, keyPresented: true)
        let result = TransferClassifier.classify(facts, purpose: .manifest, sentConditional: true, resumed: false, keyWithheld: false)
        guard case .authentication(.forbiddenAmbiguous(let evidence)) = result else {
            Issue.record("\(String(describing: result))")
            return
        }
        #expect(evidence.hint == .objectMissingLikely)
    }

    /// One row of the URL-error table.
    struct ErrorRow: Sendable, CustomTestStringConvertible {
        var code: Int
        var unavailable: Int?
        var cancelReason: Int?
        var resumed = false
        var posix: Int32?
        var expected: TransferError

        var testDescription: String {
            "\(self.code) unavailable=\(String(describing: self.unavailable)) resumed=\(self.resumed)"
        }
    }

    static let errorRows: [ErrorRow] = [
        ErrorRow(code: -999, expected: .cancelled(.byClient)),
        ErrorRow(code: -999, cancelReason: 0, expected: .cancelled(.bySystem(.userForceQuitApplication))),
        ErrorRow(code: -999, cancelReason: 1, expected: .cancelled(.bySystem(.backgroundUpdatesDisabled))),
        ErrorRow(code: -999, cancelReason: 2, expected: .cancelled(.bySystem(.insufficientSystemResources))),
        ErrorRow(code: -999, cancelReason: 9, expected: .cancelled(.bySystem(.unknown(9)))),
        ErrorRow(code: -1001, expected: .transient(.timedOut, retryAfter: nil)),
        ErrorRow(code: -1005, expected: .transient(.connectionLost(resumable: false), retryAfter: nil)),
        ErrorRow(code: -1004, expected: .transient(.cannotConnect, retryAfter: nil)),
        ErrorRow(code: -1003, expected: .transient(.dnsFailure, retryAfter: nil)),
        ErrorRow(code: -1006, expected: .transient(.dnsFailure, retryAfter: nil)),
        ErrorRow(code: -1009, expected: .offline(.noConnection)),
        ErrorRow(code: -1009, unavailable: 0, expected: .offline(.cellularDenied)),
        ErrorRow(code: -1009, unavailable: 1, expected: .offline(.expensiveDenied)),
        ErrorRow(code: -1009, unavailable: 2, expected: .offline(.constrainedDenied)),
        ErrorRow(code: -1018, expected: .offline(.roamingDisabled)),
        ErrorRow(code: -1019, expected: .offline(.callActive)),
        ErrorRow(code: -1020, expected: .offline(.cellularDenied)),
        ErrorRow(code: -1007, expected: .rejected(.redirectRefused(.tooManyRedirects))),
        ErrorRow(code: -1010, expected: .rejected(.redirectRefused(.invalidLocation))),
        ErrorRow(code: -1022, expected: .rejected(.insecureScheme)),
        ErrorRow(code: -1000, expected: .rejected(.invalidURL)),
        ErrorRow(code: -1002, expected: .rejected(.invalidURL)),
        ErrorRow(code: -1002, resumed: true, expected: .transient(.resumeRejected, retryAfter: nil)),
        ErrorRow(code: -1012, expected: .transient(.authenticationChallenge(httpStatus: 0), retryAfter: nil)),
        ErrorRow(code: -1013, expected: .transient(.authenticationChallenge(httpStatus: 0), retryAfter: nil)),
        ErrorRow(code: -1011, expected: .transient(.badServerResponse, retryAfter: nil)),
        ErrorRow(code: -1017, expected: .transient(.badServerResponse, retryAfter: nil)),
        ErrorRow(code: -1014, expected: .integrity(.truncated(expected: nil, received: 0))),
        ErrorRow(code: -1015, expected: .integrity(.undecodableContent(urlErrorCode: -1015))),
        ErrorRow(code: -1016, expected: .integrity(.undecodableContent(urlErrorCode: -1016))),
        ErrorRow(code: -3006, expected: .integrity(.undecodableContent(urlErrorCode: -3006))),
        ErrorRow(code: -3007, expected: .integrity(.undecodableContent(urlErrorCode: -3007))),
        ErrorRow(code: -1200, expected: .transient(.secureConnectionFailed(urlErrorCode: -1200), retryAfter: nil)),
        ErrorRow(code: -1206, expected: .transient(.secureConnectionFailed(urlErrorCode: -1206), retryAfter: nil)),
        ErrorRow(code: -3000, posix: ENOSPC, expected: .insufficientSpace(requiredBytes: nil)),
        ErrorRow(code: -3003, posix: EACCES, expected: .transient(.localIO(posixCode: EACCES), retryAfter: nil)),
        ErrorRow(code: -3005, expected: .transient(.localIO(posixCode: 0), retryAfter: nil)),
        ErrorRow(code: -995, expected: .transient(.backgroundSessionUnavailable(urlErrorCode: -995), retryAfter: nil)),
        ErrorRow(code: -996, expected: .transient(.backgroundSessionUnavailable(urlErrorCode: -996), retryAfter: nil)),
        ErrorRow(code: -997, expected: .transient(.backgroundSessionUnavailable(urlErrorCode: -997), retryAfter: nil)),
        ErrorRow(code: -1, expected: .transient(.unknown(urlErrorCode: -1), retryAfter: nil)),
        ErrorRow(code: -1103, expected: .transient(.unknown(urlErrorCode: -1103), retryAfter: nil)),
    ]

    @Test("R-NET-6: URL error codes map to the closed taxonomy", arguments: ClassifierTests.errorRows)
    func urlErrorTable(_ row: ErrorRow) {
        let result = TransferClassifier.classify(
            urlErrorCode: row.code,
            networkUnavailableReason: row.unavailable,
            backgroundCancelReason: row.cancelReason,
            resumed: row.resumed,
            underlyingPOSIXCode: row.posix
        )
        #expect(result == row.expected)
    }

    /// One `Retry-After` vector.
    struct RetryRow: Sendable, CustomTestStringConvertible {
        var value: String
        var expected: RetryAfter?

        var testDescription: String {
            "\"\(self.value)\""
        }
    }

    static let retryRows: [RetryRow] = [
        RetryRow(value: "7", expected: .seconds(7)),
        RetryRow(value: " 120\t", expected: .seconds(120)),
        RetryRow(value: "0", expected: .seconds(0)),
        RetryRow(value: "4294967295", expected: .seconds(4_294_967_295)),
        // E-15: the RFC 9110 example in each of the three formats.
        RetryRow(value: "Sun, 06 Nov 1994 08:49:37 GMT", expected: .date(Date(timeIntervalSince1970: 784_111_777))),
        RetryRow(value: "Sunday, 06-Nov-94 08:49:37 GMT", expected: .date(Date(timeIntervalSince1970: 784_111_777))),
        RetryRow(value: "Sun Nov  6 08:49:37 1994", expected: .date(Date(timeIntervalSince1970: 784_111_777))),
        RetryRow(value: "Sun Nov 06 08:49:37 1994", expected: .date(Date(timeIntervalSince1970: 784_111_777))),
        // The prototype's off-by-one month: October must stay October (E-8).
        RetryRow(value: "Wed, 21 Oct 2026 07:28:00 GMT", expected: .date(Date(timeIntervalSince1970: 1_792_567_680))),
        RetryRow(value: "Thu, 29 Feb 2024 12:00:00 GMT", expected: .date(Date(timeIntervalSince1970: 1_709_208_000))),
        RetryRow(value: "Saturday, 01-Jan-00 00:00:00 GMT", expected: .date(Date(timeIntervalSince1970: 946_684_800))),
        RetryRow(value: "Monday, 31-Dec-68 23:59:59 GMT", expected: .date(Date(timeIntervalSince1970: 3_124_223_999))),
        RetryRow(value: "Wednesday, 01-Jan-69 00:00:00 GMT", expected: .date(Date(timeIntervalSince1970: -31_536_000))),
    ]

    @Test("R-NET-6: Retry-After parses delta-seconds and all three HTTP-date formats", arguments: ClassifierTests.retryRows)
    func retryAfterVectors(_ row: RetryRow) {
        #expect(RetryAfterParser.parse(row.value) == row.expected)
    }

    @Test("R-NET-6: an unparsable, negative or over-long Retry-After is treated as absent", arguments: [
        "", "   ", "abc", "-5", "+5", "1.5", "12345678901", "4294967296", "７",
        "Sun, 06 Nov 1994 08:49:37 UTC", "sun, 06 Nov 1994 08:49:37 GMT", "Sun, 06 nov 1994 08:49:37 GMT",
        "Sun, 31 Feb 1994 08:49:37 GMT", "Sun, 29 Feb 2100 08:49:37 GMT", "Sun, 00 Nov 1994 08:49:37 GMT",
        "Sun, 06 Nov 1994 24:00:00 GMT", "Sun, 06 Nov 1994 08:60:00 GMT", "Sun, 06 Nov 1994 08:49:61 GMT",
        "Sun, 06 Nov 1994 08:49 GMT", "Sun, 6 Nov 1994 08:49:37 GMT", "Sun 06 Nov 1994 08:49:37 GMT",
        "Sunday, 06-Nov-1994 08:49:37 GMT", "Sundae, 06-Nov-94 08:49:37 GMT", "Sunday,06-Nov-94 08:49:37 GMT",
        "Sun Nov  6 08:49:37 94", "Sun Nov 6 08:49:37 1994", "Sun Nov  x 08:49:37 1994", "Sun Nov  6 08-49-37 1994",
        String(repeating: "9", count: 80),
    ])
    func retryAfterGarbage(_ value: String) {
        #expect(RetryAfterParser.parse(value) == nil)
    }
}
