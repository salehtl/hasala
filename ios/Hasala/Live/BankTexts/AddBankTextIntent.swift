import AppIntents
import CoreMailbox
import Foundation

struct AddBankTextIntent: AppIntent {
  static let title: LocalizedStringResource = "Add bank text"
  static let description = IntentDescription(
    "Hands a text to Hasala on this iPhone. Hasala keeps only texts that look like bank payments and drops every other text at once, without saving it.")
  static let openAppWhenRun = false
  static let isDiscoverable = true

  @Parameter(title: "Text")
  var text: String

  @Parameter(title: "Sender")
  var sender: String?

  static var parameterSummary: some ParameterSummary {
    Summary("Add \(\.$text) to Hasala") {
      \.$sender
    }
  }

  func perform() async throws -> some IntentResult {
    if case .failed(let line, _) = await BankTextIntake.live().run(text, sender: sender, at: .now) {
      throw AddBankTextFailure(line: line)
    }
    return .result()
  }
}

struct AddBankTextFailure: Error, CustomLocalizedStringResourceConvertible {
  let line: String

  var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: line) }
}

struct HasalaShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: AddBankTextIntent(), phrases: ["Add a bank text to \(.applicationName)"], shortTitle: "Add bank text",
      systemImageName: "message")
  }
}

final class RuntimeBankTextAccount: BankTextAccount {
  private let runtime: AccountRuntime

  init(_ runtime: AccountRuntime) {
    self.runtime = runtime
  }

  var author: any BankTextsAuthoring { BankTextsWiring.author(runtime) }

  func askLink() async -> Bool? {
    guard let status = await runtime.askServerLink() else { return nil }
    return BankTextsLinkCopy.linked(status)
  }
}

enum BankTextsWiring {
  static let reader: any BankTextsReading = UnwiredBankTextsCore()

  static func author(_ runtime: AccountRuntime) -> any BankTextsAuthoring { UnwiredBankTextsCore() }
}

extension BankTextIntake {
  static func live() -> BankTextIntake {
    let boot = AppGraph.live()
    let secrets = boot.env.account.secrets
    return BankTextIntake(
      BankTextIntakeDeps(
        reader: BankTextsWiring.reader, facts: .shared, marker: .shared, secret: TextKeySecret(store: secrets.store),
        hasAccount: {
          guard (try? secrets.binding()) != nil, let session = try? secrets.session() else { return false }
          return !session.pending_logout
        },
        account: {
          boot.start()
          guard let rt = await boot.openedRuntime() else { return nil }
          return RuntimeBankTextAccount(rt)
        }))
  }
}
