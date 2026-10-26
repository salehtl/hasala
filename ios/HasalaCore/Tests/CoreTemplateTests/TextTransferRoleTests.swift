import Testing

@testable import CoreTemplate

@Suite("text transfer roles")
struct TextTransferRoleTests {
  static var textTemplates: [CompiledTemplate] { BundledTemplates.load(channel: .sms).templates }

  @Test("every bundled text template has its transfer role decided, and the tables name nothing else")
  func everyTextTemplateIsDecided() {
    let ids = Self.textTemplates.map(\.definition.id)
    #expect(!ids.isEmpty)
    let roled = Set(TextTransferRole.byTemplate.keys)
    #expect(roled.isDisjoint(with: TextTransferRole.withoutRole))
    #expect(roled.union(TextTransferRole.withoutRole) == Set(ids))
    for id in ids {
      #expect(roled.contains(id) != TextTransferRole.withoutRole.contains(id), "\(id)")
    }
  }

  @Test("a transfer role sits only on a template that always reads a debit")
  func rolesAreOnDebitTemplates() {
    let roled = Self.textTemplates.filter { TextTransferRole.byTemplate[$0.definition.id] != nil }
    #expect(roled.count == TextTransferRole.byTemplate.count)
    for t in roled {
      let directions = t.definition.extract.filter { $0.field == "direction" }
      #expect(directions.count == 1, "\(t.definition.id)")
      #expect(directions.allSatisfy { $0.type == "const" && $0.value == "debit" }, "\(t.definition.id)")
    }
  }

  @Test("DIB's own transfer is the notice and its account debit the alert; nothing else has a role")
  func dib() {
    #expect(TextTransferRole.of(templateRef: "dib.sms.own-transfer.v1@1") == .notice)
    #expect(TextTransferRole.of(templateRef: "dib.sms.own-transfer.v1") == .notice)
    #expect(TextTransferRole.of(templateRef: "dib.sms.debit.v1@1") == .alert)
    #expect(TextTransferRole.of(templateRef: "dib.sms.debit.v1") == .alert)
    for ref in [
      "", "@1", "dib.sms.purchase.v1@1", "dib.sms.card-payment.v1@1", "dib.transfer.v1@1", "dib.account.v1@4",
      "dib.money-transfer.v1@1", "dib.sms.debit.v10@1", "DIB.SMS.DEBIT.V1@1", " dib.sms.debit.v1@1",
    ] {
      #expect(TextTransferRole.of(templateRef: ref) == nil, "\(ref)")
    }
    #expect(TextTransferRole.notice.counterpart == .alert)
    #expect(TextTransferRole.alert.counterpart == .notice)
  }
}
