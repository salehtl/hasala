import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// The platform passkey adapter (spec 04 §6.1.1): `ASAuthorizationPlatformPublicKeyCredentialProvider`
/// for the relying party `hasala.app`, user verification required, and the PRF extension
/// so a passkey can unwrap the account key on a new iPhone (01 §4.7).
///
/// It returns the raw bytes unparsed; CoreAuth encodes them for `02`'s routes. The live
/// `AccountService` drives it; Debug builds and UI tests never reach it (the simulator
/// cannot complete a passkey ceremony, spec 04 §19.2).
///
/// TODO(WS-14, device spike V15): confirm the iOS 26 PRF type names and the behaviour
/// when the provider returns no PRF output on a physical iPhone before external testing.
@MainActor
final class PasskeyAuthenticator: NSObject {
  static let relyingParty = "hasala.app"

  struct RawRegistration: Sendable, Equatable {
    var credentialID: Data
    var rawClientDataJSON: Data
    var rawAttestationObject: Data
    /// The PRF output for `prfSalt`, when the provider supports it.
    var prfFirst: Data?
  }

  struct RawAssertion: Sendable, Equatable {
    var credentialID: Data
    var rawClientDataJSON: Data
    var authenticatorData: Data
    var signature: Data
    var userHandle: Data
    var prfFirst: Data?
  }

  private let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingParty)
  private var continuation: CheckedContinuation<ASAuthorization, Error>?
  private var controller: ASAuthorizationController?

  /// Registration (C1 step 7, C4 step 5a, C5): `name` is always "Hasala" (spec 04 §6.1.1).
  func register(challenge: Data, userID: Data, excludedCredentials: [Data] = [], prfSalt: Data?)
    async throws(AuthFailure) -> RawRegistration
  {
    let request = provider.createCredentialRegistrationRequest(challenge: challenge, name: "Hasala", userID: userID)
    request.userVerificationPreference = .required
    request.excludedCredentials = excludedCredentials.map {
      ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
    }
    if let prfSalt {
      request.prf = .inputValues(.init(saltInput1: prfSalt))
    }
    let auth = try await perform(request)
    guard let reg = auth.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
      throw .refused
    }
    // A registration without an attestation object aborts the ceremony (01 §10.1).
    guard let attestation = reg.rawAttestationObject else { throw .refused }
    return RawRegistration(
      credentialID: reg.credentialID, rawClientDataJSON: reg.rawClientDataJSON,
      rawAttestationObject: attestation, prfFirst: reg.prf?.first.map(Self.bytes))
  }

  /// Assertion (sign-in, step-ups). An empty `allowedCredentials` is a discoverable sign-in.
  func assert(challenge: Data, allowedCredentials: [Data] = [], prfSalt: Data?) async throws(AuthFailure)
    -> RawAssertion
  {
    let request = provider.createCredentialAssertionRequest(challenge: challenge)
    request.userVerificationPreference = .required
    request.allowedCredentials = allowedCredentials.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0) }
    if let prfSalt {
      request.prf = .inputValues(.init(saltInput1: prfSalt))
    }
    let auth = try await perform(request)
    guard let a = auth.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else { throw .refused }
    return RawAssertion(
      credentialID: a.credentialID, rawClientDataJSON: a.rawClientDataJSON, authenticatorData: a.rawAuthenticatorData,
      signature: a.signature, userHandle: a.userID, prfFirst: a.prf.map { Self.bytes($0.first) })
  }

  private static func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

  private func perform(_ request: ASAuthorizationRequest) async throws(AuthFailure) -> ASAuthorization {
    do {
      return try await withCheckedThrowingContinuation { (c: CheckedContinuation<ASAuthorization, Error>) in
        continuation = c
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        controller.performRequests()
      }
    } catch let error as ASAuthorizationError {
      switch error.code {
      case .canceled: throw .cancelled
      case .notInteractive, .matchedExcludedCredential: throw .noCredential
      case .notHandled, .failed, .invalidResponse, .unknown: throw .unsupported
      default: throw .unsupported
      }
    } catch {
      throw .unsupported
    }
  }

  private func finish(_ result: Result<ASAuthorization, Error>) {
    controller = nil
    let c = continuation
    continuation = nil
    c?.resume(with: result)
  }
}

extension PasskeyAuthenticator: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
  nonisolated func authorizationController(controller: ASAuthorizationController,
                                           didCompleteWithAuthorization authorization: ASAuthorization) {
    MainActor.assumeIsolated { finish(.success(authorization)) }
  }

  nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
    MainActor.assumeIsolated { finish(.failure(error)) }
  }

  nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    MainActor.assumeIsolated {
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      let windows = scenes.flatMap(\.windows)
      if let w = windows.first(where: \.isKeyWindow) ?? windows.first { return w }
      // A ceremony only starts from a visible screen, so a scene exists.
      return ASPresentationAnchor(windowScene: scenes[0])
    }
  }
}
