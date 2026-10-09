import Foundation

/// The background session's configuration (transport.md §10.4), built on the tested side so the device-only driver
/// stays decision-free and under its line ceiling (ARCHITECTURE §14). Building a configuration creates no session
/// and performs no I/O.
package enum BackgroundSessionConfiguration {
    /// No cache, cookies or credentials, no `httpAdditionalHeaders` (the key is only ever a per-request header,
    /// R-NET-4), launch events on (R-NET-3), discretionary as the owner configured, four connections per host.
    package static func make(identifier: BackgroundSessionIdentifier, discretionary: Bool) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier.rawValue)
        configuration.isDiscretionary = discretionary
        configuration.sessionSendsLaunchEvents = true
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = [:]
        configuration.httpMaximumConnectionsPerHost = 4
        return configuration
    }
}
