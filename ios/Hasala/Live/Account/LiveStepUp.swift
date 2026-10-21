import CoreAuth
import CoreCrypto
import CoreJSON
import CoreMailbox
import CorePrimitives
import CoreStore
import CoreSync
import Foundation
import UIKit

/// The mail lanes' step-up (spec 04 §6.3; `02` §8) for `mailbox.link` and
/// `mailbox.unlink`: a passkey assertion for a passkey account, or for a password
/// account the password (asked for here) and this iPhone's approval key.
///
/// The engine hands over `P` = SHA256(id_token) rather than the token, so the params
/// hash is built from the tuple directly; the server's challenge is still recomputed and
/// compared before any prompt (AT-C9), exactly as `StepUpHelper.prove` does.
nonisolated struct LiveStepUp: MailboxStepUp {
  let env: AccountEnvironment
  /// The account signs in with a passkey (else with a password).
  let usesPasskey: @Sendable () async -> Bool
  /// Asks for the account's password ("Confirm it's you"); nil when the user cancels.
  let askPassword: @Sendable (_ reason: String) async -> String?

  func proof(kind: String, payloadHash: Data?) async throws(MailboxStepUpError) -> JSONValue {
    guard kind == "mailbox.link" || kind == "mailbox.unlink",
      let binding = try? env.secrets.binding(), let user = binding.userID, let writer = binding.writerID,
      let session = try? env.secrets.session(), !session.pending_logout
    else { throw .unavailable }
    let tuple = payloadHash.map { [$0] } ?? []
    let paramsHash = StepUp.paramsHash(action: kind, tuple: tuple)
    let passkey = await usesPasskey()
    // Both lanes share this step-up, so the reason names no provider.
    let reason = Self.reason(kind)
    let begin: StepUpBeginResponse
    do {
      begin = try await env.client.stepUpBegin(
        StepUpBeginRequest(
          action: kind, paramsHashHex: Hex.encode(paramsHash), proofKind: passkey ? "passkey" : "device"),
        bearer: session.token)
    } catch {
      throw .failed
    }
    guard let nonce = try? Base64.decodeURL(begin.nonce), let challenge = try? Base64.decodeURL(begin.challenge),
      let mine = try? StepUp.challenge(nonce: nonce, action: kind, paramsHash: paramsHash),
      constantTimeEquals(mine, challenge)
    else { throw .failed }
    let stepUp: StepUpJSON
    if passkey {
      guard let passkeys = env.passkeys else { throw .unavailable }
      let allow = (begin.allow_credentials ?? []).compactMap { try? Base64.decodeURL($0) }
      do {
        let a = try await passkeys.assert(challenge: challenge, allowCredentialIDs: allow, prfSalt: nil)
        stepUp = StepUpJSON(nonce: begin.nonce, proof: .passkey(a.credential))
      } catch .cancelled {
        throw .cancelled
      } catch {
        throw .failed
      }
    } else {
      // The password is asked for only once the server's challenge checked out.
      guard let password = await askPassword(reason), !password.isEmpty else { throw .cancelled }
      guard let salt = binding.serverSalt,
        let s = try? PasswordStretch.stretch(password: password, serverSalt: salt, emailNorm: binding.email_norm),
        let message = try? SigningMessage.deviceStepUp(challenge: challenge, writerID: writer)
      else { throw .failed }
      defer { s.wipe() }
      let sig: Data
      do {
        sig = try await env.approvalKeys.sign(message, userID: user, writerID: writer, reason: reason)
      } catch .cancelled {
        throw .cancelled
      } catch {
        throw .unavailable
      }
      stepUp = StepUpJSON(
        nonce: begin.nonce,
        proof: .device(
          writerID: writer.string, sigB64: Base64.encode(sig), verifierB64: s.withUnsafeBytes { Base64.encode($0) }))
    }
    guard let data = try? JSONEncoder().encode(stepUp), let value = try? JSONParser.parse([UInt8](data)) else {
      throw .failed
    }
    return value
  }

  /// The password alert's title and the approval key's reason: Gmail and Outlook share
  /// this step-up, so it names neither.
  static func reason(_ kind: String) -> String {
    kind == "mailbox.link"
      ? "Confirm it's you to connect this mailbox to Hasala" : "Confirm it's you to disconnect this mailbox"
  }
}

/// "Confirm it's you" outside the account screens (the mailbox step-up): a system alert over
/// the key window that names the change, with one secure field for a password account.
enum StepUpPrompt {
  @MainActor
  static func password(_ reason: String) async -> String? {
    let alert = UIAlertController(title: reason, message: "Enter your Hasala password.", preferredStyle: .alert)
    alert.addTextField { field in
      field.isSecureTextEntry = true
      field.textContentType = .password
      field.placeholder = "Password"
    }
    return await present(alert, cancelled: nil) { [weak alert] in alert?.textFields?.first?.text }
  }

  @MainActor
  private static func present<T: Sendable>(
    _ alert: UIAlertController, cancelled: T, answer continued: @escaping @MainActor () -> T
  ) async -> T {
    guard let presenter = await settledPresenter() else { return cancelled }
    let answer = FirstOf<T>()
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in answer.finish(cancelled) })
    let proceed = UIAlertAction(title: "Continue", style: .default) { _ in answer.finish(continued()) }
    alert.addAction(proceed)
    alert.preferredAction = proceed
    presenter.present(alert, animated: true)
    // UIKit refuses a presentation silently (the presenter is busy): then nobody can
    // answer, so the step-up is treated as cancelled.
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(1))
      if alert.presentingViewController == nil { answer.finish(cancelled) }
    }
    return await withCheckedContinuation { answer.install($0) }
  }

  /// The top view controller of the key window once nothing is coming or going. The
  /// prompt usually follows a tap in another alert (Bank alerts' "Disconnect", plan D.1
  /// risk 8): if the step-up's round trip is quicker than that alert's dismissal, the alert
  /// would still be on top, and UIKit refuses to present over a controller that is being
  /// dismissed, which reads as a cancel. So it waits for the transition to end, for at
  /// most two seconds; nil if the window or a settled controller never appears.
  @MainActor
  private static func settledPresenter() async -> UIViewController? {
    for _ in 0..<40 {
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      guard let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow), var top = window.rootViewController
      else { return nil }
      while let presented = top.presentedViewController { top = presented }
      if !top.isBeingDismissed, !top.isBeingPresented, top.transitionCoordinator == nil { return top }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return nil
  }
}
