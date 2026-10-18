import CoreJSON
import CoreMailbox
import CoreTestSupport
import Foundation
import Testing

@Suite struct MessageIDEvidenceTests {
  @Test func theHeaderIsNormalizedThenHashed() {
    let a = "From: x@example.invalid\r\nMessage-ID: <ABC.123@Mail.Example.Invalid>\r\nSubject: s\r\n"
    let b = "message-id:\r\n  <abc.123@mail.example.invalid>\r\nFrom: y@example.invalid\r\n"
    #expect(MessageIDEvidence.normalized(headers: a) == "abc.123@mail.example.invalid")
    #expect(MessageIDEvidence.normalized(headers: b) == "abc.123@mail.example.invalid")
    let h = MessageIDEvidence.hash(headers: a)
    #expect(h == MessageIDEvidence.hash(headers: b))
    #expect(h?.utf8.count == 32 && h.map { !$0.contains("abc") } == true)
    #expect(MessageIDEvidence.hash(headers: "From: x\r\nSubject: s\r\n") == nil)
    #expect(MessageIDEvidence.hash(headers: "Message-ID: <>\r\n") == nil)
    #expect(MessageIDEvidence.normalized(headers: "X-Message-ID: <a@b>\r\n") == nil)
  }

  @Test func everyImportCarriesTheHashNotTheHeader() async throws {
    let rig = Rig()
    let day: Int64 = 86_400_000
    rig.gmail.add(SyntheticMail.dibCard(id: "d1", dateMs: Rig.t0 - 5 * day))
    await rig.connectAndActivate()
    let drafts = await rig.enqueued()
    let d = try #require(drafts.first)
    let want = MessageIDEvidence.hash(headers: "Message-ID: <\(Rig.t0 - 5 * day).synthetic@example.invalid>")
    #expect(d.payload["dedupe"]?["message_id"] == want.map(JSONValue.string))
    #expect(!JSONWriter().string(.object(d.payload)).contains("synthetic@example.invalid"))
  }
}
