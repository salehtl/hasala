// The session routes the app runtime calls outside the ceremonies (`02` §7):
// the APNs token (#31 PUT, #32 GET, #33 DELETE), "Another bank? Tell us" (#74,
// signed in, `source: "app"`) and the display name (#76). Bodies are exactly
// the server's (unknown members are refused there), and every method throws
// `APIError` so the caller keeps its own table.
import Foundation

/// The APNs environment a device token belongs to (`02` #31). The app's
/// `APNsEnvironment` (06 §2.3, read from the provisioning profile) has the same
/// raw values: `APNsTokenEnvironment(rawValue: resolved.rawValue)`.
public enum APNsTokenEnvironment: String, Sendable, Hashable, Codable, CaseIterable {
  case production
  case sandbox
}

/// #31's body.
public struct PutAPNsRequest: Codable, Sendable, Hashable {
  public var token_hex: String
  public var environment: String

  public init(tokenHex: String, environment: APNsTokenEnvironment) {
    token_hex = tokenHex
    self.environment = environment.rawValue
  }
}

/// One device of #32's answer.
public struct APNsDevice: Codable, Sendable, Hashable {
  public var writer_id: String
  public var environment: String
  public var created_at: String
  public var updated_at: String
  /// This session's own device.
  public var current: Bool
}

public struct APNsDevicesResponse: Codable, Sendable, Hashable {
  public var devices: [APNsDevice]
}

/// #74's body as the app sends it: a catalogue slug (`bank`), or `bank: "other"`
/// with the typed name in `otherBank`.
public struct BankRequestBody: Codable, Sendable, Hashable {
  public var bank: String
  public var otherBank: String?
  public var source: String

  public init(bank: String, otherBank: String?) {
    self.bank = bank
    self.otherBank = otherBank
    source = "app"
  }
}

/// #74's answer (`202 {"status":"counted"}`; the same whether or not the bank was new).
public struct BankRequestResponse: Codable, Sendable, Hashable {
  public var status: String
}

/// #76's body.
public struct DisplayNameRequest: Codable, Sendable, Hashable {
  public var display_name: String
  public init(displayName: String) { display_name = displayName }
}

extension AuthClient {
  /// The lower-case hex of an APNs device token (what #31 stores).
  public static func tokenHex(_ deviceToken: Data) -> String {
    deviceToken.map { String(format: "%02x", $0) }.joined()
  }

  /// `PUT /push/apns {token_hex, environment}` (#31): registers or moves this
  /// writer's token. `204`; `400 bad_request` for a token or environment the
  /// server refuses, `403` while the session is not bound to a writer.
  public func putAPNs(tokenHex: String, environment: APNsTokenEnvironment, bearer: String) async throws(APIError) {
    let _: Empty = try await api.call(
      .put, "/api/v1/push/apns", json: PutAPNsRequest(tokenHex: tokenHex, environment: environment), bearer: bearer)
  }

  /// `GET /push/apns` (#32): the account's registered devices.
  public func apnsDevices(bearer: String) async throws(APIError) -> APNsDevicesResponse {
    try await api.call(.get, "/api/v1/push/apns", bearer: bearer)
  }

  /// `DELETE /push/apns` (#33): this writer stops receiving wakes. Called
  /// before "Remove this iPhone" and sign-out (04 §2.3 step 5). `204`.
  public func deleteAPNs(bearer: String) async throws(APIError) {
    let _: Empty = try await api.call(.delete, "/api/v1/push/apns", bearer: bearer)
  }

  /// `POST /bank-requests {bank, otherBank, source: "app"}` (#74). `bank` is a
  /// catalogue slug, or `"other"` with `otherBank` set. `202`; `400 bad_bank`;
  /// `429 rate_limited` or `bank_list_full`.
  @discardableResult
  public func bankRequest(bank: String, otherBank: String? = nil, bearer: String) async throws(APIError)
    -> BankRequestResponse
  {
    try await api.call(.post, "/api/v1/bank-requests", json: BankRequestBody(bank: bank, otherBank: otherBank), bearer: bearer)
  }

  /// `PUT /account/display-name {display_name}` (#76). `204`; `400 bad_name`.
  public func setDisplayName(_ name: String, bearer: String) async throws(APIError) {
    let _: Empty = try await api.call(
      .put, "/api/v1/account/display-name", json: DisplayNameRequest(displayName: name), bearer: bearer)
  }
}
