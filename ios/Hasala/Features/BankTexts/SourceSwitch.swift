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

  static let checking = "Hasala is still checking your mailbox. Try again in a moment."

  static let readElsewhereLink =
    "This account still reads bank email on another iPhone. Disconnect the mailbox there first, then switch to bank texts here."

  static let linkRemains =
    "Hasala disconnected your mailbox, but this account still shows a mailbox link. Try again in a moment to finish the switch."

  static func textsBlocker(_ mailbox: (any MailboxConnecting)?, texts: (any BankTextsConnecting)?) -> String? {
    if mailbox?.mailboxesKnown == false { return checking }
    let reading = reading(mailbox)
    if let elsewhere = reading.first(where: \.readElsewhere) {
      return "Your other iPhone reads \(elsewhere.address) and holds its sign-in. Disconnect it there first, or remove Hasala at \(MailCopy.consentPage(elsewhere.provider)). Then switch to bank texts here."
    }
    if !reading.isEmpty, mailbox?.capabilities.contains(.disconnect) != true {
      return "Hasala can't disconnect your mailbox from this iPhone, so it can't switch to bank texts here."
    }
    if reading.isEmpty, texts?.readsEmail == true { return readElsewhereLink }
    return nil
  }

  static func toTexts(mailbox: (any MailboxConnecting)?, texts: any BankTextsConnecting) async -> Outcome {
    if let blocker = textsBlocker(mailbox, texts: texts) { return .failed(blocker) }
    var off: [MailboxSnapshot] = []
    if let mailbox {
      for m in reading(mailbox) {
        do {
          try await mailbox.disconnect(m.id, removeTransactions: false)
          off.append(m)
        } catch {
          return .failed(partialFailure(disconnected: off, failed: m))
        }
      }
    }
    guard !texts.readsEmail else { return .failed(off.isEmpty ? readElsewhereLink : linkRemains) }
    do {
      try await texts.finishSetUp()
    } catch {
      return .failed(error.message)
    }
    return texts.usesTexts ? .switched : .failed(linkRemains)
  }

  static func partialFailure(disconnected: [MailboxSnapshot], failed: MailboxSnapshot) -> String {
    guard !disconnected.isEmpty else { return "Hasala couldn't disconnect \(failed.address). Nothing changed. Try again." }
    let done = disconnected.map(\.address).formatted(.list(type: .and))
    return "Hasala disconnected \(done), but couldn't disconnect \(failed.address). It still reads bank email until \(failed.address) disconnects. Try again to finish the switch."
  }
}
