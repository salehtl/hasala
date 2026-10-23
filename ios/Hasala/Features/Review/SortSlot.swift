import Foundation

enum SortSlot: Equatable {
  case ask
  case importing(MailImport)

  struct Facts: Equatable {
    var asks: Bool
    var status: CloudSortStatus?
    var importing: MailImport?

    init(asks: Bool = false, status: CloudSortStatus? = nil, importing: MailImport? = nil) {
      self.asks = asks
      self.status = status
      self.importing = importing
    }
  }

  static func of(_ f: Facts) -> SortSlot? {
    if f.asks, f.status.map({ $0.phase == .off }) ?? true { return .ask }
    guard let mail = f.importing, mail.showsInSlot else { return nil }
    return .importing(mail)
  }

  static func importingTitle(_ mail: MailImport) -> String {
    mail.read > 0 ? "Reading your mail · \(mail.read) so far" : "Reading your mail"
  }

  static func importingLine(_ mail: MailImport, queued: Bool = true) -> String {
    switch mail.state {
    case .offline: "Paused. No internet connection. It continues when you're back online."
    case .paused: "Paused for now. Hasala tries again soon."
    case .reading, .stopped:
      queued
        ? "You can start on the ones here now. More arrive as Hasala reads."
        : "Hasala is reading your bank alerts. Payments to sort show up here."
    }
  }

  static func importingSpoken(_ mail: MailImport, queued: Bool = true) -> String {
    let lead = mail.read > 0 ? "Reading your mail, \(mail.read) so far." : "Reading your mail."
    return "\(lead) \(importingLine(mail, queued: queued))"
  }
}

extension MailImport {
  var showsInSlot: Bool {
    if case .stopped = state { return false }
    return true
  }
}
