import CoreAuth
import CoreSync
import Testing

@testable import Hasala

/// The live service's failure mapping (spec 04 §6.1.5): each server refusal and
/// ceremony failure lands on the copy block the screens show.
///
/// The ceremonies themselves are CoreSync's, tested against its FakeServer there; the
/// shipped view models over this service run in `LiveAccountFlowTests`.
@MainActor
@Suite("Live account service")
struct LiveAccountServiceTests {
  static func refused(_ status: Int, _ code: String) -> CeremonyError {
    .api(.refused(APIFailure(status: status, code: code)))
  }

  @Test(arguments: [
    (403, "not_invited", AuthFailure.notInvited),
    (400, "bad_name", .badName),
    (400, "bad_email", .badEmail),
    (403, "password_rejected", .wrongCredentials),
    (409, "email_in_use", .emailInUse),
    (403, "code_rejected", .codeExpired),
    (409, "last_authenticator", .lastAuthenticator),
    (403, "account_frozen", .frozen),
    (403, "step_up_failed", .stepUpFailed),
    (429, "rate_limited", .rateLimited),
    (503, "unavailable", .offline),
    (403, "passkey_rejected", .refused),
  ])
  func refusalsMapToTheirCopy(_ status: Int, _ code: String, _ want: AuthFailure) {
    #expect(LiveAccountService.map(Self.refused(status, code)) == want)
  }

  @Test func ceremonyFailuresMapToTheirCopy() {
    #expect(LiveAccountService.map(.passkey(.cancelled)) == .cancelled)
    #expect(LiveAccountService.map(.passkey(.noCredential)) == .noCredential)
    #expect(LiveAccountService.map(.passkey(.unsupported)) == .unsupported)
    #expect(LiveAccountService.map(.notThisAccountsPhrase) == .phraseMismatch)
    #expect(LiveAccountService.map(.challengeMismatch) == .integrity)
    #expect(LiveAccountService.map(.integrityAlarm("keys")) == .integrity)
    #expect(LiveAccountService.map(.api(.transport(.offline(.notConnectedToInternet)))) == .offline)
    #expect(LiveAccountService.map(.noPRF) == .noCredential)
  }
}
