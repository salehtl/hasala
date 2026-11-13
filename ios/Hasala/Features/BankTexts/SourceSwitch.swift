import Foundation
import HasalaModels

@MainActor
enum SourceSwitch {
  enum Outcome: Equatable {
    case switched
    case failed(String)
  }

  struct Attempt: Equatable {
    var outcome: Outcome
    var mailboxOff: Bool
  }

  static func reading(_ mailbox: (any MailboxConnecting)?) -> [MailboxSnapshot] {
    mailbox?.mailboxes.filter { $0.state != .disconnected } ?? []
  }

  static let checking = "Still checking your mailbox. Try again in a moment."

  static let readElsewhereLink =
    "Another iPhone reads this account's bank email. Disconnect the mailbox there, then switch here."

  static let linkRemains = "Your mailbox disconnected, but the switch didn't finish. Try again in a moment."

  static let switchUnfinished =
    "Hasala disconnected your mailbox, but couldn't finish the switch to bank texts. Try again."

  static func textsBlocker(_ mailbox: (any MailboxConnecting)?, texts: (any BankTextsConnecting)?) -> String? {
    if mailbox?.mailboxesKnown == false { return checking }
    let reading = reading(mailbox)
    if let elsewhere = reading.first(where: \.readElsewhere) {
      return "Your other iPhone reads \(elsewhere.address). Disconnect it there, or remove Hasala at \(MailCopy.consentPage(elsewhere.provider)), then switch here."
    }
    if !reading.isEmpty, mailbox?.capabilities.contains(.disconnect) != true {
      return "This iPhone can't disconnect your mailbox, so it can't switch."
    }
    if reading.isEmpty, texts?.readsEmail == true { return readElsewhereLink }
    return nil
  }

  static func toTexts(
    mailbox: (any MailboxConnecting)?, texts: any BankTextsConnecting, mailboxOff: Bool = false
  ) async -> Outcome {
    await attempt(mailbox: mailbox, texts: texts, mailboxOff: mailboxOff).outcome
  }

  static func attempt(
    mailbox: (any MailboxConnecting)?, texts: any BankTextsConnecting, mailboxOff: Bool = false
  ) async -> Attempt {
    if let blocker = textsBlocker(mailbox, texts: texts) { return Attempt(outcome: .failed(blocker), mailboxOff: mailboxOff) }
    var off: [MailboxSnapshot] = []
    if let mailbox {
      for m in reading(mailbox) {
        do {
          try await mailbox.disconnect(m.id, removeTransactions: false)
          off.append(m)
        } catch {
          return Attempt(outcome: .failed(partialFailure(disconnected: off, failed: m)), mailboxOff: mailboxOff || !off.isEmpty)
        }
      }
    }
    let wasOff = mailboxOff || !off.isEmpty
    texts.refresh()
    guard !texts.readsEmail else {
      return Attempt(outcome: .failed(off.isEmpty ? readElsewhereLink : linkRemains), mailboxOff: wasOff)
    }
    do {
      try await texts.finishSetUp()
    } catch {
      return Attempt(outcome: .failed(wasOff ? switchUnfinished : error.message), mailboxOff: wasOff)
    }
    return Attempt(outcome: texts.usesTexts ? .switched : .failed(linkRemains), mailboxOff: wasOff)
  }

  static func partialFailure(disconnected: [MailboxSnapshot], failed: MailboxSnapshot) -> String {
    guard !disconnected.isEmpty else { return "Couldn't disconnect \(failed.address). Nothing changed. Try again." }
    let done = disconnected.map(\.address).formatted(.list(type: .and))
    return "Disconnected \(done) but not \(failed.address). Try again to finish the switch."
  }
}
