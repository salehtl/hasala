import Testing

@testable import HasalaDesign

@Suite("Mail address display")
struct MailAddressTests {
  @Test func breaksAfterAtAndDotsWithoutBreakingHyphens() {
    #expect(MailboxRow.displayAddress("first.last+bank-alerts@example.com")
      == "first.\u{200B}last+bank\u{2011}alerts@\u{200B}example.\u{200B}com")
  }

  @Test func leavesPlainNamesAlone() {
    #expect(MailboxRow.displayAddress("Gmail") == "Gmail")
    #expect(MailboxRow.displayAddress("") == "")
  }

  @Test func removingTheBreaksGivesTheAddressBack() {
    let address = "maya-k.test@mail.example.ae"
    let shown = MailboxRow.displayAddress(address)
    #expect(shown.replacingOccurrences(of: "\u{200B}", with: "").replacingOccurrences(of: "\u{2011}", with: "-") == address)
  }
}
