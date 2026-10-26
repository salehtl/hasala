import CoreDomain
import CoreTemplate
import Testing

@testable import CoreMailbox

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
}
