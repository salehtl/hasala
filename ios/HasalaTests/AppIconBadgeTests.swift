import Foundation
import HasalaMocks
import HasalaModels
import Testing
import UIKit

@testable import Hasala

@MainActor
@Suite("App icon badge")
struct AppIconBadgeTests {
  final class Sets {
    var counts: [Int] = []
    var succeeds = true
  }

  func settle() async {
    for _ in 0..<50 { await Task.yield() }
  }

  func make(_ sets: Sets, center: NotificationCenter = NotificationCenter()) -> (AppModel, AppIconBadge) {
    let app = AppModel(store: InMemoryLedger())
    let badge = AppIconBadge(app: app, center: center) { count in
      sets.counts.append(count)
      return sets.succeeds
    }
    return (app, badge)
  }

  @Test func showsTheReviewCountWhenItStarts() async {
    let sets = Sets()
    let (app, badge) = make(sets)
    await settle()
    #expect(sets.counts == [app.reviewCount])
    #expect(sets.counts == [6])
    badge.stop()
  }

  @Test func followsLedgerEdits() async {
    let sets = Sets()
    let (app, badge) = make(sets)
    await settle()
    app.perform(.categorize("lulu", "groceries", learnRule: false, project: nil))
    await settle()
    #expect(sets.counts == [6, 5])
    badge.stop()
  }

  @Test func anAwaitedPublishSetsTheCountAtOnce() async {
    let sets = Sets()
    let (app, badge) = make(sets)
    await badge.publish()
    app.perform(.categorize("lulu", "groceries", learnRule: false, project: nil))
    await badge.publish()
    #expect(sets.counts.last == 5)
    badge.stop()
  }

  @Test func anUnchangedCountIsNotSetAgain() async {
    let sets = Sets()
    let (_, badge) = make(sets)
    await settle()
    await badge.publish()
    await badge.publish()
    #expect(sets.counts == [6])
    badge.stop()
  }

  @Test func aFailedSetIsTriedAgain() async {
    let sets = Sets()
    sets.succeeds = false
    let (_, badge) = make(sets)
    await settle()
    sets.succeeds = true
    await badge.publish()
    await badge.publish()
    #expect(sets.counts == [6, 6])
    badge.stop()
  }

  @Test(arguments: [UIApplication.didBecomeActiveNotification, AppIconBadge.permissionAnswered])
  func aPermissionChangeSetsTheCountAgain(name: Notification.Name) async {
    let sets = Sets()
    let center = NotificationCenter()
    let (_, badge) = make(sets, center: center)
    await settle()
    center.post(name: name, object: nil)
    await settle()
    #expect(sets.counts == [6, 6])
    badge.stop()
  }

  @Test func setsNothingAfterItStops() async {
    let sets = Sets()
    let center = NotificationCenter()
    let (app, badge) = make(sets, center: center)
    await settle()
    badge.stop()
    app.perform(.categorize("lulu", "groceries", learnRule: false, project: nil))
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    await settle()
    await badge.publish()
    #expect(sets.counts == [6])
  }
}
