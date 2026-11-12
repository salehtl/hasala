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

  @Test func aRetryClearsTheLastFailureWhileItRuns() {
    var form = SenderAddressForm()
    form.typed = "alerts@newbank.example"
    #expect(form.begin() == "alerts@newbank.example" && form.busy)
    form.finish(.refused("Type an address that ends in @newbank.example."))
    #expect(form.failure == "Type an address that ends in @newbank.example." && !form.busy)
    #expect(form.begin() == "alerts@newbank.example")
    #expect(form.failure == nil && form.busy)
    form.finish(.offline)
    #expect(form.failure == SenderAddressForm.offlineLine && !form.busy)
  }

  @Test func editingTheAddressClearsTheFailureAndRetypingTheSameDoesNot() {
    var form = SenderAddressForm()
    form.typed = "alerts@newbank.example"
    _ = form.begin()
    form.finish(.offline)
    form.typed = "alerts@newbank.example"
    #expect(form.failure == SenderAddressForm.offlineLine)
    form.typed = "alert@newbank.example"
    #expect(form.failure == nil)
  }

  @Test func anAddRunsOnlyWithAnAddressAndOneAtATime() {
    var form = SenderAddressForm()
    form.typed = "   "
    #expect(!form.canAdd && form.begin() == nil && !form.busy)
    form.typed = "alerts@newbank.example"
    #expect(form.canAdd && form.begin() != nil)
    #expect(!form.canAdd && form.begin() == nil)
    form.finish(.added("alerts@newbank.example"))
    #expect(form.failure == nil && !form.busy)
  }

  @Test func theSheetSaysWhyTheAddressIsNeeded() {
    #expect(AddSenderAddressSheet.note("newbank.example").contains("exact address"))
    #expect(BankAlertsPage.unlistedDetail == "Add the address it sends from.")
  }
}
