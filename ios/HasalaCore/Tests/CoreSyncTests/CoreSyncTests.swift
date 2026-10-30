// Unit tests for CoreSync (owner: WS-11). The protocol scenarios run in
// HasalaCoreE2ETests against FakeServer; these cover the pieces alone.
import CoreTestSupport
import Foundation
import Testing

@testable import CoreSync

@Suite("CoreSync: pieces")
struct SyncPieceTests {
  @Test("ULIDs: 26 Crockford characters, time-ordered")
  func ulid() {
    let clock = FakeClock(ms: 1_791_000_000_000)
    let r = SeededRandom()
    let a = ULID.make(clock: clock, random: r)
    clock.advance(ms: 1)
    let b = ULID.make(clock: clock, random: r)
    #expect(a.count == 26 && b.count == 26)
    #expect(a < b)
    #expect(a.utf8.allSatisfy { ULID.alphabet.contains($0) })
  }

  @Test("§6.1.4 invite codes: upper-cased, spaces and hyphens dropped, 24 of A-Z2-7")
  func inviteCode() {
    #expect(AuthInput.inviteCode("abcd-efgh ijkl-mnop-qrst-uvwx") == "ABCDEFGHIJKLMNOPQRSTUVWX")
    #expect(AuthInput.inviteCode("ABCDEFGHIJKLMNOPQRSTUVW1") == nil)  // 1 is not base32
    #expect(AuthInput.inviteCode("HSL-ABCD") == nil)
  }

  @Test("a sign-in's device refusals have their own classes")
  func deviceRefusalClasses() {
    func f(_ s: Int, _ c: String) -> CeremonyError { .api(.refused(APIFailure(status: s, code: c))) }
    #expect(f(409, "other_account_device").failureClass == .otherAccountDevice)
    #expect(f(400, "bad_signature").failureClass == .deviceRefused)
    #expect(f(403, "writer_revoked").failureClass == .deviceRefused)
    #expect(f(403, "passkey_rejected").failureClass == .rejected)
  }

  @Test("the common answers of §5.5 / §6.4")
  func commonStops() {
    func f(_ s: Int, _ c: String) -> APIError { .refused(APIFailure(status: s, code: c)) }
    #expect(SyncStop.common(f(401, "unauthorized")) == .needsSignIn)
    #expect(SyncStop.common(f(410, "account_deleted")) == .wipe)
    #expect(SyncStop.common(f(410, "link_expired")) == .halted(.unexpectedGone))
    #expect(SyncStop.common(f(410, "")) == .halted(.unexpectedGone))
    #expect(SyncStop.common(f(403, "writer_revoked")) == .halted(.unprovedRevocation))
    #expect(SyncStop.common(f(403, "writer_unbound")) == .needsRebind)
    #expect(SyncStop.common(f(403, "keys_required")) == .keysRequired)
    #expect(SyncStop.common(f(503, "unavailable")) == .offline)
    #expect(SyncStop.common(.transport(.offline(.timedOut))) == .offline)
    #expect(SyncStop.common(f(400, "bad_request")) == nil)
  }

  @Test("RFC 3339 with Go's nanoseconds")
  func rfc3339() {
    #expect(RFC3339.seconds("2027-01-09T00:00:00.123456789Z") == 1_799_452_800)
    #expect(RFC3339.seconds("2027-01-09T00:00:00Z") == 1_799_452_800)
    #expect(RFC3339.seconds("yesterday") == nil)
  }
}

@Suite("CoreSync: boot (§6.5)")
struct BootTests {
  let user = UserID("6f1c2b9e-4d3a-4f5b-8c7d-0e1f2a3b4c5d")!
  let other = UserID("7f1c2b9e-4d3a-4f5b-8c7d-0e1f2a3b4c5d")!
  let writer = WriterID("ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d")!

  var binding: AccountBinding {
    AccountBinding(
      userID: user, writerID: writer, apiBase: "b", keyEpoch: 1, emailNorm: "m@example.com", serverSalt: Data(count: 32),
      displayName: nil)
  }

  func session(_ u: UserID, pending: Bool = false) -> SessionRecord {
    SessionRecord(token: "t", userID: u.string, expiresAt: 0, tag: "00", pendingLogout: pending)
  }

  func facts(
    binding b: AccountBinding?, session s: SessionRecord?, store: UserID?, ke: Bool = true, dwk: Bool = true
  ) -> BootFacts {
    BootFacts(binding: b, session: s, storeUserID: store, storeExists: store != nil, epochKeyPresent: ke, writerKeyPresent: dwk)
  }

  @Test("each row of §6.5's table")
  func table() {
    #expect(Boot.decide(facts(binding: nil, session: nil, store: nil)) == .signedOut)
    #expect(Boot.decide(facts(binding: nil, session: session(user), store: nil)) == .onboardingKeys)
    #expect(Boot.decide(facts(binding: nil, session: session(user, pending: true), store: nil)) == .signedOut)
    #expect(Boot.decide(facts(binding: binding, session: session(user), store: other)) == .foreignData)
    #expect(Boot.decide(facts(binding: binding, session: session(other), store: user)) == .foreignData)
    #expect(Boot.decide(facts(binding: binding, session: session(user), store: user, ke: false)) == .needsUnlock)
    #expect(Boot.decide(facts(binding: binding, session: session(user), store: user, dwk: false)) == .unenrolled)
    #expect(Boot.decide(facts(binding: binding, session: nil, store: user)) == .signedOutBound)
    #expect(Boot.decide(facts(binding: binding, session: session(user), store: nil)) == .restoring)
    #expect(Boot.decide(facts(binding: binding, session: session(user), store: user)) == .opening(binding))
    var locked = facts(binding: nil, session: nil, store: nil)
    locked.unreadable = true
    #expect(Boot.decide(locked) == .waitingForUnlock)
  }
}
