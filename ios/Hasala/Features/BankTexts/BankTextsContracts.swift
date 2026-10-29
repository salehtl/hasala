import Foundation
import HasalaModels

enum PaymentSource: String, Equatable, Sendable {
  case email
  case texts
}

enum BankTextsStatus: Equatable, Sendable {
  case notSetUp
  case waitingForFirstText
  case working(lastRan: Date)
}

struct BankTextsSetAside: Equatable, Identifiable, Sendable {
  var sender: String
  var bank: SupportedBank?
  var counts: [BankTextDropKind: Int]

  var id: String { sender }
  var total: Int { counts.values.reduce(0, +) }
  var name: String { bank?.shortName ?? sender }
}

enum BankTextsTest: Equatable, Sendable {
  case idle
  case waiting(since: Date)
  case received(at: Date)
  case nothingYet

  var isWaiting: Bool {
    if case .waiting = self { return true }
    return false
  }
}

struct BankTextPreview: Equatable, Sendable {
  enum Direction: Equatable, Sendable {
    case out
    case incoming
  }

  var amount: Money
  var direction: Direction
  var merchant: String?
  var date: Date?
  var bank: SupportedBank?
  var cardEnding: String?
}

enum BankTextReading: Equatable, Sendable {
  case read(BankTextPreview)
  case unreadable
  case notAPayment
}

enum BankTextsFailure: Error, Equatable, Sendable {
  case failed(String)

  var message: String {
    switch self {
    case .failed(let line): line
    }
  }
}

enum MailboxLinkCopy: Equatable, Sendable {
  case linked
  case notLinked
  case unknown
}

struct BankTextMatch: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case payment
    case unreadText
  }

  var rowID: String
  var kind: Kind
  var merchant: String?
  var amount: Money?
  var postedAt: Date
  var fromText: Bool
}

@MainActor
protocol BankTextsConnecting: AnyObject, Observable {
  var link: MailboxLinkCopy { get }
  var isSetUp: Bool { get }
  var status: BankTextsStatus { get }
  var test: BankTextsTest { get }
  var lastTextAt: Date? { get }
  var lastRanAt: Date? { get }
  var ignoredLast30Days: Int { get }
  func finishSetUp() async throws(BankTextsFailure)
  func startTest()
  func read(_ text: String) async -> BankTextReading
  func match(_ text: String) async -> BankTextMatch?
  func addToReview(_ text: String, replacing: BankTextMatch?) async throws(BankTextsFailure)
  var setAside: [BankTextsSetAside] { get }
  var lockedNotice: Int? { get }
  func lockedNoticeShown()
  func refresh()
}

extension BankTextsConnecting {
  var source: PaymentSource? {
    switch link {
    case .linked: .email
    case .notLinked, .unknown: isSetUp ? .texts : nil
    }
  }

  var usesTexts: Bool { source == .texts }
  var readsEmail: Bool { link == .linked }
  var offersPaste: Bool { link != .linked }
  var sawAutomationRun: Bool { lastRanAt != nil || ignoredLast30Days > 0 }
}

enum BankTexts {
  static let testPhrase = "Hasala test."
  static let shortcutsURL = URL(string: "shortcuts://")!
  static let messagesURL = URL(string: "sms:")!

  static let clock = LiveMailboxConnecting.localTimeZone

  private static func formatter(_ format: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = clock
    f.dateFormat = format
    return f
  }

  private static let dayAndTimeFormat = formatter("EEE d MMM, HH:mm")
  private static let timeFormat = formatter("HH:mm")

  static func dayAndTime(_ date: Date) -> String { dayAndTimeFormat.string(from: date) }

  static func time(_ date: Date) -> String { timeFormat.string(from: date) }

  static func setUpHere(_ lane: (any BankTextsConnecting)?) -> Bool { lane?.isSetUp == true }

  static func statusLine(_ status: BankTextsStatus, now: Date) -> String {
    switch status {
    case .notSetUp: "Not set up on this iPhone"
    case .waitingForFirstText: "Waiting for your first bank text"
    case .working(let lastRan): "Ran \(RelativeTime.ago(lastRan, now: now))"
    }
  }

  static let switchToEmailMessage =
    "Next, you connect Gmail or Outlook. Once it connects, Hasala stops adding bank texts; delete the automation in the Shortcuts app too. Email brings in all the bank mail it finds. A mail that may be the same payment as a bank text waits in Review beside it, where you keep both or archive one."

  static let readsEmailNow =
    "This account reads bank email, so Hasala adds no bank texts. Delete the automation in the Shortcuts app."

  static let pasteRefused =
    "This account reads bank email. Switch to bank texts in Profile \u{203A} Bank alerts to paste a text."

  static func switchToTextsMessage(disconnects: Bool) -> String {
    let rest = "Texts count from now on; payments already added stay. Next, you make the automation in the Shortcuts app."
    return disconnects ? "Hasala disconnects your mailbox. \(rest)" : rest
  }

  static let setupReadsEmail =
    "This account already reads bank email, so Hasala doesn't offer bank texts here. To use texts instead, switch in Profile \u{203A} Bank alerts."

  static let setupReadsEmailElsewhere =
    "This account already reads bank email, so Hasala doesn't offer bank texts here. To use texts instead, switch in Profile \u{203A} Bank alerts on the iPhone that reads your bank email."

  static func ignoredLine(_ count: Int) -> String? {
    guard count > 0 else { return nil }
    let texts =
      count == 1 ? "1 text that looks like a payment was" : "\(MoneyFormat.count(count)) texts that look like payments were"
    return "\(texts) ignored in the last 30 days because this account reads bank email."
  }

  static let automationStillThere =
    "Your Shortcuts automation is still there. Hasala will add bank texts from now on."

  static func disconnectNote(
    _ lane: (any BankTextsConnecting)?, mailbox: (any MailboxConnecting)?, disconnecting id: String
  ) -> String? {
    guard let lane, lane.sawAutomationRun else { return nil }
    let others = SourceSwitch.reading(mailbox).filter { $0.id != id }
    return others.isEmpty ? automationStillThere : nil
  }

  static func pasteDetail(usesTexts: Bool) -> String {
    usesTexts ? "For texts from before you set up the automation" : "It waits in Review for you to check"
  }

  static func pasteIntro(usesTexts: Bool) -> String {
    let how = "Copy it in Messages, then paste it here. Hasala reads it on this iPhone."
    return usesTexts ? "For a text from before your automation. \(how)" : "For a payment text from your bank. \(how)"
  }

  static let keepsNoText =
    "Hasala keeps only the details it needs from a text that looks like a payment, never the text itself. They sync only end\u{2011}to\u{2011}end encrypted; the text never leaves this iPhone."

  static let oneSourceNote =
    "Hasala reads one source at a time. After a switch, a payment that may have come in both ways waits in Review."

  static let keepsPaymentShapedTexts =
    "Hasala keeps the payment details of texts that look like payments, from any sender. Every other text is dropped at once, never saved or sent anywhere."

  static let keepsPayments = "Hasala looks at each text on this iPhone. " + keepsPaymentShapedTexts

  static let anyBankLine =
    "Hasala reads payment texts from any bank. It files the ones it reads with confidence, and the rest wait in Review for you to check."

  static func lockedNoticeLine(_ n: Int) -> String {
    n == 1
      ? "1 text that looks like a payment arrived while your iPhone was locked after a restart. Paste it from Messages."
      : "\(MoneyFormat.count(n)) texts that look like payments arrived while your iPhone was locked after a restart. Paste them from Messages."
  }

  static func kindName(_ kind: BankTextDropKind, count n: Int) -> String {
    let one = n == 1
    return switch kind {
    case .oneTimeCode: one ? "1 one-time code" : "\(MoneyFormat.count(n)) one-time codes"
    case .declined: one ? "1 declined payment" : "\(MoneyFormat.count(n)) declined payments"
    case .notice: one ? "1 notice" : "\(MoneyFormat.count(n)) notices"
    case .promotion: one ? "1 promotion" : "\(MoneyFormat.count(n)) promotions"
    case .noPaymentShape: one ? "1 other text" : "\(MoneyFormat.count(n)) other texts"
    }
  }

  static func setAsideDetail(_ s: BankTextsSetAside) -> String {
    let head =
      s.total == 1
      ? "1 text set aside in the last 30 days" : "\(MoneyFormat.count(s.total)) texts set aside in the last 30 days"
    let kinds = BankTextDropKind.allCases.compactMap { k in s.counts[k].flatMap { $0 > 0 ? kindName(k, count: $0) : nil } }
    return kinds.isEmpty ? head : "\(head)\n\(kinds.joined(separator: ", "))"
  }

  static func setAsideRows(_ rows: [BankTextsSetAside]) -> [BankTextsSetAside] {
    rows.filter { $0.total > 0 }
  }

  static let setAsideFootnote =
    "Texts from your banks that aren't payments. Hasala drops them at once and keeps only these counts, on this iPhone. If a payment is counted here, paste it."

  static let automationFootnote =
    "The automation lives in the Shortcuts app. Hasala can't see or change it; it only gets the texts it is handed."
}

extension MailboxesSummary {
  static func texts(_ status: BankTextsStatus, now: Date) -> MailboxesSummary {
    switch status {
    case .working:
      MailboxesSummary(
        title: "Bank texts are working", detail: BankTexts.statusLine(status, now: now), hue: .mint, needsYou: false)
    case .waitingForFirstText:
      MailboxesSummary(
        title: "Bank texts are ready", detail: BankTexts.statusLine(status, now: now), hue: .sky, needsYou: false)
    case .notSetUp:
      MailboxesSummary(
        title: "Bank texts aren't set up", detail: "Make the automation in the Shortcuts app.", hue: .sand,
        needsYou: true)
    }
  }
}
