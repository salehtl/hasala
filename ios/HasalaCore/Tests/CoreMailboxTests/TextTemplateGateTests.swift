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
}
