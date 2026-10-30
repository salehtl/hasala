import Foundation
import HasalaDesign
import HasalaMocks
import HasalaModels
import Testing

@Suite("Review · bank texts")
struct BankTextReviewTests {
  let s = Scenario.mayaTexts.state
  let now = MayaLedger.now

  @Test func aRowThatMayRepeatATextSaysSoAndNamesIt() throws {
    let mail = try #require(s.txn("mail-twin"))
    #expect(mail.activeReviewReason == .mayRepeat)
    let card = ReviewEngine.card(mail, s)
    #expect(card.reviewReason == .mayRepeat && card.reasonLine == "This may be the same payment as a bank text from DIB on 9 October.")
    #expect(ReviewEngine.tabRow(card, s).subtitle == "Same payment? · you decide")
    #expect(ActivityEngine.row(mail, s).detail.hasPrefix("Same payment?"))
    let pair = ReviewEngine.card(try #require(s.txn("text-transfer")), s)
    #expect(pair.reasonLine == "This may be the same transfer as the bank text from DIB at 12:31." && pair.fromText)
    #expect(TransactionEngine.detail("mail-twin", s, now: now)?.reasonLine == card.reasonLine)
  }

  @Test func aSortedRowOrAnUnverifiedSenderHidesTheRepeatLine() throws {
    var t = try #require(s.txn("mail-twin"))
    t.needsReview = false
    t.categoryID = "groceries"
    #expect(t.activeReviewReason == nil && ReviewEngine.card(t, s).reasonLine == nil)
  }

  @Test func aTextRowCardKnowsItCameFromATextAndHidesAnEmptyMerchant() throws {
    var t = try #require(s.txn("text-transfer"))
    #expect(ReviewEngine.card(t, s).fromText && ReviewEngine.card(t, s).rawMerchant == "MB FUND TRANSFER")
    t.provenance?.rawMerchant = ""
    #expect(ReviewEngine.card(t, s).rawMerchant == nil)
    #expect(!ReviewEngine.card(try #require(s.txn("mail-twin")), s).fromText)
  }

  @Test func unreadTextsAreNewestFirstWithTheirOwnCopy() {
    let texts = ReviewEngine.unreadTexts(s)
    #expect(texts.map(\.id) == ["unread-text-dib", "unread-text-other"])
    let today = now.date
    #expect(ReviewEngine.unreadTextTitle(texts[0]) == "Text from DIB" && ReviewEngine.unreadTextTitle(texts[1]) == "Bank text")
    #expect(ReviewEngine.unreadTextDetail(texts[0], today: today) == "Received today, 09:58")
    #expect(ReviewEngine.unreadTextDetail(texts[1], today: today) == "Received Thu 8 Oct, 19:12")
    #expect(
      ReviewEngine.unreadTextBody(texts[1], today: today, canPaste: true)
        == "Hasala couldn't read this bank text. Find the text at 19:12 on Thu 8 Oct in Messages, copy it and paste it here, or add the payment yourself.")
    #expect(s.unreadMail.isEmpty && ReviewEngine.unreadCount(s) == 0)
  }

  @Test func theBellGetsOneItemForUnreadTextsThatOpensTheirPage() {
    var t = s
    let bell = NotificationsEngine.snapshot(t, now: now)
    let item = bell.needsALook.first { $0.id == "unreadTexts" }
    #expect(item?.title == "2 bank texts we couldn't read" && item?.destination == .unreadTexts)
    #expect(item?.disc == .neutral(.chat) && item?.line.rendered(hidden: false) == "Add each one by hand or dismiss it" && item?.when == "Today")
    #expect(bell.needsALook.first { $0.id == "unread" } == nil)
    t.unreadTexts = []
    #expect(NotificationsEngine.snapshot(t, now: now).needsALook.first { $0.id == "unreadTexts" } == nil)
    #expect(Glyph.chat.icon == .chat)
  }

  @Test func aTextProvenanceSurvivesCodingAndAnOldOneIsMail() throws {
    let t = try #require(s.txn("text-grocer"))
    let back = try JSONDecoder().decode(Txn.self, from: JSONEncoder().encode(t))
    #expect(back.provenance?.isText == true && back.fromText)
    let old = try JSONDecoder().decode(Provenance.self, from: Data(#"{"title":"t","readAt":"r","rawMerchant":"m"}"#.utf8))
    #expect(!old.isText)
  }
}
