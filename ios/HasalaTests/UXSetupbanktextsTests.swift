import Foundation
import CoreStore
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Bank texts setup copy and states")
struct UXSetupbanktextsTests {
  static let t0 = Date(timeIntervalSince1970: 1_792_000_000)

  final class Clock {
    var now: Date
    init(_ now: Date) { self.now = now }
  }

  struct Rig {
    let facts: BankTextsFacts
    let lane: LiveBankTexts
    let clock: Clock
  }

  func rig(hintDelay: Duration) -> Rig {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ux-texts-\(UUID().uuidString)")
    let facts = BankTextsFacts(directory: dir.appendingPathComponent("facts"))
    let clock = Clock(Self.t0)
    let author = FakeTextAuthor()
    let store = MemorySecretStore()
    let lane = LiveBankTexts(
      facts: facts, marker: LockedTextsMarkerFile(directory: dir.appendingPathComponent("marker")),
      reader: FakeTextReader([:]), author: { author }, secret: { TextKeySecret(store: store) },
      now: { clock.now }, hintDelay: hintDelay)
    return Rig(facts: facts, lane: lane, clock: clock)
  }

  func waitForHints(_ lane: LiveBankTexts) async throws {
    for _ in 0..<200 where lane.test != .nothingYet { try await Task.sleep(for: .milliseconds(5)) }
  }

  @Test func theTestShowsWhatToCheckAfterAMinuteWhileTheWindowStaysOpen() async throws {
    let r = rig(hintDelay: .milliseconds(20))
    r.lane.startTest()
    #expect(r.lane.test == .waiting(since: Self.t0) && r.lane.testWindowOpen)
    try await waitForHints(r.lane)
    #expect(r.lane.test == .nothingYet && r.lane.testWindowOpen)
    #expect(BankTextsTestScreen.nothingYetNote(windowOpen: r.lane.testWindowOpen) == "Hasala is still watching for the test text.")
    r.lane.returnedToForeground()
    #expect(r.lane.test == .nothingYet)
  }

  @Test func aLateTestTextStillPassesAfterTheHints() async throws {
    let r = rig(hintDelay: .milliseconds(20))
    r.lane.startTest()
    try await waitForHints(r.lane)
    let passed = BankTextIntake.ms(Self.t0.addingTimeInterval(120))
    _ = try r.facts.update(nowMs: passed) {
      $0.testPassedMs = passed
      $0.testOpenedMs = nil
    }
    r.lane.reload()
    #expect(r.lane.test == .received(at: Self.t0.addingTimeInterval(120)))
  }

  @Test func afterTheWindowClosesHasalaSaysItStoppedWatching() {
    let r = rig(hintDelay: .seconds(60))
    r.lane.startTest()
    r.clock.now = Self.t0.addingTimeInterval(11 * 60)
    r.lane.reload()
    #expect(r.lane.test == .nothingYet && !r.lane.testWindowOpen)
    #expect(BankTextsTestScreen.nothingYetNote(windowOpen: false) == "Hasala stopped watching. Tap Send the test again.")
  }

  @Test func theAutomationStepsSayAlmostEveryTextReachesHasala() throws {
    let link = try #require(URL(string: "https://www.icloud.com/shortcuts/test"))
    let subtitle =
      "One automation in the Shortcuts app hands Hasala almost every text you get, from anyone, on this iPhone. Hasala keeps only payments."
    #expect(TextsSetUpCopy(install: link).subtitle == subtitle && TextsSetUpCopy(install: nil).subtitle == subtitle)
    let sentences = BankTexts.keepsPayments.split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces) }
    #expect(sentences.filter { $0.hasPrefix("Hasala") }.count == 1)
    #expect(BankTexts.keepsPayments.contains("from any sender") && BankTexts.keepsPayments.contains("never saved or sent"))
  }

  @Test func backFromShortcutsTheTestLeadsAndAddingAgainWarnsOfTwoAutomations() throws {
    let link = try #require(URL(string: "https://www.icloud.com/shortcuts/test"))
    let ready = TextsSetUpCopy(install: link)
    #expect(!ready.returned(opened: false) && ready.returned(opened: true))
    #expect(ready.testTitle == "I turned it on, send a test" && ready.againTitle == "Add to Shortcuts again")
    #expect(ready.againNote == "Only if it didn't add. Two automations bring in each text twice.")
    #expect(BankTextsGuide.alreadyMade.hasSuffix(BankTextsGuide.twoAutomations))
    #expect(!TextsSetUpCopy(install: nil).returned(opened: true))
  }

  @Test func theSourceCardsSayWhatEachReadsAndWhichBanks() {
    #expect(SourceCardCopy.upsides(.texts) == [
      "No mailbox access, no Google warning", "Works when your bank only texts", "Any bank that texts you",
    ])
    #expect(SourceCardCopy.downsides(.texts).first == "Hasala sees each text with a full stop, from anyone, and drops all but payments")
    #expect(SourceCardCopy.upsides(.email).last == "Emirates NBD, DIB and ADIB")
    #expect(SourceCardCopy.downsides(.email) == ["Gmail shows an unverified-app warning in the beta"])
  }

  @Test func messagesOpensWithTheTestWritten() {
    #expect(BankTexts.messagesURL.absoluteString == "sms:&body=Hasala%20test.")
    #expect(BankTextsTestScreen.subtitle(.idle) == "Messages opens with the test written. Send it to your own number. Hasala is watching for it.")
    #expect(BankTextsTestScreen.copiedFor == .seconds(2))
  }

  @Test func theFakedSenderLineShowsWhereTextsAreRead() {
    #expect(BankTexts.fakedTextNote == "A text's sender can be faked. If you don't recognise a payment, check your bank's app, then archive it here.")
    #expect(BankTextsAlertsPage.readsRows.map(\.text).contains(BankTexts.fakedTextNote))
  }

  @Test func theBankTextsPageSaysEachThingOnce() {
    let now = Self.t0
    let hero = BankTextsAlertsPage.Hero(
      .working(lastRan: now.addingTimeInterval(-240)), lastText: now.addingTimeInterval(-240), now: now)
    #expect(hero.detail == "Last text added 4 min ago")
    #expect(BankTextsAlertsPage.skippedTitle == "Skipped texts")
    #expect(BankTexts.setAsideDetail(BankTextsSetAside(sender: "DIB", bank: .dib, counts: [.promotion: 1])) == "1 text skipped in the last 30 days\n1 promotion")
    let rows = BankTextsAlertsPage.readsRows.map(\.text)
    #expect(rows.count == 4 && rows.contains(BankTexts.keepsNoText))
    #expect(BankTexts.keepsNoText.contains("never leaves this iPhone") && BankTexts.keepsNoText.contains("end\u{2011}to\u{2011}end encrypted"))
  }

  @Test func thePasteIntroGoesAndTheDockIsSolidOnceAMatchShows() async {
    let lane = MockBankTexts(setUp: true)
    lane.readDelay = .zero
    lane.nextMatch = BankTextMatch(
      rowID: "r1", kind: .unreadText, merchant: nil, amount: nil, postedAt: Self.t0, fromText: true)
    let m = PasteBankTextModel(lane: lane)
    #expect(m.showsIntro && !m.solidDock)
    await m.paste(MockBankTexts.sampleText)
    #expect(!m.showsIntro && m.solidDock)
  }

  @Test func theSeveralPaymentsWarningSaysWhichOneIsAdded() {
    #expect(PasteBankTextModel.severalNote(3) == "This paste has 3 payments. Hasala adds only the one shown above. Paste the others one at a time.")
  }

  @Test func theTextsSwitchSaysMailbox() {
    #expect(UseBankTextsSection.useTextsDetail == "No mailbox access. Set up a Shortcut once.")
    #expect(SourceCardCopy.upsides(.texts).allSatisfy { !$0.contains("inbox") })
  }
}
