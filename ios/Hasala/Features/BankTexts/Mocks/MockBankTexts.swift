#if HASALA_MOCKS
  import Foundation
  import HasalaModels
  import Observation

  @MainActor
  @Observable
  final class MockBankTexts: BankTextsConnecting {
    enum TestOutcome: Equatable {
      case received
      case nothing
    }

    @ObservationIgnored private let mailbox: MockMailbox?
    var linkOverride: MailboxLinkCopy?
    private(set) var isSetUp: Bool
    var lastRan: Date?
    var ignoredLast30Days: Int
    var lastTexts: [SupportedBank: Date] = [:]
    var test: BankTextsTest = .idle
    var testOutcome: TestOutcome = .received
    var testDelay: Duration = .seconds(2)
    var finishFails = false
    var readDelay: Duration = .milliseconds(150)
    var addDelay: Duration = .zero
    var nextMatch: BankTextMatch?
    var setAside: [BankTextsSetAside] = []
    var lockedNotice: Int?
    private(set) var refreshes = 0
    private(set) var added: [String] = []
    private(set) var replaced: [String] = []
    private(set) var finishCalls = 0
    private(set) var testsStarted = 0
    @ObservationIgnored private var testTask: Task<Void, Never>?
    @ObservationIgnored var now: () -> Date = { .now }

    init(
      setUp: Bool = false, mailbox: MockMailbox? = nil, link: MailboxLinkCopy? = nil, lastRan: Date? = nil,
      lastTexts: [SupportedBank: Date] = [:], ignored: Int = 0
    ) {
      isSetUp = setUp
      self.mailbox = mailbox
      linkOverride = link
      self.lastRan = lastRan
      self.lastTexts = lastTexts
      ignoredLast30Days = ignored
    }

    static let sampleText =
      "AED 64.00 spent on card ending 0000 at Sample Grocer on 19/10 18:30. Available balance AED 2,940.00."
    static let undatedText = "AED 64.00 refunded to card ending 0000 by Sample Grocer."
    static let unreadableText = "Your card ending 0000 was used. Call us for details."
    static let codeText = "Your one-time code is 000000. Do not share it with anyone."

    static func working(now: Date = .now, mailbox: MockMailbox? = nil) -> MockBankTexts {
      let lane = MockBankTexts(
        setUp: true, mailbox: mailbox, lastRan: now.addingTimeInterval(-4 * 60),
        lastTexts: [
          .dib: now.addingTimeInterval(-4 * 60),
          .enbd: now.addingTimeInterval(-2 * 3600),
        ])
      lane.setAside = [
        BankTextsSetAside(sender: "DIB", bank: .dib, counts: [.oneTimeCode: 8, .promotion: 2, .declined: 1])
      ]
      return lane
    }

    static func waiting(mailbox: MockMailbox? = nil) -> MockBankTexts {
      let lane = MockBankTexts(setUp: true, mailbox: mailbox)
      lane.test = .received(at: .now.addingTimeInterval(-3600))
      return lane
    }

    var link: MailboxLinkCopy {
      if let linkOverride { return linkOverride }
      guard let mailbox else { return .notLinked }
      return mailbox.mailboxes.contains { $0.state != .disconnected } ? .linked : .notLinked
    }

    var status: BankTextsStatus {
      guard usesTexts else { return .notSetUp }
      if let lastRan { return .working(lastRan: lastRan) }
      return .waitingForFirstText
    }

    var banks: [BankTextsBank] {
      SupportedBank.allCases.map { BankTextsBank(bank: $0, lastText: lastTexts[$0]) }
    }

    var lastTextAt: Date? { lastTexts.values.max() }

    var lastRanAt: Date? { lastRan }

    func finishSetUp() async throws(BankTextsFailure) {
      finishCalls += 1
      if finishFails { throw .failed("Hasala couldn't save this on your iPhone. Try again.") }
      isSetUp = true
    }

    func lockedNoticeShown() {
      lockedNotice = nil
    }

    func refresh() {
      refreshes += 1
    }

    func startTest() {
      testsStarted += 1
      testTask?.cancel()
      test = .waiting(since: now())
      let delay = testDelay
      let outcome = testOutcome
      testTask = Task { [weak self] in
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled, let self else { return }
        switch outcome {
        case .received: self.test = .received(at: self.now())
        case .nothing: self.test = .nothingYet
        }
      }
    }

    func read(_ text: String) async -> BankTextReading {
      try? await Task.sleep(for: readDelay)
      return Self.reading(text)
    }

    func match(_ text: String) async -> BankTextMatch? {
      Self.reading(text) == .notAPayment ? nil : nextMatch
    }

    func addToReview(_ text: String, replacing: BankTextMatch?) async throws(BankTextsFailure) {
      if addDelay > .zero { try? await Task.sleep(for: addDelay) }
      guard !readsEmail else { throw .failed(BankTexts.pasteRefused) }
      guard Self.reading(text) != .notAPayment else { throw .failed("This isn't a bank payment text.") }
      added.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
      if let replacing, replacing.kind == .unreadText { replaced.append(replacing.rowID) }
    }

    static let codeMarkers = [#"\bone[- ]time (pass)?code\b"#, #"\botp\b"#, #"\bverification code\b"#, #"\bdeclined\b"#]
    static let transactionClauses = [
      #"\bspent\b"#, #"\bdebited\b"#, #"\bcredited\b"#, #"\bhas been charged\b"#, #"\bpurchase of .+ was successful\b"#,
      #"\breceived\b"#, #"\breversed\b"#, #"\brefunded\b"#,
    ]

    static func reading(_ text: String) -> BankTextReading {
      let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
      let lower = t.lowercased()
      let marked = codeMarkers.contains { matches($0, lower) }
      let moved = transactionClauses.contains { matches($0, lower) }
      if t.isEmpty || lower.contains(BankTexts.testPhrase.lowercased()) || (marked && !moved) {
        return .notAPayment
      }
      guard let amount = firstMatch(#"AED\s?([0-9][0-9,]*\.[0-9]{2})"#, in: t),
        let minor = minorUnits(amount)
      else { return .unreadable }
      let incoming = ["credited", "received", "refunded"].contains { lower.contains($0) }
      return .read(BankTextPreview(
        amount: .aed(minor), direction: incoming ? .incoming : .out,
        merchant: firstMatch(#" at (.+?) on "#, in: t), date: date(in: t), bank: nil,
        cardEnding: firstMatch(#"ending ([0-9]{4})"#, in: t)))
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
      text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
      guard let regex = try? NSRegularExpression(pattern: pattern),
        let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
        let r = Range(m.range(at: 1), in: text)
      else { return nil }
      return String(text[r])
    }

    private static func minorUnits(_ amount: String) -> Int64? {
      let digits = amount.replacingOccurrences(of: ",", with: "").split(separator: ".")
      guard digits.count == 2, let whole = Int64(digits[0]), let fils = Int64(digits[1]) else { return nil }
      return whole * 100 + fils
    }

    private static func date(in text: String) -> Date? {
      guard let regex = try? NSRegularExpression(pattern: #"([0-9]{1,2})/([0-9]{1,2}) ([0-9]{2}):([0-9]{2})"#),
        let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
      else { return nil }
      let parts = (1...4).compactMap { i in Range(m.range(at: i), in: text).flatMap { Int(text[$0]) } }
      guard parts.count == 4 else { return nil }
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = BankTexts.clock
      return calendar.date(from: DateComponents(year: 2026, month: parts[1], day: parts[0], hour: parts[2], minute: parts[3]))
    }
  }
#endif
