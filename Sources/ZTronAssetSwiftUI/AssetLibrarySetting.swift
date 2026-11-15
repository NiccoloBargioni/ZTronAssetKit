import Foundation

/// The value of one knob: a flag, a number, a string, a URL, a set of host names, or a choice between cases.
///
/// The key-path steps of `AssetLibrary.Setup` accept only these, which is what keeps the chain free of options
/// values (ADR-058): `.storage(\.deletionGrace, 30)` compiles, while a step that would hand over a whole policy,
/// such as `.storage(\.self, StoragePolicy())` or `.tuning(\.retry, RetryPolicy())`, does not, because no policy
/// type conforms. A knob inside a nested policy is reached by a longer key path, `.tuning(\.retry.maxDelay, 60)`.
///
/// `BackgroundTransferPolicy` is left out on purpose, although it is a choice between cases: one of them carries an
/// options value, and `Setup.backgroundTransfers()` is the step that enables it.
public protocol AssetLibrarySetting {}

extension Bool: AssetLibrarySetting {}
extension Int: AssetLibrarySetting {}
extension Int64: AssetLibrarySetting {}
extension Double: AssetLibrarySetting {}
extension String: AssetLibrarySetting {}
extension URL: AssetLibrarySetting {}
extension Set: AssetLibrarySetting where Element == String {}
extension Optional: AssetLibrarySetting where Wrapped: AssetLibrarySetting {}
extension AppKey: AssetLibrarySetting {}
extension StorageBudget: AssetLibrarySetting {}
extension ThermalLevel: AssetLibrarySetting {}
extension PackRetention: AssetLibrarySetting {}
extension KeyRedirectExposure: AssetLibrarySetting {}
