import Foundation
import HasalaModels

@MainActor
enum SourceSwitch {
  enum Outcome: Equatable {
    case switched
    case failed(String)
  }

  static func reading(_ mailbox: (any MailboxConnecting)?) -> [MailboxSnapshot] {
    mailbox?.mailboxes.filter { $0.state != .disconnected } ?? []
  }

  static func textsBlocker(_ mailbox: (any MailboxConnecting)?) -> String? {
    let reading = reading(mailbox)
    if let elsewhere = reading.first(where: \.readElsewhere) {
      return "Your other iPhone reads \(elsewhere.address) and holds its sign-in. Disconnect it there first, or remove Hasala at \(MailCopy.consentPage(elsewhere.provider)). Then switch to bank texts here."
    }
    if !reading.isEmpty, mailbox?.capabilities.contains(.disconnect) != true {
      return "Hasala can't disconnect your mailbox from this iPhone, so it can't switch to bank texts here."
    }
    return nil
  }

  static func toTexts(mailbox: (any MailboxConnecting)?, texts: any BankTextsConnecting) async -> Outcome {
    if let blocker = textsBlocker(mailbox) { return .failed(blocker) }
    let wasTexts = texts.usesTexts
    do {
      try await texts.useTexts()
    } catch {
      return .failed(error.message)
    }
    guard let mailbox else { return .switched }
    for m in reading(mailbox) {
      do {
        try await mailbox.disconnect(m.id, removeTransactions: false)
      } catch {
        if !wasTexts { try? await texts.useEmail() }
        return .failed(error.message(for: m.provider) ?? "Hasala couldn't disconnect \(m.address). Try again.")
      }
    }
    return .switched
  }

  static func toEmail(texts: any BankTextsConnecting) async -> Outcome {
    do {
      try await texts.useEmail()
    } catch {
      return .failed(error.message)
    }
    return .switched
  }
}
