import Foundation

/// What `GET /version` said, plus the version Thrall decided to speak.
public struct ThrallEngineVersion: Equatable, Sendable {
    public let engineVersion: String
    public let apiVersion: ThrallAPIVersion
    public let minimumAPIVersion: ThrallAPIVersion?
    public let platformName: String?
    public let os: String
    public let arch: String
    /// The version every subsequent request will be pathed with.
    public let negotiated: ThrallAPIVersion

    public var pathPrefix: String { negotiated.pathPrefix }
}

/// The version handshake.
///
/// **Negotiated, never hardcoded.** The path `/v1.51/...` works against this
/// machine's engine (which reports 1.54) and fails against a Podman compat
/// layer, which lags — and Podman is a first-class target because Thrall
/// replaces the *Desktop app*, not the runtime. The handshake itself is
/// therefore sent **unversioned**: a version probe that needs a version to
/// reach is a bootstrap problem, and `GET /version` has answered unversioned
/// since the API existed.
public enum ThrallEngineNegotiation {
    /// The newest version Thrall is written against. Not raised casually:
    /// every endpoint used must exist at this version.
    public static let target = ThrallAPIVersion(major: 1, minor: 51)
    /// Below this, fail closed rather than degrade. `/system/df`'s build-cache
    /// section and the multiplexed log content type are both younger than
    /// 1.41, and half-working is worse here than not starting.
    public static let floor = ThrallAPIVersion(major: 1, minor: 41)

    public static func negotiate(reported: ThrallAPIVersion,
                                 serverMinimum: ThrallAPIVersion?) throws -> ThrallAPIVersion {
        let chosen = min(target, reported)
        guard chosen >= floor else {
            throw ThrallEngineError.apiTooOld(reported: reported.description,
                                              minimumSupported: floor.description)
        }
        if let serverMinimum, chosen < serverMinimum {
            // Unreachable while `floor` is above every shipping engine's
            // minimum — this daemon reports 1.40 — but it is the check that
            // keeps raising `floor` from silently pinning a path the server
            // refuses.
            throw ThrallEngineError.apiNotServable(chosen: chosen.description,
                                                   serverMinimum: serverMinimum.description)
        }
        return chosen
    }
}
