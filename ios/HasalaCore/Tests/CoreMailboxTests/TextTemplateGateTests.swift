import CoreDomain
import CoreResources
import CoreTestSupport
import Foundation
import Testing

@testable import CoreMailbox
@testable import CoreTemplate

@Suite("text templates and mail")
struct TextTemplateGateTests {
  @Test("mail never runs a text template, even one that names a mail domain")
  func mailNeverRunsATextTemplate() throws {
    let templates = BundledTemplates.load().templates
    var forged = try #require(templates.first { $0.definition.isSMS }).definition
    forged.match.senderDomain = ["dib.ae"]
    let compiled = try CompiledTemplate(forged)
    #expect(MessageDisposer.templatesMatching([compiled], domains: ["dib.ae"]).isEmpty)
    let matching = MessageDisposer.templatesMatching(templates, domains: ["dib.ae"])
    #expect(!matching.isEmpty)
    #expect(matching.allSatisfy { !$0.definition.isSMS })
  }

  @Test("every template the app names by id is a bundled template")
  func namedTemplatesAreBundled() {
    let bundled = Set(BundledTemplates.load().templates.map(\.definition.id))
    let named =
      MessageDisposer.refundTemplates + ModelSuggestionSweep.cloudTemplates.sorted()
      + TextTransferRole.byTemplate.keys.sorted() + TextTransferRole.withoutRole.sorted()
    #expect(!named.isEmpty)
    for id in named {
      #expect(bundled.contains(id), "\(id) is named in the app but no bundled template has that id")
    }
  }

  @Test("mail halts templates_unavailable when no mail template loads, even when every text template does")
  func onlyTextTemplatesHaltTheMailbox() async throws {
    let textIDs = Set(BundledTemplates.load(channel: .sms).templates.map(\.definition.id))
    #expect(textIDs.count == 8)
    let entries = TemplatesManifest.entries.map { e in
      textIDs.contains(e.id)
        ? e : TemplatesManifest.Entry(file: e.file, id: e.id, version: e.version, sha256: String(repeating: "0", count: 64))
    }
    let read: (String) -> Data? = { file in
      CoreResources.bundle.url(forResource: file, withExtension: nil, subdirectory: "templates").flatMap { try? Data(contentsOf: $0) }
    }
    let loaded = BundledTemplates.load(entries: entries, read: read)
    #expect(Set(loaded.templates.map(\.definition.id)) == textIDs)
    #expect(loaded.skipped.count == entries.count - textIDs.count)
    #expect(BundledTemplates.load(entries: entries, channel: .mail, read: read).templates.isEmpty)

    let rig = Rig(templates: loaded.templates)
    rig.gmail.add(SyntheticMail.dibCard(id: "m1", dateMs: Rig.t0 - 86_400_000))
    await rig.connectAndActivate()
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.haltedOn == .templatesUnavailable)
    #expect(await rig.state().haltedOn == .templatesUnavailable)
    #expect(await rig.enqueued().isEmpty)
    #expect(rig.rawRequests.isEmpty)

    let mail = Rig(templates: BundledTemplates.load().templates)
    mail.gmail.add(SyntheticMail.dibCard(id: "m1", dateMs: Rig.t0 - 86_400_000))
    await mail.connectAndActivate()
    #expect(await mail.state().haltedOn == nil)
    #expect(await mail.enqueued().map(\.messageID) == ["m1"])
  }
}
