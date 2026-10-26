import CoreJSON
import Foundation
import Testing

@testable import CoreTemplate

@Suite("the text channel")
struct TextChannelTests {
  static func sms(dateFrom: String = "received", channel: String = "\"sms\"", required: String = "[\"amount\",\"direction\"]",
    layouts: String = "[\"DD-MM-YYYY HH:mm\"]") -> [UInt8]
  {
    Array(
      """
      {"id":"t.sms.v1","version":1,"bank":"t","channel":\(channel),"normalizer_version":1,
       "match":{"sms_sender":["BANK-SMS","AD-Bank"]},"default_currency":"AED","date_from":"\(dateFrom)",
       "required":\(required),
       "extract":[{"field":"amount","type":"amount","source":"body","patterns":["Amt: (?P<amt>[0-9][0-9,]{0,24}\\\\.[0-9]{2})"]},
        {"field":"direction","type":"const","source":"body","value":"debit"},
        {"field":"date","type":"date","source":"body","layouts":\(layouts),"patterns":["Date: (?P<d>[^\\\\n]+)"]}]}
      """.utf8)
  }

  @Test("an sms definition reads its channel and senders, and loads only with date_from received")
  func loads() throws {
    let t = try CompiledTemplate(json: Self.sms())
    #expect(t.definition.isSMS)
    #expect(t.definition.match.smsSender == ["BANK-SMS", "AD-Bank"])
    #expect(try t.execute(subject: "", normalizedBody: "Amt: 12.34\nDate: 05-06-2026 14:30").postedAt == "2026-06-05T14:30:00Z")
    let undated = try t.execute(subject: "", normalizedBody: "Amt: 12.34")
    #expect(undated.matched)
    #expect(undated.postedAt == "")
    #expect(throws: TemplateError.self) { try CompiledTemplate(json: Self.sms(dateFrom: "body")) }
    #expect(throws: TemplateError.self) { try CompiledTemplate(json: Self.sms(dateFrom: "email")) }
    #expect(throws: TemplateError.self) { try CompiledTemplate(json: Self.sms(channel: "\"fax\"")) }
    #expect(throws: TemplateError.self) { try CompiledTemplate(json: Self.sms(channel: "\"mail\"")) }
    #expect(throws: TemplateError.self) {
      try CompiledTemplate(json: Self.sms(required: "[\"amount\",\"direction\",\"date\"]"))
    }
    #expect(throws: TemplateError.self) { try CompiledTemplate(json: Self.sms(channel: "1")) }
  }

  @Test("the timed numeric layout reads as Go's 02-01-2006 15:04")
  func timedLayout() {
    let l = ["DD-MM-YYYY HH:mm"]
    #expect(CompiledTemplate.convertDate("05-06-2026 14:30", l) == "2026-06-05T14:30:00Z")
    #expect(CompiledTemplate.convertDate("05-06-2026 00:00", l) == "2026-06-05T00:00:00Z")
    #expect(CompiledTemplate.convertDate("05-06-2026 23:59", l) == "2026-06-05T23:59:00Z")
    #expect(CompiledTemplate.convertDate("05-06-2026 8:05", l) == "2026-06-05T08:05:00Z")
    #expect(CompiledTemplate.convertDate("05-06-2026 24:00", l) == nil)
    #expect(CompiledTemplate.convertDate("05-06-2026 12:60", l) == nil)
    #expect(CompiledTemplate.convertDate("05-06-2026 12:5", l) == nil)
    #expect(CompiledTemplate.convertDate("05-06-2026 123:45", l) == nil)
    #expect(CompiledTemplate.convertDate("05-06-2026", l) == nil)
    #expect(CompiledTemplate.convertDate("05-06-2026  14:30", l) == nil)
    #expect(CompiledTemplate.convertDate("05-06-2026T14:30", l) == nil)
    #expect(CompiledTemplate.convertDate("31-02-2026 10:00", l) == nil)
    #expect(CompiledTemplate.convertDate("05-06-2026 garbage", l + ["DD-MM-YYYY"]) == "2026-06-05T00:00:00Z")
  }

  @Test("the sender gate is exact, ignores ASCII case and trims the executor's cutset")
  func senders() throws {
    let d = try TemplateDefinition(json: Self.sms())
    for (s, want) in [
      ("BANK-SMS", true), ("bank-sms", true), (" BANK-SMS\n", true), ("ad-bank", true), ("BANK-SMS2", false), ("BANK", false),
      ("BANK SMS", false), ("", false), ("   ", false), ("BANK-SMS\u{A0}", false),
    ] {
      #expect(d.matchesSMSSender(s) == want, "\(s)")
    }
    var mail = d
    mail.channel = ""
    #expect(!mail.matchesSMSSender("BANK-SMS"))
  }

  @Test("a mail definition's canonical bytes do not gain the text keys; an sms definition's do")
  func canonical() throws {
    let plain = try TemplateDefinition(json: Array("{\"id\":\"x\",\"version\":1}".utf8))
    let mail = try TemplateDefinition(json: Array("{\"id\":\"x\",\"version\":1,\"channel\":\"mail\"}".utf8))
    #expect(plain.canonicalJSON() == mail.canonicalJSON())
    #expect(!String(decoding: plain.canonicalJSON(), as: UTF8.self).contains("channel"))
    let sms = try TemplateDefinition(json: Array("{\"id\":\"x\",\"version\":1,\"channel\":\"sms\",\"match\":{\"sms_sender\":[\"B\"]}}".utf8))
    let want =
      "{\"bank\":\"\",\"channel\":\"sms\",\"date_from\":\"\",\"default_currency\":\"\",\"extract\":[],\"id\":\"x\","
      + "\"match\":{\"body_contains\":[],\"body_not_contains\":[],\"sender_domain\":[],\"sms_sender\":[\"B\"],\"subject_contains\":[]},"
      + "\"normalizer_version\":0,\"required\":[],\"version\":1}"
    #expect(String(decoding: sms.canonicalJSON(), as: UTF8.self) == want)
  }

  @Test("the bundled sms templates read the DIB text families and never run as mail templates")
  func bundled() throws {
    let all = BundledTemplates.load().templates
    let texts = all.filter(\.definition.isSMS)
    #expect(texts.count == 8)
    for t in texts {
      #expect(t.definition.match.senderDomain.isEmpty)
      #expect(t.definition.matchesSMSSender("DIB-SMS"))
      #expect(t.definition.bank == "dib")
    }
    let purchase = try #require(texts.first { $0.definition.id == "dib.sms.purchase.v1" })
    let body = "مشتريات بمبلغ 123.45 من بطاقة XX1234 في 05-06-2026 10:11 من SAMPLE SHOP. الحد الائتماني المتاح 1,234.56"
    let x = try purchase.execute(subject: "", normalizedBody: body)
    #expect(x.matched && x.amountMinor == 12_345 && x.currency == "AED" && x.direction == "debit")
    #expect(x.merchant == "SAMPLE SHOP" && x.last4 == "1234" && x.postedAt == "2026-06-05T10:11:00Z")
    let matching = texts.filter { (try? $0.execute(subject: "", normalizedBody: body).matched) == true }
    #expect(matching.map(\.definition.id) == ["dib.sms.purchase.v1"])
  }
}
