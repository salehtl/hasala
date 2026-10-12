import CoreAuth
import CoreStore
import CoreSync
import Foundation
import UIKit
import os

/// APNs registration (spec 04 §2.3 step 2, 06 §11): once an account is open, iOS is
/// asked for a device token; the token goes to the server with this build's APNs
/// environment (`PUT /push/apns`, #31) so peer uploads wake this iPhone with a silent push.
///
/// Nothing is sent while the environment is `.unknown` (06 §11.3): a token registered in
/// the wrong environment would make every wake fail. A digest of the last (account,
/// token, environment) sent is remembered (never the values, spec 04 §4.5), so a launch
/// with the same token sends nothing. Gmail never depends on this: foreground and
/// background-refresh runs read mail too.
@MainActor
final class PushRegistrar {
  static let shared = PushRegistrar()

  private var env: AccountEnvironment?
  private var userID: String?
  private let defaults: UserDefaults
  private let log = Logger(subsystem: "app.hasala.ios", category: "push")
  private nonisolated static let lastKey = "push.apns.registered.v2"
  /// The earlier form, which held the values themselves.
  private nonisolated static let legacyLastKey = "push.apns.registered.v1"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Asks iOS for a token for `userID`'s account (the answer arrives in `AppDelegate`).
  func register(env: AccountEnvironment, userID: String) {
    self.env = env
    self.userID = userID
    UIApplication.shared.registerForRemoteNotifications()
  }

  /// The token iOS gave this app.
  func didRegister(token: Data) async {
    guard let env, let userID else { return }
    guard case .resolved(let raw) = resolveAPNsEnvironment(), let environment = APNsTokenEnvironment(rawValue: raw) else {
      log.info("apns environment unknown: token not registered")
      return
    }
    let hex = AuthClient.tokenHex(token)
    let key = LocalAccountData.digest("\(userID)|\(hex)|\(raw)", salt: LocalAccountData.salt(defaults))
    defaults.removeObject(forKey: Self.legacyLastKey)
    guard defaults.string(forKey: Self.lastKey) != key else { return }
    guard let session = try? env.secrets.session(), !session.pending_logout else { return }
    do {
      try await env.client.putAPNs(tokenHex: hex, environment: environment, bearer: session.token)
      defaults.set(key, forKey: Self.lastKey)
    } catch {
      log.info("apns registration failed; retried next launch")
    }
  }

  /// "Remove this iPhone" (#33, before the device's keys go): the server stops waking
  /// this iPhone. Best effort.
  func unregister() async {
    defer { forget() }
    guard let env, let session = try? env.secrets.session(), !session.pending_logout else { return }
    try? await env.client.deleteAPNs(bearer: session.token)
  }

  /// Sign-out: the next account registers its own token.
  func forget() {
    Self.forgetRegistration(defaults)
    env = nil
    userID = nil
  }

  /// Drops the remembered registration, so the next account sends its token again.
  nonisolated static func forgetRegistration(_ defaults: UserDefaults) {
    defaults.removeObject(forKey: lastKey)
    defaults.removeObject(forKey: legacyLastKey)
  }
}
