import CoreMailbox
import Foundation
import Testing

@testable import Hasala

@MainActor
@Suite("Add a sender on Outlook")
struct SenderAddressTests {
  @Test func everyRefusalHasALine() {
    let errors: [BankDomains.TypedDomainError] = [.empty, .addressRequired, .forwarder, .sharedSuffix, .notQuerySafe, .nonASCII]
    for e in errors {
      #expect(!LiveMailboxConnecting.senderLine(e, "newbank.example").isEmpty)
    }
    #expect(LiveMailboxConnecting.senderLine(.addressRequired, "newbank.example") == "Type the full address, such as alerts@newbank.example.")
    #expect(LiveMailboxConnecting.senderLine(.notQuerySafe, "newbank.example", other: true) == "Type an address that ends in @newbank.example.")
  }

  @Test func theSheetSaysWhyTheAddressIsNeeded() {
    #expect(AddSenderAddressSheet.note("newbank.example").contains("exact address"))
    #expect(BankAlertsPage.unlistedDetail == "Not read on Outlook. Add the address it sends from.")
  }
}
