import Foundation
import HasalaMocks
import HasalaModels
import HasalaWidgetData
import Testing
import UIKit

@testable import Hasala

@MainActor
@Suite("Widget snapshot publisher")
struct WidgetPublisherTests {
  final class Reloads {
    var count = 0
  }

  func temporaryStore() -> WidgetSnapshotStore {
    WidgetSnapshotStore(directory: FileManager.default.temporaryDirectory
      .appendingPathComponent("hasala-widgets-\(UUID().uuidString)", isDirectory: true))
  }

  func settle() async {
    for _ in 0..<50 { await Task.yield() }
  }

  @Test func writesTheSnapshotWhenItStarts() throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let reloads = Reloads()
    let app = AppModel(store: InMemoryLedger())
    let publisher = WidgetPublisher(app: app, store: store) { reloads.count += 1 }
    let read = try #require(store.read())
    #expect(read == publisher.snapshot)
    #expect(read.spentSoFar?.verdict == .onTrack)
    #expect(read.toReview?.count == 6)
    #expect(read.amountsHidden == false)
    #expect(reloads.count == 1)
    publisher.publish()
    #expect(reloads.count == 1)
  }

  @Test func theAppLockHidesTheWidgetAmounts() throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let app = AppModel(store: InMemoryLedger())
    _ = WidgetPublisher(app: app, store: store, reload: {}, locked: { app.store.state.prefs.faceIDLock })
    #expect(store.read()?.amountsHidden == true)
    let open = WidgetPublisher(app: app, store: nil, reload: {}, locked: { false })
    #expect(open.snapshot.amountsHidden == false)
  }

  @Test func followsHiddenAmountsAndLedgerEdits() async throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let reloads = Reloads()
    let app = AppModel(store: InMemoryLedger())
    let publisher = WidgetPublisher(app: app, store: store) { reloads.count += 1 }
    app.toggleAmountsHidden()
    await settle()
    #expect(store.read()?.amountsHidden == true)
    #expect(reloads.count == 2)
    app.perform(.categorize("lulu", "groceries", learnRule: false, project: nil))
    await settle()
    #expect(store.read()?.toReview?.count == 5)
    #expect(reloads.count == 3)
    publisher.stop()
    app.toggleAmountsHidden()
    await settle()
    #expect(store.read()?.amountsHidden == true)
    #expect(reloads.count == 3)
  }

  @Test func showsThisMonthWhateverPeriodHomeShows() async throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    var state = MayaHistory.state
    state.txns.append(Txn(id: "sep-shop", merchant: "Corner Shop", amount: .aed(12_50),
                          postedAt: LocalDateTime(2026, 9, 20, 18, 0), accountID: "dib"))
    let app = AppModel(store: InMemoryLedger(state: state))
    let reloads = Reloads()
    let publisher = WidgetPublisher(app: app, store: store) { reloads.count += 1 }
    let october = try #require(store.read()?.spentSoFar)
    #expect(october.spent == app.snapshot.hero.spent)
    #expect(october.spent == .aed(Spending.total(state, in: MayaLedger.october)))
    app.period = .month(YearMonth(2026, 9))
    await settle()
    #expect(app.snapshot.hero.spent == .aed(Spending.total(state, in: YearMonth(2026, 9))))
    #expect(app.reviewCount == 7)
    #expect(store.read()?.spentSoFar == october)
    #expect(store.read()?.toReview?.count == 7)
    #expect(publisher.snapshot == WidgetPublisher(app: AppModel(store: InMemoryLedger(state: state)), store: nil).snapshot)
    #expect(reloads.count == 1)
  }

  final class Day {
    var date = MayaLedger.now.date
    var refreshes = 0
  }

  @Test func republishesWhenTheDayChanges() async throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let ledger = InMemoryLedger()
    let app = AppModel(store: ledger)
    let day = Day()
    app.refreshWork = {
      day.refreshes += 1
      ledger.setNow(LocalDateTime(date: day.date, hour: 0, minute: 5))
    }
    let center = NotificationCenter()
    let publisher = WidgetPublisher(app: app, store: store, center: center, reload: {}, today: { day.date })
    #expect(store.read()?.asOf == MayaLedger.now.date)
    center.post(name: UIApplication.significantTimeChangeNotification, object: nil)
    await settle()
    #expect(day.refreshes == 0)
    day.date = LocalDate(2026, 10, 11)
    center.post(name: UIApplication.significantTimeChangeNotification, object: nil)
    await settle()
    #expect(day.refreshes == 1)
    #expect(store.read()?.asOf == LocalDate(2026, 10, 11))
    day.date = LocalDate(2026, 10, 12)
    center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    await settle()
    #expect(store.read()?.asOf == LocalDate(2026, 10, 12))
    publisher.stop()
  }

  @Test func aFailedWriteIsTriedAgain() async throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    try Data().write(to: store.directory)
    let reloads = Reloads()
    let center = NotificationCenter()
    let publisher = WidgetPublisher(app: AppModel(store: InMemoryLedger()), store: store, center: center) {
      reloads.count += 1
    }
    #expect(store.read() == nil && reloads.count == 0)
    try FileManager.default.removeItem(at: store.directory)
    center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
    await settle()
    #expect(store.read() == publisher.snapshot)
    #expect(reloads.count == 1)
    publisher.stop()
  }

  @Test func theFileIsProtectedAndNotBackedUp() throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    _ = WidgetPublisher(app: AppModel(store: InMemoryLedger()), store: store) {}
    let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
    let protection = attributes[.protectionKey] as? FileProtectionType
    #if targetEnvironment(simulator)
      #expect(protection == nil || protection == .completeUntilFirstUserAuthentication)
    #else
      #expect(protection == .completeUntilFirstUserAuthentication)
    #endif
    let values = try store.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)
  }

  @Test func clearRemovesTheSnapshot() throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let reloads = Reloads()
    _ = WidgetPublisher(app: AppModel(store: InMemoryLedger()), store: store) {}
    #expect(store.read() != nil)
    WidgetPublisher.clear(store: store) { reloads.count += 1 }
    #expect(store.read() == nil)
    #expect(reloads.count == 1)
  }

  @Test(
    "The App Group container is reachable in a signed build",
    .enabled(if: WidgetSnapshotStore.shared() != nil, "unsigned build: no App Group"))
  func theAppGroupContainerIsReachable() {
    #expect(WidgetSnapshotStore.shared() != nil)
  }

  @Test func withoutTheAppGroupNothingIsWrittenOrReloaded() {
    let reloads = Reloads()
    let publisher = WidgetPublisher(app: AppModel(store: InMemoryLedger()), store: nil) { reloads.count += 1 }
    publisher.publish()
    publisher.timeMoved()
    #expect(reloads.count == 0)
    #expect(publisher.snapshot.toReview?.count == 6)
    publisher.stop()
  }
}

@MainActor
@Suite("Widget links open their screen")
struct WidgetLinkRoutingTests {
  @Test func eachLinkOpensItsPlace() {
    let app = AppModel(store: InMemoryLedger())
    app.open(.category("dining"))
    #expect(app.router.sheet == .profile)
    #expect(app.router.profile == [.plan, .category("dining")])
    app.open(.category("no-such-category"))
    #expect(app.router.profile == [.plan])
    app.open(.plan)
    #expect(app.router.sheet == .profile && app.router.profile == [.plan])
    app.open(.bills)
    #expect(app.tab == .home)
    #expect(app.router.home == [.bills])
    app.open(.activity)
    #expect(app.tab == .activity)
    app.open(.review)
    #expect(app.tab == .review)
    #expect(app.cover == .review)
    app.open(.home)
    #expect(app.tab == .home)
    #expect(app.router.home.isEmpty)
    #expect(app.cover == nil)
  }

  @Test func theReviewLinkOpensTheWholeDeckInAnyPeriod() {
    let app = AppModel(store: InMemoryLedger())
    app.period = .month(YearMonth(2026, 9))
    #expect(app.reviewCount == 6)
    let widget = WidgetPublisher(app: app, store: nil).snapshot
    app.open(.review)
    #expect(app.period == .month(YearMonth(2026, 9)))
    #expect(app.reviewCount == widget.toReview?.count)
    #expect(app.reviewCount == 6)
    #expect(app.cover == .review)
  }
}
