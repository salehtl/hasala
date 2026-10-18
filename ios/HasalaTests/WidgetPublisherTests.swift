import Foundation
import HasalaMocks
import HasalaModels
import HasalaWidgetData
import Testing

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
    #expect(app.reviewCount == 1)
    #expect(store.read()?.spentSoFar == october)
    #expect(store.read()?.toReview?.count == 6)
    #expect(publisher.snapshot == WidgetPublisher(app: AppModel(store: InMemoryLedger(state: state)), store: nil).snapshot)
    #expect(reloads.count == 1)
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

  @Test func theAppGroupContainerIsReachable() {
    #expect(WidgetSnapshotStore.shared() != nil)
  }
}

@MainActor
@Suite("Widget links open their screen")
struct WidgetLinkRoutingTests {
  @Test func eachLinkOpensItsPlace() {
    let app = AppModel(store: InMemoryLedger())
    app.open(.category("dining"))
    #expect(app.tab == .plan)
    #expect(app.router.plan == [.category("dining")])
    app.open(.category("no-such-category"))
    #expect(app.router.plan.isEmpty)
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
}
