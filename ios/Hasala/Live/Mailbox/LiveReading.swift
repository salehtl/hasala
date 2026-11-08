import CoreMailbox
import Foundation
import HasalaModels
import UIKit

enum LiveReading {
  struct Inputs: Sendable {
    var nowMs: Int64
    var known: Bool
    var sample: Bool
    var status: MailboxStatus?
    var provider: MailProviderKind
    var progress: MailboxProgress?
    var heldElsewhere: MailProviderKind?
    var textsChosen: Bool
    var textsLastRunMs: Int64?
    var textsTestMissed = false
    var trustedBanks: [SupportedBank]
    var newestMailRowMs: Int64?
    var txns: [Txn]
    var backgroundRefreshOff: Bool
    var movedAwayMs: Int64?
  }

  static func facts(_ i: Inputs) -> ReadingFacts {
    ReadingFacts(
      nowMs: i.nowMs, known: i.known, sample: i.sample, mail: i.status.map { mail($0, provider: i.provider, progress: i.progress) },
      heldElsewhere: i.heldElsewhere, texts: i.textsChosen ? ReadingFacts.Texts(lastRunMs: i.textsLastRunMs, testMissed: i.textsTestMissed) : nil,
      banks: i.status.map { banks($0.health, trusted: i.trustedBanks) } ?? [], newestMailRowMs: i.newestMailRowMs,
      earliestBankRow: earliestBankRow(i.txns), backgroundRefreshOff: i.backgroundRefreshOff,
      movedAwayMs: i.status?.phase == .otherDevice ? i.movedAwayMs : nil)
  }

  static func state(_ i: Inputs) -> ReadingState { ReadingState.derive(facts(i)) }

  static var backgroundRefreshOff: Bool { UIApplication.shared.backgroundRefreshStatus != .available }

  static func mail(_ s: MailboxStatus, provider: MailProviderKind, progress: MailboxProgress?) -> ReadingFacts.Mail {
    mail(phase: s.phase, halt: s.haltedOn, lastSuccessMs: s.lastSuccessAtMs, connectedMs: s.connectedAtMs,
         readFromMs: s.readFromMs, provider: provider, progress: progress)
  }

  static func mail(
    phase lane: MailboxPhase, halt code: MailboxHaltCode?, lastSuccessMs: Int64?, connectedMs: Int64?, readFromMs: Int64?,
    provider: MailProviderKind, progress: MailboxProgress?
  ) -> ReadingFacts.Mail {
    let phase = lanePhase(lane)
    var offline = false
    var paused = false
    if case .failed(let failure)? = progress?.stage {
      if failure == .offline { offline = true } else { paused = true }
    }
    return ReadingFacts.Mail(
      provider: provider, phase: phase, halt: lane == .halted ? halt(code) : nil, lastCheckedMs: lastSuccessMs,
      connectedMs: connectedMs, pastSkippedFromMs: readFromMs, importRead: progress?.done ?? 0,
      importTotal: progress?.total ?? 0, importOffline: offline, importPaused: paused,
      thisMonthRead: phase == .backfill || (progress?.thisMonthRead ?? false))
  }

  static func lanePhase(_ p: MailboxPhase) -> ReadingFacts.LanePhase {
    switch p {
    case .unlinked: .unlinked
    case .scanning: .scanning
    case .awaitingCards, .authoringBackfill: .backfill
    case .active: .active
    case .otherDevice: .otherDevice
    case .reconnectRequired: .reconnectRequired
    case .halted: .halted
    }
  }

  static func halt(_ code: MailboxHaltCode?) -> ReadingFacts.Halt? {
    switch code {
    case .reconnectRequired?, .notHolder?: .signIn
    case .noMailbox?: .noMailbox
    case .accountFull?: .accountFull
    case .templatesUnavailable?: .templates
    case .quota?: .quota
    case .gmail?: .provider
    case .stagingFull?, .offline?: .other
    case nil: nil
    }
  }

  static func banks(_ health: [BankHealthRow], trusted: [SupportedBank]) -> [ReadingFacts.Bank] {
    trusted.map { bank in
      let domains = MailboxLane.senderDomains(bank: bank.rawValue)
      let last = health.filter { BankDomains.isMember($0.domain, of: domains) }.compactMap(\.lastEmailAtMs).max()
      return ReadingFacts.Bank(name: bank.name, lastMailMs: last)
    }
  }

  static func earliestBankRow(_ txns: [Txn]) -> LocalDate? {
    txns.lazy.filter { $0.provenance != nil }.map(\.postedAt.date).min()
  }

  static func movedAway(from old: MailboxPhase?, to new: MailboxPhase) -> Bool {
    guard new == .otherDevice, let old else { return false }
    switch old {
    case .scanning, .awaitingCards, .authoringBackfill, .active, .reconnectRequired, .halted: return true
    case .unlinked, .otherDevice: return false
    }
  }
}
