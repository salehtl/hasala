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
    if let mailbox {
      var off: [MailboxSnapshot] = []
      for m in reading(mailbox) {
        do {
          try await mailbox.disconnect(m.id, removeTransactions: false)
          off.append(m)
        } catch {
          return .failed(partialFailure(disconnected: off, failed: m))
        }
      }
    }
    do {
      try await texts.finishSetUp()
    } catch {
      return .failed(error.message)
    }
    return .switched
  }

  static func partialFailure(disconnected: [MailboxSnapshot], failed: MailboxSnapshot) -> String {
    guard !disconnected.isEmpty else { return "Hasala couldn't disconnect \(failed.address). Nothing changed. Try again." }
    let done = disconnected.map(\.address).formatted(.list(type: .and))
    return "Hasala disconnected \(done), but couldn't disconnect \(failed.address). It still reads bank email until \(failed.address) disconnects. Try again to finish the switch."
  }
}
