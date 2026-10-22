import Foundation
import Observation

@MainActor
protocol UnseenPhraseNoting: AnyObject {
  var unseen: Bool { get }
  func noteUnseen(at date: Date)
  func noteSeen()
  func remindIfAllowed() async
  func adopt(serverUnseenSince: Date?) async
}

@MainActor
@Observable
final class InMemoryUnseenPhrase: UnseenPhraseNoting {
  private(set) var unseen = false
  private(set) var since: Date?
  private(set) var reminders = 0

  nonisolated init() {}

  func noteUnseen(at date: Date) {
    unseen = true
    since = date
  }

  func noteSeen() {
    unseen = false
    since = nil
  }

  func remindIfAllowed() async {
    if unseen { reminders += 1 }
  }

  func adopt(serverUnseenSince: Date?) async {
    if let serverUnseenSince {
      if !unseen { noteUnseen(at: serverUnseenSince) }
    } else {
      noteSeen()
    }
  }
}
