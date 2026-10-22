import Foundation
import Observation

@MainActor
protocol UnseenPhraseNoting: AnyObject {
  var unseen: Bool { get }
  func noteUnseen(at date: Date)
  func noteSeen()
  func remindIfAllowed() async
  func adopt(serverUnseenSince: Date?) async
  func flush() async
}

@MainActor
@Observable
final class InMemoryUnseenPhrase: UnseenPhraseNoting {
  private(set) var unseen = false
  private(set) var since: Date?
  private(set) var reminders = 0
  private(set) var reportPending = false
  private(set) var reports = 0
  @ObservationIgnored var report: (@MainActor () async -> Bool)?

  nonisolated init() {}

  func noteUnseen(at date: Date) {
    unseen = true
    since = date
    reportPending = false
  }

  func noteSeen() {
    if unseen { reportPending = true }
    unseen = false
    since = nil
  }

  func remindIfAllowed() async {
    if unseen { reminders += 1 }
  }

  func adopt(serverUnseenSince: Date?) async {
    if reportPending {
      await flush()
      return
    }
    if let serverUnseenSince {
      if !unseen { noteUnseen(at: serverUnseenSince) }
    } else {
      unseen = false
      since = nil
    }
  }

  func flush() async {
    guard reportPending, let report else { return }
    reports += 1
    if await report() { reportPending = false }
  }
}
