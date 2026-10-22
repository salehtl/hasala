import CoreAuth
import CoreSync
import Foundation
import HasalaMocks
import Testing

@testable import Hasala

@MainActor
@Suite("The 12 words after the first value")
struct WordsLaterTests: AccountSuite {
  private func atMethod(_ account: MockAccountService, unseen: InMemoryUnseenPhrase, created: @escaping () -> Void = {})
    async -> SignupModel
  {
    account.delay = .zero
    let m = SignupModel(account: account, unseenPhrase: unseen, accountCreated: created)
    m.inviteText = Self.code
    m.submitInvite()
    m.displayName = "Maya Rahman"
    m.email = "maya@example.com"
    await m.submitAboutYou()
    m.code = MockAccountService.emailCode
    await m.submitCode()
    return m
  }

  @Test func aPasskeyWithPRFMakesTheAccountWithoutShowingTheWords() async {
    let account = MockAccountService()
    account.passkeyPRF = true
    let unseen = InMemoryUnseenPhrase()
    var created = 0
    let m = await atMethod(account, unseen: unseen) { created += 1 }
    m.method = .passkey
    await m.continueWithMethod()
    #expect(created == 1)
    #expect(account.profile?.method == .passkey)
    #expect(m.profile?.method == .passkey)
    #expect(!m.path.contains(.phraseIntro) && !m.path.contains(.phraseShow) && !m.path.contains(.accountReady))
    #expect(m.phrase == nil && !m.phraseSeen)
    #expect(unseen.unseen)
    #expect(m.failure == nil)
  }

  @Test func aPasskeyWithoutPRFKeepsTheWordsInSignup() async {
    let account = MockAccountService()
    account.passkeyPRF = false
    let unseen = InMemoryUnseenPhrase()
    var created = 0
    let m = await atMethod(account, unseen: unseen) { created += 1 }
    await m.continueWithMethod()
    #expect(m.path.last == .phraseIntro)
    #expect(account.profile == nil && created == 0)
    showPhrase(m)
    await m.finish()
    #expect(m.path.last == .accountReady)
    #expect(!unseen.unseen)
  }

  @Test func aBuildThatCantShowTheWordsAgainKeepsThemInSignup() async {
    let account = MockAccountService()
    account.passkeyPRF = true
    account.capabilities = AccountCapabilities.beta.subtracting(.viewPhrase)
    let unseen = InMemoryUnseenPhrase()
    let m = await atMethod(account, unseen: unseen)
    await m.continueWithMethod()
    #expect(m.path.last == .phraseIntro)
    #expect(account.profile == nil && !unseen.unseen)
  }

  @Test func aPasswordKeepsTheWordsInSignupAndClearsAStaleFact() async {
    let account = MockAccountService()
    account.passkeyPRF = true
    let unseen = InMemoryUnseenPhrase()
    unseen.noteUnseen(at: .now)
    let m = await atMethod(account, unseen: unseen)
    m.method = .password
    await m.continueWithMethod()
    m.newPassword = "copper lantern quietly 42"
    m.confirmPassword = "copper lantern quietly 42"
    m.submitPassword()
    #expect(m.path.last == .phraseIntro)
    showPhrase(m)
    await m.finish()
    #expect(m.path.last == .accountReady)
    #expect(!unseen.unseen)
  }

  @Test func aFailedFinishStaysOnTheMethodAndRetriesWithoutASecondPasskey() async {
    let account = MockAccountService()
    account.passkeyPRF = true
    account.refuseFinish = .offline
    let unseen = InMemoryUnseenPhrase()
    var created = 0
    let m = await atMethod(account, unseen: unseen) { created += 1 }
    await m.continueWithMethod()
    #expect(m.failure == .offline && created == 0 && m.path.last == .method)
    #expect(m.passkeyRegistered)
    #expect(!unseen.unseen)
    await m.continueWithMethod()
    #expect(m.failure == nil && created == 1)
    #expect(unseen.unseen)
  }

  @Test func anOlderServerShowsTheWordsInSignupWithTheSamePasskey() async {
    let account = MockAccountService()
    account.passkeyPRF = true
    account.refuseFinish = .wordsInSignup
    let unseen = InMemoryUnseenPhrase()
    var created = 0
    let m = await atMethod(account, unseen: unseen) { created += 1 }
    m.method = .passkey
    await m.continueWithMethod()
    #expect(m.failure == nil && created == 0 && account.profile == nil)
    #expect(m.wordsInSignup && !m.wordsLater)
    #expect(m.path.last == .phraseIntro)
    #expect(m.phrase != nil && m.passkeyRegistered)
    #expect(!unseen.unseen)
    showPhrase(m)
    await m.finish()
    #expect(m.path.last == .accountReady)
    #expect(account.profile?.method == .passkey)
    #expect(account.passkeysMade == 1)
    #expect(!unseen.unseen)
  }

  @Test func theOlderServersRefusalIsTheOnlyOneThatShowsTheWords() {
    let old = CeremonyError.api(.refused(APIFailure(status: 400, code: "bad_request")))
    #expect(LiveAccountService.finishFailure(old, phraseUnseen: true) == .wordsInSignup)
    #expect(LiveAccountService.finishFailure(old, phraseUnseen: false) != .wordsInSignup)
    let other = CeremonyError.api(.refused(APIFailure(status: 409, code: "keys_exist")))
    #expect(LiveAccountService.finishFailure(other, phraseUnseen: true) != .wordsInSignup)
    let unseen = CeremonyError.api(.refused(APIFailure(status: 409, code: "phrase_unseen")))
    #expect(LiveAccountService.map(unseen) == .wordsBeforeRemovingPasskey)
  }

  @Test func anExpiredCeremonyStartsAgain() async {
    let account = MockAccountService()
    account.passkeyPRF = true
    account.refuseFinish = .offline
    let m = await atMethod(account, unseen: InMemoryUnseenPhrase())
    await m.continueWithMethod()
    m.now = { .now.addingTimeInterval(31 * 60) }
    await m.continueWithMethod()
    #expect(account.profile == nil)
    #expect(m.path == [.aboutYou])
    #expect(m.failure == .signupExpired)
  }

  @Test func theViewerNotesTheWordsSeenOnlyWhenDrawn() async {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    account.delay = .zero
    var s = services(account)
    let unseen = InMemoryUnseenPhrase()
    unseen.noteUnseen(at: .now)
    s.unseenPhrase = unseen
    let m = SecurityModel(session: AccountSession(services: s, phase: .ready))
    await m.load()
    m.requestPhrase()
    await m.confirm()
    m.confirmationDismissed()
    #expect(m.viewedPhrase == MockAccountService.phraseWords)
    m.phraseMasked = true
    m.phraseRevealed = true
    #expect(!m.phraseRevealed && unseen.unseen)
    m.phraseMasked = false
    m.phraseRevealed = true
    #expect(m.phraseRevealed && !unseen.unseen)
  }

  @Test func homeShowsTheWordsFirstUntilTheyWereShown() async throws {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    account.delay = .zero
    var s = services(account)
    let unseen = InMemoryUnseenPhrase()
    unseen.noteUnseen(at: .now)
    s.unseenPhrase = unseen
    let session = AccountSession(services: s, phase: .ready)
    let m = FinishSetupModel(services: s, session: { session })
    #expect(m.items == [.phrase, .plan, .notifications])
    #expect(!m.isDone(.phrase))

    await m.writeDownPhrase()
    let security = try #require(m.phraseSecurity)
    #expect(security.confirming == .viewPhrase)
    await security.confirm()
    security.confirmationDismissed()
    security.phraseRevealed = true
    #expect(m.isDone(.phrase))
    #expect(m.items == [.phrase, .plan, .notifications])
  }

  @Test func theFirstViewAsksForPaperAndALaterOneDoesNot() async {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    account.delay = .zero
    var s = services(account)
    let unseen = InMemoryUnseenPhrase()
    unseen.noteUnseen(at: .now)
    s.unseenPhrase = unseen
    let m = SecurityModel(session: AccountSession(services: s, phase: .ready))
    await m.load()
    m.requestPhrase()
    await m.confirm()
    m.confirmationDismissed()
    #expect(m.phraseFirstView)
    m.phraseRevealed = true
    #expect(m.phraseFirstView && !unseen.unseen)
    m.closePhrase()
    m.requestPhrase()
    await m.confirm()
    m.confirmationDismissed()
    #expect(!m.phraseFirstView)
  }

  @Test func homeSaysWhyTheWordsCouldNotBeShown() async throws {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    account.delay = .zero
    var s = services(account)
    let unseen = InMemoryUnseenPhrase()
    unseen.noteUnseen(at: .now)
    s.unseenPhrase = unseen
    let session = AccountSession(services: s, phase: .ready)
    let m = FinishSetupModel(services: s, session: { session })
    await m.writeDownPhrase()
    let security = try #require(m.phraseSecurity)
    #expect(m.phraseProblem == nil)
    account.failNext = .passkeyCantShowPhrase
    await security.confirm()
    security.confirmationDismissed()
    #expect(security.viewedPhrase == nil)
    #expect(m.phraseProblem == .passkeyCantShowUnseenPhrase)
    #expect(!m.isDone(.phrase))
  }

  @Test func aPasskeyThatDoesNotSyncKeepsTheWordsInSignup() async {
    let account = MockAccountService()
    account.passkeyPRF = true
    account.passkeySynced = false
    let unseen = InMemoryUnseenPhrase()
    var created = 0
    let m = await atMethod(account, unseen: unseen) { created += 1 }
    m.method = .passkey
    await m.continueWithMethod()
    #expect(!m.wordsLater)
    #expect(m.path.last == .phraseIntro)
    #expect(account.profile == nil && created == 0 && !unseen.unseen)
    showPhrase(m)
    await m.finish()
    #expect(m.path.last == .accountReady)
    #expect(!unseen.unseen)
  }

  @Test func theUnseenCopyPointsToSupportNotToPaper() async {
    let unseenCopy = AuthFailure.passkeyCantShowUnseenPhrase.message ?? ""
    #expect(!unseenCopy.contains("wrote down") && unseenCopy.contains("hasala.app/support"))
    for unseenNow in [true, false] {
      let account = MockAccountService(existing: .passkey, signedIn: true)
      account.delay = .zero
      var s = services(account)
      let unseen = InMemoryUnseenPhrase()
      if unseenNow { unseen.noteUnseen(at: .now) }
      s.unseenPhrase = unseen
      let m = SecurityModel(session: AccountSession(services: s, phase: .ready))
      await m.load()
      m.requestPhrase()
      account.failNext = .passkeyCantShowPhrase
      await m.confirm()
      #expect(m.confirming == nil)
      #expect(m.failure == (unseenNow ? .passkeyCantShowUnseenPhrase : .passkeyCantShowPhrase))
    }
  }

  @Test func aPasskeyStaysWhileTheWordsAreUnseen() async throws {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    account.delay = .zero
    var s = services(account)
    let unseen = InMemoryUnseenPhrase()
    unseen.noteUnseen(at: .now)
    s.unseenPhrase = unseen
    let m = SecurityModel(session: AccountSession(services: s, phase: .ready))
    await m.load()
    let id = try #require(m.state?.passkeys.first?.id)
    await m.request(.removePasskey(id: id))
    #expect(m.confirming == nil)
    #expect(m.failure == .wordsBeforeRemovingPasskey)
    unseen.noteSeen()
    await m.request(.removePasskey(id: id))
    #expect(m.confirming == .perform(.removePasskey(id: id)))
    #expect(m.failure == nil)
  }

  @Test func theServerAlwaysDecidesAfterAnAccountRead() async {
    let unseen = InMemoryUnseenPhrase()
    let since = Date(timeIntervalSince1970: 1_800_000_000)
    await unseen.adopt(serverUnseenSince: since)
    #expect(unseen.unseen && unseen.since == since)
    await unseen.adopt(serverUnseenSince: nil)
    #expect(!unseen.unseen)
    await unseen.adopt(serverUnseenSince: since)
    unseen.noteSeen()
    #expect(!unseen.unseen)
    await unseen.adopt(serverUnseenSince: since)
    #expect(unseen.unseen)
  }

  @Test func withoutAPasskeyTheWordsStayUnseenAndHomePointsToSupport() async {
    let account = MockAccountService(existing: .passwordOnly, signedIn: true)
    account.delay = .zero
    var s = services(account)
    let unseen = InMemoryUnseenPhrase()
    unseen.noteUnseen(at: .now)
    s.unseenPhrase = unseen
    let session = AccountSession(services: s, phase: .ready)
    let m = FinishSetupModel(services: s, session: { session })
    #expect(!m.isDone(.phrase))
    await m.writeDownPhrase()
    #expect(unseen.unseen && !m.isDone(.phrase))
    #expect(m.phraseFailure == .passkeyCantShowUnseenPhrase && m.phraseProblem == .passkeyCantShowUnseenPhrase)
    #expect(m.phraseSecurity?.confirming == nil && m.phraseSecurity?.viewedPhrase == nil)
    #expect(m.items.first == .phrase)
  }

  @Test func homeLeavesTheWordsOutWhenNothingIsPending() {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    let m = FinishSetupModel(services: services(account))
    #expect(m.items == [.plan, .notifications])
  }

  @Test func allowingNotificationsAsksForTheReminder() async {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    var s = services(account)
    let unseen = InMemoryUnseenPhrase()
    unseen.noteUnseen(at: .now)
    s.unseenPhrase = unseen
    let m = FinishSetupModel(services: s)
    m.askNotifications()
    await m.allowNotifications()
    #expect(unseen.reminders == 1)
  }
}

@MainActor
@Suite("The words reminder")
struct StoredUnseenPhraseTests {
  final class Calls {
    var allowed = true
    var scheduled: [Date] = []
    var cancelled = 0
  }

  @Test func theServerFillsAnEmptyCacheAndClearsAStaleOne() async {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let calls = Calls()
    let (store, defaults) = make(calls, now: start.addingTimeInterval(60))
    await store.adopt(serverUnseenSince: start)
    #expect(store.unseen && store.since == start)
    #expect(StoredUnseenPhrase(defaults: defaults).unseen)
    await store.adopt(serverUnseenSince: nil)
    #expect(!store.unseen && calls.cancelled == 1)
    store.noteUnseen(at: start)
    store.noteSeen()
    #expect(!store.unseen && !StoredUnseenPhrase(defaults: defaults).unseen)
    await store.adopt(serverUnseenSince: start)
    #expect(store.unseen)
    StoredUnseenPhrase.forget(defaults)
    #expect(!StoredUnseenPhrase(defaults: defaults).unseen)
  }

  private func make(_ calls: Calls, now: Date) -> (StoredUnseenPhrase, UserDefaults) {
    let name = "phrase.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    let scheduler = StoredUnseenPhrase.Scheduler(
      allowed: { calls.allowed },
      schedule: { _, at in
        calls.scheduled.append(at)
        return true
      },
      cancel: { _ in calls.cancelled += 1 })
    return (StoredUnseenPhrase(defaults: defaults, scheduler: scheduler, now: { now }), defaults)
  }

  @Test func remindsOnceADayAfterSignupWhenAllowed() async {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let calls = Calls()
    let (store, defaults) = make(calls, now: start.addingTimeInterval(60))
    #expect(!store.unseen)
    store.noteUnseen(at: start)
    #expect(store.unseen)
    #expect(StoredUnseenPhrase(defaults: defaults).unseen)
    await store.remindIfAllowed()
    await store.remindIfAllowed()
    #expect(calls.scheduled == [start.addingTimeInterval(24 * 60 * 60)])
    store.noteSeen()
    #expect(!store.unseen && calls.cancelled == 1)
    await store.remindIfAllowed()
    #expect(calls.scheduled.count == 1)
  }

  @Test func noReminderWithoutPermissionOrAfterTheDay() async {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let calls = Calls()
    calls.allowed = false
    let (store, _) = make(calls, now: start.addingTimeInterval(60))
    store.noteUnseen(at: start)
    await store.remindIfAllowed()
    #expect(calls.scheduled.isEmpty)

    let late = Calls()
    let (after, _) = make(late, now: start.addingTimeInterval(25 * 60 * 60))
    after.noteUnseen(at: start)
    await after.remindIfAllowed()
    #expect(late.scheduled.isEmpty)
  }
}
