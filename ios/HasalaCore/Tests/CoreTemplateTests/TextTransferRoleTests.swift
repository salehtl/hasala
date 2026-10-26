import Testing

@testable import CoreTemplate

@Suite("text transfer roles")
struct TextTransferRoleTests {
  static var textTemplates: [CompiledTemplate] { BundledTemplates.load(channel: .sms).templates }

  @Test("the roles come from the bundled definitions: DIB's own transfer is the notice, its account debit the alert")
  func rolesComeFromTheBundle() {
    #expect(TextTransferRole.byTemplate == ["dib.sms.own-transfer.v1": .notice, "dib.sms.debit.v1": .alert])
    #expect(Self.textTemplates.count == 8)
    for t in Self.textTemplates {
      #expect(TextTransferRole.byTemplate[t.definition.id] == TextTransferRole(definition: t.definition), "\(t.definition.id)")
    }
    for t in BundledTemplates.load(channel: .mail).templates {
      #expect(t.definition.transferRole.isEmpty, "\(t.definition.id)")
      #expect(TextTransferRole(definition: t.definition) == nil, "\(t.definition.id)")
    }
  }

  @Test("a transfer role sits only on a template that always reads a debit")
  func rolesAreOnDebitTemplates() {
    let roled = Self.textTemplates.filter { TextTransferRole(definition: $0.definition) != nil }
    #expect(roled.count == TextTransferRole.byTemplate.count)
    for t in roled {
      let directions = t.definition.extract.filter { $0.field == "direction" }
      #expect(directions.count == 1, "\(t.definition.id)")
      #expect(directions.allSatisfy { $0.type == "const" && $0.value == "debit" }, "\(t.definition.id)")
      #expect(t.definition.extract.allSatisfy { !$0.onMatch.contains { $0.key == "direction" } }, "\(t.definition.id)")
    }
  }

  @Test("a template ref names its role by id, whatever its version; nothing else has a role")
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

  @Test("the role is read from transfer_role; the executor refuses an unknown role and a role on a mail template")
  func definitionRules() throws {
    for (role, want) in [("notice", TextTransferRole.notice), ("alert", .alert)] {
      let t = try CompiledTemplate(json: TextChannelTests.sms(channel: "\"sms\",\"transfer_role\":\"\(role)\""))
      #expect(t.definition.transferRole == role)
      #expect(TextTransferRole(definition: t.definition) == want)
    }
    let none = try CompiledTemplate(json: TextChannelTests.sms())
    #expect(none.definition.transferRole.isEmpty)
    #expect(TextTransferRole(definition: none.definition) == nil)
    for role in ["\"both\"", "\"ALERT\"", "\"Notice\"", "\" alert\"", "1", "true"] {
      #expect(throws: TemplateError.self, "\(role)") {
        try CompiledTemplate(json: TextChannelTests.sms(channel: "\"sms\",\"transfer_role\":\(role)"))
      }
    }
    let mail = TextChannelTests.sms(
      dateFrom: "body", channel: "\"mail\",\"transfer_role\":\"notice\"", match: "{\"sender_domain\":[\"example.com\"]}")
    #expect(throws: TemplateError.self) { try CompiledTemplate(json: mail) }
    var forged = try TemplateDefinition(
      json: TextChannelTests.sms(dateFrom: "body", channel: "\"mail\"", match: "{\"sender_domain\":[\"example.com\"]}"))
    _ = try CompiledTemplate(forged)
    forged.transferRole = "alert"
    #expect(TextTransferRole(definition: forged) == nil)
    #expect(throws: TemplateError.self) { try CompiledTemplate(forged) }
  }
}
