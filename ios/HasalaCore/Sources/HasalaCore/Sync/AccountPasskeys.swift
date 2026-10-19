import CoreAuth
import CoreCrypto
import CorePrimitives
import CoreStore
import CoreWire
import Foundation

public struct AddedPasskey: Sendable, Hashable {
  public let credentialID: Data
  public let unlocksData: Bool
}

public enum AccountPasskeys {
  public static func add(
    _ env: AccountEnvironment, binding: AccountBinding, factor: StepUpHelper.Factor, body: KeyBody?, reason: String
  ) async throws(CeremonyError) -> AddedPasskey {
    guard let user = binding.userID, let writer = binding.writerID else { throw .noDeviceKey }
    guard let passkeys = env.passkeys else { throw .passkey(.unsupported) }
    let proof = try await StepUpHelper.prove(env, params: .passkeyAdd, factor: factor, binding: binding, reason: reason)
    defer { proof.prf?.wipe() }
    guard let nonce = try? Base64.decodeURL(proof.stepUp.nonce) else { throw .badResponse("step-up nonce") }
    let bearer = try AccountCreation.currentBearer(env)
    let begin = try await apiStep { () async throws(APIError) in
      try await env.client.passkeyAddBegin(PasskeyAddBeginRequest(step_up: proof.stepUp), bearer: bearer)
    }
    let options: CreationOptions
    do { options = try begin.options.decoded() } catch { throw .badResponse("add options") }
    var opened: KeyBody?
    if body == nil, let credentialID = proof.credentialID, proof.prf != nil {
      opened = try? await Enrolment.unlockWithPRF(env, userID: user, credentialID: credentialID, prf: proof.prf)
    }
    defer { opened?.wipe() }
    let reg: RawRegistration
    do { reg = try await passkeys.register(options, prfSalt: KeyDerivation.prfSalt) } catch { throw .passkey(error) }
    defer { reg.prfFirst?.wipe() }
    var wrap: Data?
    if let prf = reg.prfFirst, let source = body ?? opened {
      wrap = try cryptoStep("prf wrap") {
        try Wrap.sealPRF(body: source, prfOutput: prf, userID: user, credentialID: reg.credentialID, random: env.random)
      }
    }
    guard let seed = try secretStep({ () throws(SecretStoreError) in try env.secrets.writerSeed(userID: user, writerID: writer) })
    else { throw .noDeviceKey }
    defer { seed.wipe() }
    let sig = try cryptoStep("passkey add") {
      try DWK.sign(
        seed: seed,
        message: try SigningMessage.passkeyAdd(
          nonce: nonce, clientDataJSON: reg.rawClientDataJSON, attestationObject: reg.rawAttestationObject,
          prfWrap: wrap))
    }
    let added = try await apiStep { () async throws(APIError) in
      try await env.client.passkeyAddFinish(
        PasskeyAddFinishRequest(
          ceremonyID: begin.ceremony_id, credential: reg.credential,
          prfWrap: wrap.map { BootstrapPRFWrapJSON(credentialIDB64URL: Base64.encodeURL(reg.credentialID), wrapB64: Base64.encode($0)) },
          dwkSigB64: Base64.encode(sig)),
        bearer: bearer)
    }
    guard (try? Base64.decodeURL(added.credential_id)) == reg.credentialID else { throw .badResponse("credential_id") }
    return AddedPasskey(credentialID: reg.credentialID, unlocksData: wrap != nil)
  }
}
