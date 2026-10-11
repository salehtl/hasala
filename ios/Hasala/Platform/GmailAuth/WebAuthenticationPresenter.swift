import AuthenticationServices
import CoreMailbox
import UIKit

/// The browser half of "Connect Gmail" (spec 04 §7.2): ASWebAuthenticationSession with the
/// reversed client id as a custom callback scheme. The scheme is deliberately NOT registered in
/// `CFBundleURLTypes` (spec 06 DV-2): the session captures the redirect itself, so no other app
/// or page can open Hasala with a forged code. `prefersEphemeralWebBrowserSession = false`: the
/// user is usually already signed in to Google in Safari (PO-4).
final class WebAuthenticationPresenter: NSObject, GmailAuthSessionPresenter, ASWebAuthenticationPresentationContextProviding {
  /// The running session, retained until its completion handler fires.
  private var session: ASWebAuthenticationSession?

  nonisolated func authorize(url: URL, callbackScheme: String) async throws(GmailOAuthError) -> URL {
    let result: Result<URL, GmailOAuthError> = await withCheckedContinuation { continuation in
      Task { @MainActor in
        self.start(url: url, scheme: callbackScheme) { continuation.resume(returning: $0) }
      }
    }
    return try result.get()
  }

  private func start(url: URL, scheme: String, done: @escaping (Result<URL, GmailOAuthError>) -> Void) {
    let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { [weak self] callback, error in
      Task { @MainActor in self?.session = nil }
      if let callback {
        done(.success(callback))
      } else if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
        done(.failure(.cancelled))
      } else {
        done(.failure(.malformedCallback))
      }
    }
    session.prefersEphemeralWebBrowserSession = false
    session.presentationContextProvider = self
    self.session = session
    if !session.start() {
      self.session = nil
      done(.failure(.malformedCallback))
    }
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    if let key = scenes.flatMap(\.windows).first(where: \.isKeyWindow) { return key }
    // "Connect Gmail" is only reachable from a foreground scene, so one always exists.
    return ASPresentationAnchor(windowScene: scenes.first!)
  }
}
