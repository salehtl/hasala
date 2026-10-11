import CoreAuth
import CorePrimitives
import Foundation

/// CoreAuth's passkey seam over `PasskeyAuthenticator` (spec 04 §2.7, §6.1.1): the
/// ceremonies in CoreSync call it from any context; the system sheet runs on the main
/// actor. The options come from the server and were checked by the caller (`C_reg`).
nonisolated struct LivePasskeyProvider: PasskeyProvider {
  func register(_ options: CreationOptions, prfSalt: Data?) async throws(PasskeyError) -> CoreAuth.RawRegistration {
    try await Self.register(options, prfSalt: prfSalt)
  }

  func assert(challenge: Data, allowCredentialIDs: [Data], prfSalt: Data?) async throws(PasskeyError)
    -> CoreAuth.RawAssertion
  {
    try await Self.assert(challenge: challenge, allow: allowCredentialIDs, prfSalt: prfSalt)
  }

  @MainActor
  private static func register(_ o: CreationOptions, prfSalt: Data?) async throws(PasskeyError)
    -> CoreAuth.RawRegistration
  {
    guard o.rpID.isEmpty || o.rpID == PasskeyAuthenticator.relyingParty else { throw .failed("rp_id") }
    let r: PasskeyAuthenticator.RawRegistration
    do {
      r = try await PasskeyAuthenticator().register(
        challenge: o.challenge, userID: o.userID, excludedCredentials: o.excludeCredentialIDs, prfSalt: prfSalt)
    } catch {
      throw map(error, creating: true)
    }
    return CoreAuth.RawRegistration(
      credentialID: r.credentialID, rawClientDataJSON: r.rawClientDataJSON, rawAttestationObject: r.rawAttestationObject,
      prfFirst: r.prfFirst.map { SecureBytes(copying: $0) })
  }

  @MainActor
  private static func assert(challenge: Data, allow: [Data], prfSalt: Data?) async throws(PasskeyError)
    -> CoreAuth.RawAssertion
  {
    let a: PasskeyAuthenticator.RawAssertion
    do {
      a = try await PasskeyAuthenticator().assert(challenge: challenge, allowedCredentials: allow, prfSalt: prfSalt)
    } catch {
      throw map(error, creating: false)
    }
    return CoreAuth.RawAssertion(
      credentialID: a.credentialID, rawClientDataJSON: a.rawClientDataJSON, authenticatorData: a.authenticatorData,
      signature: a.signature, userHandle: a.userHandle, prfFirst: a.prfFirst.map { SecureBytes(copying: $0) })
  }

  private static func map(_ f: AuthFailure, creating: Bool) -> PasskeyError {
    switch f {
    case .cancelled: .cancelled
    case .noCredential: .noCredential
    case .refused: creating ? .noAttestation : .failed("assertion")
    default: .unsupported
    }
  }
}
