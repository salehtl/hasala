// "Remove this iPhone" and "Delete account" (spec 04 §4.7 rows 2 and 4,
// §6.2 C6 for the own writer; spec 01 §10.6, §10.12; `02` §9.5, §15.2).
//
//   remove:  flush and pull to head → #23 challenge → RevocationMessage signed by
//            this iPhone's DWK, pinning its own VERIFIED head (final_counter,
//            final_head; (0, 0^32) for an empty chain) → step-up writer.revoke →
//            #25; 409 head_moved → pull and re-sign once → local wipe
//   delete:  step-up account.delete → DeletionMessage(step_up.nonce, user_id)
//            signed by the DWK → #41 → local wipe
//
// The holder's Gmail stop and token revoke come first (§4.7); they are the
// mailbox lane's (TODO(WS-12)).
import CoreAuth
import CoreCrypto
import CorePrimitives
import CoreStore
import CoreWire
import Foundation

public enum AccountManagement {
  public static func removeThisIPhone(
    _ env: AccountEnvironment, ctx: SyncContext, factor: StepUpHelper.Factor, binding: AccountBinding
  ) async throws(CeremonyError) {
    for attempt in 0..<2 {
      try await catchUp(ctx)
      let head = (try? ctx.store.chainHeads()[ctx.writerID]) ?? .genesis
      let bearer = try AccountCreation.currentBearer(env)
      let challenge = try await apiStep { () async throws(APIError) in try await env.client.writerChallenge(bearer: bearer) }
      let nonce = try b64(challenge.nonce, "writer nonce")
      let seed = try dwk(env, ctx)
      defer { seed.wipe() }
      let sig = try cryptoStep("revocation") {
        try DWK.sign(
          seed: seed,
          message: try SigningMessage.revocation(
            nonce: nonce, writerID: ctx.writerID, finalCounter: head.counter, finalHead: head.hash))
      }
      let proof = try await StepUpHelper.prove(
        env, params: .writerRevoke(ctx.writerID), factor: factor, binding: binding,
        reason: "Confirm it's you to remove this device")
      do {
        try await env.client.writerRevoke(
          WriterRevokeRequest(
            writer_id: ctx.writerID.string, signer_writer_id: ctx.writerID.string, nonce: Base64.encode(nonce),
            final_counter: String(head.counter), final_head: Base64.encode(head.hash.bytes), sig: Base64.encode(sig),
            step_up: proof.stepUp),
          bearer: bearer)
        AccountWipe.wipe(env, userID: ctx.userID, writerID: ctx.writerID)
        return
      } catch {
        if error.is(409, "head_moved"), attempt == 0 { continue }
        throw .api(error)
      }
    }
  }

  public static func deleteAccount(
    _ env: AccountEnvironment, ctx: SyncContext, factor: StepUpHelper.Factor, binding: AccountBinding
  ) async throws(CeremonyError) {
    let proof = try await StepUpHelper.prove(
      env, params: .accountDelete(ctx.userID), factor: factor, binding: binding,
      reason: "Confirm it's you to delete your account")
    guard let n = try? Base64.decodeURL(proof.stepUp.nonce) else { throw .badResponse("step-up nonce") }
    let seed = try dwk(env, ctx)
    defer { seed.wipe() }
    let sig = try cryptoStep("deletion") {
      try DWK.sign(seed: seed, message: try SigningMessage.deletion(nonce: n, userID: ctx.userID))
    }
    let bearer = try AccountCreation.currentBearer(env)
    try await apiStep { () async throws(APIError) in
      try await env.client.deleteAccount(
        DeleteAccountRequest(step_up: proof.stepUp, writer_id: ctx.writerID.string, sig: Base64.encode(sig)),
        bearer: bearer)
    }
    AccountWipe.wipe(env, userID: ctx.userID, writerID: ctx.writerID)
  }

  /// Uploads what is queued and pulls to the head, so the pinned head is current.
  static func catchUp(_ ctx: SyncContext) async throws(CeremonyError) {
    do {
      _ = try await Pusher.flush(ctx, deadline: nil)
    } catch {
      if case .latched = error {} else { throw .badResponse("sync before removal: \(error)") }
    }
    do { _ = try await Puller.pull(ctx, observer: nil) } catch { throw .badResponse("pull before removal: \(error)") }
  }

  static func dwk(_ env: AccountEnvironment, _ ctx: SyncContext) throws(CeremonyError) -> SecureBytes {
    guard let s = try secretStep({ () throws(SecretStoreError) in try env.secrets.writerSeed(userID: ctx.userID, writerID: ctx.writerID) })
    else { throw .noDeviceKey }
    return s
  }
}
