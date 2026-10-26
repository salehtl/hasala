import Foundation
import HasalaModels

@MainActor
enum SourceSwitch {
  enum Outcome: Equatable {
    case switched
    case failed(String)
  }

  static func toTexts(mailbox: (any MailboxConnecting)?, texts: any BankTextsConnecting) async -> Outcome {
    let reading = mailbox?.mailboxes.filter { $0.state != .disconnected } ?? []
    if let mailbox {
      for m in reading {
        do {
          try await mailbox.disconnect(m.id, removeTransactions: false)
        } catch {
          return .failed(error.message(for: m.provider) ?? "Hasala couldn't disconnect \(m.address). Try again.")
        }
      }
    }
    do {
      try await texts.useTexts()
    } catch {
      return .failed(error.message)
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
