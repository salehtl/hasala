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

struct BankTextsBank: Equatable, Identifiable, Sendable {
  var bank: SupportedBank
  var lastText: Date?

  var id: SupportedBank { bank }
  var readsAutomatically: Bool { BankTexts.readAutomatically.contains(bank) }
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

@MainActor
protocol BankTextsConnecting: AnyObject, Observable {
  var source: PaymentSource? { get }
  var status: BankTextsStatus { get }
  var banks: [BankTextsBank] { get }
  var test: BankTextsTest { get }
  var lastTextAt: Date? { get }
  func useTexts() async throws(BankTextsFailure)
  @discardableResult
  func useEmail() async throws(BankTextsFailure) -> Date?
  func startTest()
  func read(_ text: String) async -> BankTextReading
  func addToReview(_ text: String) async throws(BankTextsFailure)
}

extension BankTextsConnecting {
  var usesTexts: Bool { source == .texts }
}

enum BankTexts {
  static let readAutomatically: Set<SupportedBank> = [.dib]
  static let testPhrase = "Hasala test"
  static let shortcutsURL = URL(string: "shortcuts://")!
  static let messagesURL = URL(string: "sms:")!

  static let clock = TimeZone(secondsFromGMT: 4 * 3600)!

  static func ago(_ date: Date, now: Date) -> String {
    let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
    if minutes < 1 { return "just now" }
    if minutes < 60 { return "\(minutes) min ago" }
    if minutes < 48 * 60 { return "\(minutes / 60) h ago" }
    return "\(minutes / (24 * 60)) days ago"
  }

  static func day(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = clock
    f.dateFormat = "EEE d MMM"
    return f.string(from: date)
  }

  static func dayAndTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = clock
    f.dateFormat = "EEE d MMM, HH:mm"
    return f.string(from: date)
  }

  static func time(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = clock
    f.dateFormat = "HH:mm"
    return f.string(from: date)
  }

  static func statusLine(_ status: BankTextsStatus, now: Date) -> String {
    switch status {
    case .notSetUp: "Not set up on this iPhone"
    case .waitingForFirstText: "Waiting for your first bank text"
    case .working(let lastRan): "Ran \(ago(lastRan, now: now))"
    }
  }

  static func bankDetail(_ bank: BankTextsBank, now: Date) -> String {
    let when = bank.lastText.map { "Last text \(ago($0, now: now))" } ?? "No text yet"
    return bank.readsAutomatically ? "\(when)\nRead automatically" : "\(when)\nYou check each one in Review"
  }

  static func switchToEmailMessage(cutoff: Date?) -> String {
    let stop = "Hasala stops reading bank texts; delete the automation in the Shortcuts app too."
    guard let cutoff else { return stop }
    return stop + " Email adds only payments after your last bank text (\(day(cutoff))), so nothing counts twice."
  }

  static let switchToTextsMessage =
    "Hasala disconnects your mailbox. Texts count from now on; payments already added stay. Next, you make the automation in the Shortcuts app."

  static let oneSourceNote = "Hasala uses one source at a time, so no payment counts twice."

  static let keepsOnlyPayments =
    "Hasala looks at each text on this iPhone and keeps only your banks' payment texts. Every other text is dropped at once, never saved or sent anywhere."

  static let banksLine =
    "DIB texts are read automatically. Texts from your other banks come in to Review for you to check."

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
