import Foundation
import HasalaModels
import Observation

@MainActor
@Observable
final class LiveBankTexts: BankTextsConnecting {
  @ObservationIgnored private let facts: BankTextsFacts
  @ObservationIgnored private let marker: LockedTextsMarkerFile
  @ObservationIgnored private let reader: any BankTextsReading
  @ObservationIgnored private let author: () -> (any BankTextsAuthoring)?
  @ObservationIgnored private let secret: () -> TextKeySecret?
  @ObservationIgnored private let now: () -> Date
  @ObservationIgnored private var observer: NSObjectProtocol?
  @ObservationIgnored private var closing: Task<Void, Never>?
  @ObservationIgnored private var testStartedMs: Int64?

  private(set) var data: BankTextsFactsData
  private var testMissed = false
  private(set) var lockedNotice: Int?

  static let saveFailed = "Hasala couldn't save this on your iPhone. Try again."
  static let notAPayment = "This isn't a bank payment text."
  static let notOpen = "Hasala is still opening your account. Try again in a moment."
  static let unavailable = "This build of Hasala can't add bank texts yet."

  init(
    facts: BankTextsFacts, marker: LockedTextsMarkerFile, reader: any BankTextsReading,
    author: @escaping () -> (any BankTextsAuthoring)?, secret: @escaping () -> TextKeySecret?,
    now: @escaping () -> Date = { .now }
  ) {
    self.facts = facts
    self.marker = marker
    self.reader = reader
    self.author = author
    self.secret = secret
    self.now = now
    data = facts.read(nowMs: PastePreCheck.ms(now()))
    observer = NotificationCenter.default.addObserver(forName: BankTextsFacts.changed, object: nil, queue: .main) {
      [weak self] _ in
      MainActor.assumeIsolated { self?.reload() }
    }
  }

  convenience init(runtime: @escaping () -> AccountRuntime?) {
    self.init(
      facts: .shared, marker: .shared, reader: BankTextsWiring.reader,
      author: { runtime().map(BankTextsWiring.author) },
      secret: { runtime().map { TextKeySecret(store: $0.env.secrets.store) } })
  }

  private var nowMs: Int64 { PastePreCheck.ms(now()) }

  private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }

  func reload() {
    let next = facts.read(nowMs: nowMs)
    if let started = testStartedMs, next.testOpenedMs == nil {
      testStartedMs = nil
      if (next.testPassedMs ?? 0) < started { testMissed = true }
    }
    if next != data { data = next }
  }

  var link: MailboxLinkCopy { BankTextsLinkCopy.copy(data) }

  var isSetUp: Bool { data.chosen }

  var status: BankTextsStatus {
    guard usesTexts else { return .notSetUp }
    if let ran = data.lastRunMs { return .working(lastRan: Self.date(ran)) }
    return .waitingForFirstText
  }

  var banks: [BankTextsBank] {
    SupportedBank.allCases.map { bank in
      BankTextsBank(bank: bank, lastText: data.lastKeptMs[bank.rawValue].map(Self.date))
    }
  }

  var test: BankTextsTest {
    if let opened = data.testOpenedMs, data.testWindowOpen(nowMs: nowMs) { return .waiting(since: Self.date(opened)) }
    if testMissed { return .nothingYet }
    if let passed = data.testPassedMs { return .received(at: Self.date(passed)) }
    return .idle
  }

  var lastTextAt: Date? { data.lastKeptMs.values.max().map(Self.date) }

  var setAside: [BankTextsSetAside] {
    var bySender: [String: BankTextsSetAside] = [:]
    for entry in data.setAsideRecent(nowMs: nowMs) {
      var row = bySender[entry.sender] ?? BankTextsSetAside(
        sender: entry.sender, bank: SupportedBank(coreBank: entry.bank), counts: [:])
      if row.bank == nil { row.bank = SupportedBank(coreBank: entry.bank) }
      row.counts[entry.kind, default: 0] += entry.count
      bySender[entry.sender] = row
    }
    return bySender.values.sorted { ($0.total, $1.name) > ($1.total, $0.name) }
  }

  var ignoredLast30Days: Int { data.ignoredTotal(nowMs: nowMs) }

  var lastRanAt: Date? { data.lastRunMs.map(Self.date) }

  func finishSetUp() async throws(BankTextsFailure) {
    do {
      data = try facts.update(nowMs: nowMs) { $0.chosen = true }
    } catch {
      throw .failed(Self.saveFailed)
    }
  }

  func startTest() {
    let started = nowMs
    testMissed = false
    testStartedMs = started
    data = (try? facts.update(nowMs: started) { $0.testOpenedMs = started }) ?? data
    closing?.cancel()
    closing = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(BankTextsFactsData.testWindowMs + 500))
      guard !Task.isCancelled else { return }
      self?.reload()
    }
  }

  func read(_ text: String) async -> BankTextReading {
    switch reader.readPaste(text, pastedAt: now()) {
    case .setUpTest, .drop: .notAPayment
    case .keep(let kept): Self.reading(kept.fields)
    }
  }

  static func reading(_ f: BankTextFields) -> BankTextReading {
    guard let amount = f.amount else { return .unreadable }
    return .read(
      BankTextPreview(
        amount: amount, direction: f.direction == .in ? .incoming : .out, merchant: f.merchant, date: f.postedAt,
        bank: SupportedBank(coreBank: f.bank), cardEnding: f.cardEnding))
  }

  func match(_ text: String) async -> BankTextMatch? {
    let pastedAt = now()
    guard case .keep(let kept) = reader.readPaste(text, pastedAt: pastedAt), let author = author() else {
      return nil
    }
    let range = PastePreCheck.range(kept.fields, pastedAt: pastedAt)
    let rows = await author.liveRows(postedFrom: range.from, through: range.through)
    return PastePreCheck.match(kept.fields, pastedAt: pastedAt, rows: rows)
  }

  func addToReview(_ text: String, replacing: BankTextMatch?) async throws(BankTextsFailure) {
    guard link != .linked else { throw .failed(BankTexts.pasteRefused) }
    let pastedAt = Date(timeIntervalSince1970: TimeInterval(LockedTextsMarkerFile.minute(nowMs)) / 1000)
    guard case .keep(let kept) = reader.readPaste(text, pastedAt: pastedAt) else {
      throw .failed(Self.notAPayment)
    }
    guard let author = author(), let secret = secret() else { throw .failed(Self.notOpen) }
    let key: Data
    do { key = try secret.current() } catch { throw .failed(Self.saveFailed) }
    let replaced = replacing?.kind == .unreadText ? replacing?.rowID : nil
    let state: BankTextLinkState = link == .notLinked ? .notLinked : .unknownUnanswered
    do {
      _ = try await author.author(
        text, sender: nil, reading: kept, arrivedAt: pastedAt, secret: key, link: state,
        origin: .paste(replacing: replaced))
    } catch .unavailable {
      throw .failed(Self.unavailable)
    } catch .notAPayment {
      throw .failed(Self.notAPayment)
    } catch {
      throw .failed(Self.saveFailed)
    }
  }

  func refresh() {
    reload()
    guard let m = marker.read() else {
      lockedNotice = nil
      return
    }
    guard link == .linked else {
      lockedNotice = m.count
      return
    }
    _ = try? facts.update(nowMs: nowMs) { $0.addIgnored(m.count, atMs: m.latestMinuteMs) }
    marker.remove()
    lockedNotice = nil
    reload()
  }

  func lockedNoticeShown() {
    marker.remove()
    lockedNotice = nil
  }
}
