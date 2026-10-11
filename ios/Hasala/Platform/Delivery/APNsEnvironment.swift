import Foundation

/// Which APNs environment this build's device tokens belong to, as the server's
/// `PUT /push/apns` expects it (spec 06 §11).
///
/// Not main-actor isolated, so the push registrar can resolve it from any context.
nonisolated enum APNsEnvironmentResolution: Sendable, Equatable {
  /// `"production"` or `"sandbox"`, the wire value sent with the token.
  case resolved(String)
  /// The environment can't be told from this build. Never register a token in this
  /// state; foreground refresh and background catch-up keep working without push.
  case unknown
}

/// Reads this build's APNs environment from its embedded provisioning profile (spec 06
/// §11.3): no profile means a store or TestFlight build (`production`); a profile's
/// `aps-environment` of `development` means `sandbox`.
///
/// IntegrationStub: always `.unknown`, so no token is registered yet. Lane C implements
/// it per spec 06 §11.3, with the fixture tests, and removes this marker (Lane C's
/// archive gate is to refuse a build while `IntegrationStub` appears under `ios/`).
nonisolated func resolveAPNsEnvironment() -> APNsEnvironmentResolution {
  .unknown
}
