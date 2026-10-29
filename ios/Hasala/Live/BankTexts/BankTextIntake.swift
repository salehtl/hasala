import CoreMailbox
import CoreStore
import Foundation

nonisolated protocol BankTextAccount: AnyObject, Sendable {
  var author: any BankTextsAuthoring { get }
  func askLink() async -> Bool?
}

enum BankTextSignIn: Equatable, Sendable {
  case signedIn
  case signedOut
  case locked
}

enum BankTextIntakeResult: Equatable, Sendable {
  case testPassed
  case dropped(counted: Bool)
  case ignored(counted: Bool)
  case authored(filed: Bool)
  case failed(String, marked: Bool = false)
}

struct BankTextIntakeDeps {
  var reader: any BankTextsReading
  var facts: BankTextsFacts
  var marker: LockedTextsMarkerFile
  var secret: TextKeySecret
  var signIn: () -> BankTextSignIn
  var account: () async -> (any BankTextAccount)?
  var linkBudget: Duration = .seconds(6)
}

final class BankTextIntake {
  static let lockedMessage = "Hasala can't save bank texts until you unlock your iPhone. Paste this text later."
  static let signedOutMessage = "Sign in to Hasala to add bank texts."
  static let notOpenMessage = "Hasala couldn't add this text. Open Hasala, then paste the text from Messages."
  static let unavailableMessage = "This build of Hasala can't add bank texts yet. Paste the text into Hasala later."

  private let deps: BankTextIntakeDeps

  init(_ deps: BankTextIntakeDeps) {
    self.deps = deps
  }

  static func signIn(_ secrets: Secrets, installChecked: Bool = true) -> BankTextSignIn {
    do {
      guard try secrets.binding() != nil, let session = try secrets.session() else { return .signedOut }
      return session.pending_logout || !installChecked ? .signedOut : .signedIn
    } catch .notNow {
      return .locked
    } catch {
      return .signedOut
    }
  }

  static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }

  static func sender(_ raw: String?) -> String? {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  func run(_ text: String, sender rawSender: String?, at now: Date) async -> BankTextIntakeResult {
    let nowMs = Self.ms(now)
    let sender = Self.sender(rawSender)
    let signIn = deps.secret.beforeFirstUnlock() ? .locked : deps.signIn()
    if signIn == .locked {
      guard case .keep(let kept) = deps.reader.read(text, sender: sender, testWindowOpen: false) else {
        return .dropped(counted: false)
      }
      let marked = kept.mayBeBanks && deps.marker.add(arrivedAtMs: nowMs)
      return .failed(Self.lockedMessage, marked: marked)
    }
    guard signIn == .signedIn else {
      guard case .keep = deps.reader.read(text, sender: sender, testWindowOpen: false) else {
        return .dropped(counted: false)
      }
      return .failed(Self.signedOutMessage)
    }
    let facts = deps.facts.read(nowMs: nowMs)
    let reading = deps.reader.read(text, sender: sender, testWindowOpen: facts.testWindowOpen(nowMs: nowMs))
    switch reading {
    case .setUpTest:
      note(nowMs) {
        $0.testPassedMs = nowMs
        $0.testOpenedMs = nil
      }
      return .testPassed
    case .drop(let kind, let setAsideSender, let bank):
      note(nowMs) { data in
        if let setAsideSender { data.addSetAside(sender: setAsideSender, bank: bank, kind: kind, atMs: nowMs) }
      }
      return .dropped(counted: setAsideSender != nil)
    case .keep(let kept):
      return await keep(text, sender: sender, kept: kept, copy: facts.link, now: now)
    }
  }

  private func keep(
    _ text: String, sender: String?, kept: KeptBankText, copy: BankTextsFactsData.LinkCopy?, now: Date
  ) async -> BankTextIntakeResult {
    let nowMs = Self.ms(now)
    note(nowMs) { _ in }
    if copy?.linked == true { return ignore(kept, nowMs: nowMs) }
    guard let account = await deps.account() else { return .failed(Self.notOpenMessage) }
    var link: BankTextLinkState = copy == nil ? .unknownUnanswered : .notLinked
    if copy == nil, let answer = await Self.within(deps.linkBudget, { await account.askLink() }) {
      link = answer ? .linked : .notLinked
    }
    if link == .linked { return ignore(kept, nowMs: nowMs) }
    let secret: Data
    do { secret = try deps.secret.current() } catch { return .failed(Self.notOpenMessage) }
    let outcome: BankTextAuthored
    do {
      outcome = try await account.author.author(
        text, sender: sender, reading: kept, arrivedAt: now, secret: secret, link: link, origin: .automation)
    } catch .unavailable {
      return .failed(Self.unavailableMessage)
    } catch .notAPayment {
      return .dropped(counted: false)
    } catch {
      return .failed(Self.notOpenMessage)
    }
    switch outcome {
    case .authored(_, let filed, let bank, let keptAt):
      let key = bank ?? ""
      note(nowMs) { $0.lastKeptMs[key] = max($0.lastKeptMs[key] ?? 0, Self.ms(keptAt)) }
      return .authored(filed: filed)
    case .ignoredLinked(let counts):
      if counts { note(nowMs) { $0.addIgnored(atMs: nowMs) } }
      return .ignored(counted: counts)
    }
  }

  private func ignore(_ kept: KeptBankText, nowMs: Int64) -> BankTextIntakeResult {
    if kept.mayBeBanks { note(nowMs) { $0.addIgnored(atMs: nowMs) } }
    return .ignored(counted: kept.mayBeBanks)
  }

  private func note(_ nowMs: Int64, _ change: (inout BankTextsFactsData) -> Void) {
    _ = try? deps.facts.update(nowMs: nowMs) { data in
      data.lastRunMs = nowMs
      change(&data)
    }
  }

  static func within<T: Sendable>(_ budget: Duration, _ work: @escaping @Sendable () async -> T?) async -> T? {
    await withTaskGroup(of: T?.self) { group in
      group.addTask { await work() }
      group.addTask {
        try? await Task.sleep(for: budget)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }
}

enum BankTextsLinkCopy {
  static func linked(_ status: MailboxLinkStatus) -> Bool {
    switch status {
    case .noLink: false
    case .holder: true
    }
  }

  static func note(_ status: MailboxLinkStatus, facts: BankTextsFacts = .shared, nowMs: Int64) {
    note(linked: linked(status), facts: facts, nowMs: nowMs)
  }

  static func note(linked: Bool, facts: BankTextsFacts = .shared, nowMs: Int64) {
    _ = try? facts.update(nowMs: nowMs) { $0.link = BankTextsFactsData.LinkCopy(linked: linked, learnedAtMs: nowMs) }
  }

  static func disconnected(facts: BankTextsFacts = .shared, nowMs: Int64) {
    _ = try? facts.update(nowMs: nowMs) { data in
      data.link = BankTextsFactsData.LinkCopy(linked: false, learnedAtMs: nowMs)
      if data.sawAutomationRun(nowMs: nowMs) { data.chosen = true }
    }
  }

  static func copy(_ facts: BankTextsFactsData) -> MailboxLinkCopy {
    switch facts.link?.linked {
    case true?: .linked
    case false?: .notLinked
    case nil: .unknown
    }
  }
}

struct BankTextsLinkKeeper {
  let facts: BankTextsFacts
  let nowMs: () -> Int64

  init(facts: BankTextsFacts = .shared, nowMs: @escaping () -> Int64) {
    self.facts = facts
    self.nowMs = nowMs
  }

  nonisolated static func holdsLink(_ phase: MailboxPhase) -> Bool {
    switch phase {
    case .scanning, .awaitingCards, .authoringBackfill, .active, .halted: true
    case .unlinked, .reconnectRequired, .otherDevice: false
    }
  }

  nonisolated static func asksServer(_ phase: MailboxPhase?) -> Bool {
    switch phase {
    case .unlinked?, .otherDevice?, .reconnectRequired?: true
    case nil, .scanning?, .awaitingCards?, .authoringBackfill?, .active?, .halted?: false
    }
  }

  func ask<Provider>(_ server: () async throws -> (MailboxLinkStatus, Provider?)) async
    -> (MailboxLinkStatus, Provider?)?
  {
    guard let answer = try? await server() else { return nil }
    BankTextsLinkCopy.note(answer.0, facts: facts, nowMs: nowMs())
    return answer
  }

  func ownLink(_ phase: MailboxPhase?) {
    guard let phase, Self.holdsLink(phase) else { return }
    let now = nowMs()
    guard facts.read(nowMs: now).link?.linked != true else { return }
    BankTextsLinkCopy.note(linked: true, facts: facts, nowMs: now)
  }

  func afterRun(_ phase: MailboxPhase?, ask: () async -> Void) async {
    ownLink(phase)
    if Self.asksServer(phase) { await ask() }
  }

  func connected() {
    BankTextsLinkCopy.note(linked: true, facts: facts, nowMs: nowMs())
  }

  func disconnected(_ outcome: MailboxDisconnectOutcome) {
    guard Self.unlinked(outcome) else { return }
    BankTextsLinkCopy.disconnected(facts: facts, nowMs: nowMs())
  }

  nonisolated static func unlinked(_ outcome: MailboxDisconnectOutcome) -> Bool {
    switch outcome {
    case .disconnected, .removed, .disconnectedRemoveFailed: true
    case .otherDevice, .failed: false
    }
  }
}
