// The domain-string registry (spec 01 §3): one constant per row, D01-D43, in
// order. `allCases` is the registry that AT-X3 compares with Go's
// `keyproto/domains.go` and with `conformance/crypto-v3/manifest.json`.
//
// D27-D30, D41 and D43 are used only by the server; they are listed so the namespace
// stays collision-free and the Swift tests can reproduce A19 and A19-K. No
// `ledger-*` string and no op-spec `hasala/v1/*` hash string belongs here.
import Foundation

public enum Domain: String, CaseIterable, Sendable {
  case register = "hasala/v1/register"  // D01
  case stepUp = "hasala/v1/step-up"  // D02
  case stepUpParams = "hasala/v1/step-up-params"  // D03
  case recoveryKey = "hasala/v1/recovery-key"  // D04
  case wrapRecovery = "hasala/v1/wrap/recovery"  // D05
  case wrapPRF = "hasala/v1/wrap/prf"  // D06
  case wrap = "hasala/v1/wrap"  // D07
  case prfSaltUnlock = "hasala/v1/prf-salt/unlock"  // D08
  case amkCommitment = "hasala/v1/amk-commitment"  // D09
  case epochKey = "hasala/v1/epoch-key"  // D10
  case blobKey = "hasala/v1/blob-key"  // D11
  case blob = "hasala/v1/blob"  // D12
  case writerRegistration = "hasala/v1/writer-registration"  // D13
  case writerRevocation = "hasala/v1/writer-revocation"  // D14
  case sessionBind = "hasala/v1/session-bind"  // D15
  case accountDelete = "hasala/v1/account-delete"  // D16
  case bootstrap = "hasala/v1/bootstrap"  // D17
  case recoverySignin = "hasala/v1/recovery-signin"  // D18
  case recoveryRotate = "hasala/v1/recovery-rotate"  // D19
  case epochRotate = "hasala/v1/epoch-rotate"  // D20
  case keyringKey = "hasala/v1/keyring-key"  // D21
  case keyring = "hasala/v1/keyring"  // D22
  case deviceComparison = "hasala/v1/device-comparison"  // D23
  case mailboxRoute = "hasala/v1/mailbox-route"  // D24
  case mailboxRouteKeyID = "hasala/v1/mailbox-route-key-id"  // D25
  case password = "hasala/v1/password"  // D26
  case serverPasswordSalt = "hasala/v1/server/password-salt"  // D27
  case serverPasswordPepper = "hasala/v1/server/password-pepper"  // D28
  case serverEmailCode = "hasala/v1/server/email-code"  // D29
  case serverEmailTag = "hasala/v1/server/email-tag"  // D30
  case stepUpDevice = "hasala/v1/step-up-device"  // D31
  case writerHead = "hasala/v1/writer-head"  // D32
  case passkeyAdd = "hasala/v1/passkey-add"  // D33
  case wrapPut = "hasala/v1/wrap-put"  // D34
  case phraseBoxKey = "hasala/v1/phrase-box-key"  // D35
  case phraseBox = "hasala/v1/phrase-box"  // D36
  case resetCode = "hasala/v1/reset-code"  // D37
  case resetApprove = "hasala/v1/reset-approve"  // D38
  case resetFinish = "hasala/v1/reset-finish"  // D39
  case emailChange = "hasala/v1/email-change"  // D40
  case serverAuthKeyID = "hasala/v1/server/auth-key-id"  // D41
  case deviceFreeze = "hasala/v1/device-freeze"  // D42
  case serverInviteMint = "hasala/v1/server/invite-mint"  // D43

  /// The ASCII bytes of the string (no terminator).
  public var bytes: Data { Data(rawValue.utf8) }

  /// The string followed by exactly one `0x00`: the prefix form, used wherever
  /// the domain string is followed by other fields (spec 01 §1).
  public var prefix: Data { bytes + [0x00] }
}
