import CoreDomain
import CoreResources
import CoreTestSupport
import Foundation
import Testing

@testable import CoreMailbox
@testable import CoreTemplate

@Suite("text templates and mail")
struct TextTemplateGateTests {
  @Test("mail never runs a text template: one that names a mail domain does not compile")
  func mailNeverRunsATextTemplate() throws {
    let texts = BundledTemplates.load(channel: .sms).templates
    var forged = try #require(texts.first).definition
    forged.match.senderDomain = ["dib.ae"]
    #expect(throws: TemplateError.self) { try CompiledTemplate(forged) }
    let matching = MessageDisposer.templatesMatching(BundledTemplates.load(channel: .mail).templates + texts, domains: ["dib.ae"])
    #expect(!matching.isEmpty)
    #expect(matching.allSatisfy { !$0.definition.isSMS })
  }

  @Test("an ENBD refund text is a refund, as DIB's are")
  func enbdRefundIsARefund() {
    #expect(MessageDisposer.refundDecision(template: "enbd.sms.refund.v1@1", direction: "credit")?.category == "refunds")
    #expect(MessageDisposer.refundDecision(template: "enbd.sms.refund.v1@1", direction: "debit") == nil)
    #expect(MessageDisposer.refundDecision(template: "enbd.sms.credit.v1@1", direction: "credit") == nil)
  }

  @Test("every template the app names by id is a bundled template")
  func namedTemplatesAreBundled() {
    let bundled = Set((BundledTemplates.load(channel: .mail).templates + BundledTemplates.load(channel: .sms).templates).map(\.definition.id))
    let named =
      MessageDisposer.refundTemplates + ModelSuggestionSweep.cloudTemplates.sorted()
      + TextTransferRole.byTemplate.keys.sorted()
    #expect(!named.isEmpty)
    for id in named {
      #expect(bundled.contains(id), "\(id) is named in the app but no bundled template has that id")
    }
  }

  @Test("mail halts templates_unavailable when no mail template loads, even when every text template does")
  func onlyTextTemplatesHaltTheMailbox() async throws {
    let textIDs = Set(BundledTemplates.load(channel: .sms).templates.map(\.definition.id))
    #expect(textIDs.count == 18)
    let entries = TemplatesManifest.entries.map { e in
      textIDs.contains(e.id)
        ? e : TemplatesManifest.Entry(file: e.file, id: e.id, version: e.version, sha256: String(repeating: "0", count: 64))
    }
    let read: (String) -> Data? = { file in
      CoreResources.bundle.url(forResource: file, withExtension: nil, subdirectory: "templates").flatMap { try? Data(contentsOf: $0) }
    }
    let texts = BundledTemplates.load(entries: entries, channel: .sms, read: read)
    #expect(Set(texts.templates.map(\.definition.id)) == textIDs)
    #expect(texts.skipped.count == entries.count - textIDs.count)
    let mailOnly = BundledTemplates.load(entries: entries, channel: .mail, read: read)
    #expect(mailOnly.templates.isEmpty)
    #expect(mailOnly.skipped.count == entries.count - textIDs.count)

    let rig = Rig(templates: mailOnly.templates + texts.templates)
    rig.gmail.add(SyntheticMail.dibCard(id: "m1", dateMs: Rig.t0 - 86_400_000))
    await rig.connectAndActivate()
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.haltedOn == .templatesUnavailable)
    #expect(await rig.state().haltedOn == .templatesUnavailable)
    #expect(await rig.enqueued().isEmpty)
    #expect(rig.rawRequests.isEmpty)

    let mail = Rig(templates: BundledTemplates.load(channel: .mail).templates + BundledTemplates.load(channel: .sms).templates)
    mail.gmail.add(SyntheticMail.dibCard(id: "m1", dateMs: Rig.t0 - 86_400_000))
    await mail.connectAndActivate()
    #expect(await mail.state().haltedOn == nil)
    #expect(await mail.enqueued().map(\.messageID) == ["m1"])
  }
}
