import CoreAuth
import CoreDomain
import CoreMailbox
import CoreReplay
import CoreSync
import CoreTime
import Foundation
import HasalaModels

/// The setup steps' ops (spec 04 §6.6 "When ops are authored") over the open account:
/// each call is one blob through `OpAuthor` under the account's shared stamps, one
/// `Outbox.enqueue`, then a re-projection; the outbox's trigger uploads it.
///
///   - bank:   `bank_declared` and `sender_trust_set` for each bank's alert senders
///   - "Another bank? Tell us": #74 with `source: "app"` (the name only)
///   - income and plan: `income_source_set`, `budget_split_set` and the seeded
///     `budget_set`s, in one blob
@MainActor
final class LiveSetupAuthoring: SetupAuthoring, SetupClock {
  private let runtime: @MainActor () -> AccountRuntime?

  init(runtime: @escaping @MainActor () -> AccountRuntime?) {
    self.runtime = runtime
  }

  private func open() throws(SetupFailure) -> AccountRuntime {
    guard let rt = runtime() else { throw .failed("Hasala is still opening your account. Try again in a moment.") }
    return rt
  }

  private static func token(_ rt: AccountRuntime) throws(SetupFailure) -> String {
    guard let token = try? rt.env.secrets.session()?.token else { throw .failed("You're signed out. Sign in again.") }
    return token
  }

  private static func domains(_ banks: [SupportedBank]) -> [String] {
    var out: [String] = []
    for bank in banks {
      for d in MailboxLane.senderDomains(bank: bank.rawValue) where !out.contains(d) { out.append(d) }
    }
    return out
  }

  /// The salary and the split the projection holds (plan B3.3), for setup to show again
  /// after a relaunch. Reads only; nothing is authored.
  func readBack() -> SetupReadBack {
    guard let r = runtime()?.projection.reader else { return SetupReadBack() }
    let sources = (try? r.incomeSources()) ?? []
    let salary = sources.first { $0.id == "salary" } ?? sources.first { $0.active }
    let split = (try? r.budgetTemplate()).flatMap { $0 }.map {
      StartingPlan(needsPercent: Int($0.need), wantsPercent: Int($0.want), savingsPercent: Int($0.saving))
    }
    return SetupReadBack(incomeMinor: salary?.amountMinor, payday: salary.map { Int($0.payday) }, split: split)
  }

  /// Today in the ledger's clock (the runtime's), for setup's payday line and the plan's
  /// month. Reads only; before the runtime opens, the device's clock in the same zone.
  func today() -> LocalDate {
    guard let ms = runtime()?.context.clock.nowMs(), let d = LocalClock.localDate(ms) else {
      return LedgerToday.device()
    }
    return LocalDate(d.year, d.month, d.day)
  }

  func chooseBanks(_ banks: [SupportedBank]) async throws(SetupFailure) {
    let rt = try open()
    var trusted = BankDomains.effectiveTrusted((try? rt.projection.reader.senderTrust()) ?? [:])
    let domains = Self.domains(banks)
    try await author(rt) { a throws(AuthorError) in
      for bank in banks { a.declareBank(bank.rawValue, active: true) }
      for d in domains where !trusted.contains(d) {
        try a.setSenderTrust(typed: d, trusted: true, currentTrusted: trusted)
        trusted.append(d)
      }
    }
  }

  func setBanks(_ banks: [SupportedBank]) async throws(SetupFailure) {
    let rt = try open()
    var trusted = BankDomains.effectiveTrusted((try? rt.projection.reader.senderTrust()) ?? [:])
    let before = trusted
    let kept = Self.domains(banks)
    var dropped: [String] = []
    for bank in SupportedBank.allCases where !banks.contains(bank) {
      for d in MailboxLane.senderDomains(bank: bank.rawValue) where !kept.contains(d) && !dropped.contains(d) {
        if trusted.contains(d) { dropped.append(d) }
      }
    }
    try await author(rt) { a throws(AuthorError) in
      for bank in SupportedBank.allCases { a.declareBank(bank.rawValue, active: banks.contains(bank)) }
      for d in kept where !trusted.contains(d) {
        try a.setSenderTrust(typed: d, trusted: true, currentTrusted: trusted)
        trusted.append(d)
      }
      for d in dropped {
        try a.setSenderTrust(typed: d, trusted: false, currentTrusted: trusted)
        trusted.removeAll { $0 == d }
      }
    }
    let added = Self.newlyTrusted(kept: kept, before: before)
    if !added.isEmpty { rt.lane?.backfill(senders: added) }
  }

  static func newlyTrusted(kept: [String], before: [String]) -> [String] {
    kept.filter { !before.contains($0) }
  }

  func requestBank(_ name: String) async throws(SetupFailure) {
    let rt = try open()
    let token = try Self.token(rt)
    do {
      try await rt.env.client.bankRequest(bank: "other", otherBank: name, bearer: token)
    } catch {
      if case .transport = error { throw .offline }
      throw .failed("Couldn't send that just now. Try again later.")
    }
  }

  func requestBank(slug: String, senderDomain: String?) async throws(SetupFailure) {
    let rt = try open()
    let token = try Self.token(rt)
    do {
      try await rt.env.client.bankRequest(bank: slug, senderDomain: senderDomain, bearer: token)
    } catch {
      if case .transport = error { throw .offline }
      throw .failed("Couldn't send that just now. Try again later.")
    }
  }

  func bankRequests() async throws(SetupFailure) -> BankRequestsSnapshot {
    let rt = try open()
    let token = try Self.token(rt)
    let list: BankRequestsList
    do {
      list = try await rt.env.client.bankRequests(bearer: token)
    } catch {
      if case .transport = error { throw .offline }
      throw .failed("Couldn't check your bank requests just now.")
    }
    return BankRequestsSnapshot(list)
  }

  func savePlan(income: Int64?, payday: Int?, plan: StartingPlan?) async throws(SetupFailure) {
    let rt = try open()
    let now = rt.context.clock.nowMs()
    guard let month = LocalClock.localMonth(now) else { throw .failed("The date is out of range.") }
    try await author(rt) { a throws(AuthorError) in
      if let income {
        a.setIncomeSource(id: "salary", name: "Salary", amountMinor: income, payday: Int64(payday ?? 28))
      }
      if let plan, plan.isValid {
        try a.setBudgetTemplate(
          need: Int64(plan.needsPercent), want: Int64(plan.wantsPercent), saving: Int64(plan.savingsPercent))
        if let income {
          a.seedPlan(
            income: income,
            split: BudgetSplit(
              need: Int64(plan.needsPercent), want: Int64(plan.wantsPercent), saving: Int64(plan.savingsPercent)),
            month: month)
        }
      }
    }
  }

  /// One blob: built, enqueued (durable), re-projected, and the screens reloaded.
  private func author(_ rt: AccountRuntime, _ body: (inout OpAuthor) throws(AuthorError) -> Void)
    async throws(SetupFailure)
  {
    do {
      let ctx = try await rt.observer.authorContext()
      guard let blob = try rt.observer.stamps.build(ctx, body) else { return }
      try await rt.outbox.enqueue(blob.ops)
      try await rt.observer.reproject()
    } catch {
      throw .failed("Couldn't save that. Try again.")
    }
    await rt.store.reload()
  }
}

extension BankRequestsSnapshot {
  init(_ list: BankRequestsList) {
    self.init(
      requests: list.requests.map { RequestedBank(bank: $0.bank, name: $0.name, state: RequestedBankState(wire: $0.state)) },
      catalog: list.catalog.map { BankCatalogChoice(slug: $0.bank, name: $0.name, state: RequestedBankState(wire: $0.state)) })
  }
}
