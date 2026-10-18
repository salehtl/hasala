import Foundation
import HasalaMocks
import HasalaModels
import HasalaWidgetData
import Testing

@Suite("Widgets · snapshot from the Maya ledger")
struct GlanceEngineTests {
  let s = MayaLedger.state
  let now = MayaLedger.now

  func snapshot(hidden: Bool = false, state: LedgerState? = nil) -> WidgetSnapshot {
    let st = state ?? s
    return GlanceEngine.snapshot(st, now: now, home: HomeEngine.snapshot(st, now: now), amountsHidden: hidden)
  }

  @Test func spentSoFarIsTheHero() throws {
    let w = try #require(snapshot().spentSoFar)
    #expect(w.spent == HomeEngine.snapshot(s, now: now).hero.spent)
    #expect(w.spent == .aed(Spending.total(s, in: MayaLedger.october)))
    #expect(MoneyFormat.string(w.spent.minor, style: .rounded) == "11,116")
    #expect(w.verdict == .onTrack)
    #expect(w.caption.rendered(hidden: false) == "On track · 7,884 left")
    #expect(w.caption.rendered(hidden: true) == "On track · ••• left")
    #expect(w.billWords == "1 bill due Wed")
    #expect(w.billNamed == "DEWA on Wed")
    #expect(MoneyFormat.short(w.spent.minor) == "11.1K")
  }

  @Test func theLaunchSetIsFilled() {
    let w = snapshot()
    #expect(w.budgetPace?.rows.count == 3)
    #expect(w.nextBill?.caption == "DEWA · expected Wed")
    #expect(w.netWorth != nil)
    #expect(w.projects.first?.name == "Japan trip")
    #expect(w.goals.first?.name == "Emergency fund")
    #expect(w.today?.rows.count == 2)
    #expect(!w.categories.isEmpty)
    #expect(w.lockScreenDetails == false)
    #expect(w.lockShowsAmounts == false)
  }

  @Test func diningIsWatchedOverPace() throws {
    let dining = try #require(snapshot().categories.first { $0.name == "Dining" })
    #expect(MoneyFormat.string(dining.left.minor, style: .rounded) == "957")
    #expect(dining.verdict == .overPace)
    #expect(dining.caption.rendered(hidden: false) == "Dining · 43 a day fits")
    #expect(dining.tick == Permille(320))
    #expect(snapshot().category(nil)?.verdict != .onTrack)
  }

  @Test func comingUpIsBillsAndSalary() throws {
    let c = try #require(snapshot().comingUp)
    #expect(c.title == "Coming up · 14 days")
    #expect(MoneyFormat.string(c.total.minor, style: .rounded) == "1,039")
    #expect(c.rows.map(\.name) == ["DEWA", "AXA Insurance", "Salary"])
    #expect(c.rows.map(\.note) == ["Wed · in 4 days", "3 days past usual", "Wed 28 Oct"])
    #expect(c.rows.map(\.late) == [false, true, false])
    #expect(c.rows.last?.isIncome == true)
  }

  @Test func toReviewCountsTheDeck() throws {
    let r = try #require(snapshot().toReview)
    #expect(r.count == 6)
    #expect(r.caption.rendered(hidden: false) == "827 not counted yet")
    #expect(ToReviewWidget(count: 0, notCounted: .aed(0)).caption.rendered(hidden: false) == "Nothing to sort")
  }

  @Test func hiddenAndLockDetailsFollowTheApp() {
    var st = s
    st.prefs.notificationDetail = true
    #expect(snapshot(state: st).lockShowsAmounts)
    #expect(!snapshot(hidden: true, state: st).lockShowsAmounts)
    #expect(snapshot(hidden: true).amountsHidden)
  }

  @Test func anEmptyLedgerWaits() {
    var st = s
    st.txns = []
    let w = snapshot(state: st)
    #expect(w.spentSoFar == nil)
    #expect(w.budgetPace == nil)
    #expect(w.today == nil)
    #expect(w.toReview == nil)
    #expect(w.categories.isEmpty)
  }

  @Test func shortFigures() {
    #expect(MoneyFormat.short(48_900) == "489")
    #expect(MoneyFormat.short(100_000) == "1K")
    #expect(MoneyFormat.short(1_028_800) == "10.3K")
    #expect(MoneyFormat.short(22_756_800) == "228K")
    #expect(MoneyFormat.short(125_000_000) == "1.3M")
  }
}

@Suite("Widgets · snapshot store")
struct WidgetSnapshotStoreTests {
  func temporaryStore() -> WidgetSnapshotStore {
    WidgetSnapshotStore(directory: FileManager.default.temporaryDirectory
      .appendingPathComponent("hasala-widget-tests-\(UUID().uuidString)", isDirectory: true))
  }

  func sample() -> WidgetSnapshot {
    let s = MayaLedger.state
    let now = MayaLedger.now
    return GlanceEngine.snapshot(s, now: now, home: HomeEngine.snapshot(s, now: now), amountsHidden: false)
  }

  @Test func writesAndReadsTheSameSnapshot() throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    #expect(store.read() == nil)
    let snap = sample()
    try store.write(snap)
    #expect(store.read() == snap)
  }

  @Test func theEncodingIsStable() throws {
    let snap = sample()
    #expect(try WidgetSnapshotStore.encode(snap) == WidgetSnapshotStore.encode(snap))
  }

  @Test func clearRemovesTheFile() throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    try store.write(sample())
    store.clear()
    #expect(store.read() == nil)
    #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
  }

  @Test func anotherVersionOrGarbageReadsAsNothing() throws {
    var snap = sample()
    snap.version = WidgetSnapshot.currentVersion + 1
    #expect(WidgetSnapshotStore.decode(try WidgetSnapshotStore.encode(snap)) == nil)
    #expect(WidgetSnapshotStore.decode(Data("not json".utf8)) == nil)
  }

  @Test func theFileHoldsFilsNotFloats() throws {
    let text = String(decoding: try WidgetSnapshotStore.encode(sample()), as: UTF8.self)
    #expect(text.contains("\"minor\":"))
    #expect(!text.contains("e+"))
  }
}

@Suite("Widgets · links")
struct WidgetLinkTests {
  @Test(arguments: [
    WidgetLink.home, .plan, .category("dining"), .bills, .accounts, .review, .activity,
  ])
  func everyLinkRoundTrips(link: WidgetLink) {
    #expect(WidgetLink(url: link.url) == link)
    #expect(link.url.scheme == "hasala")
  }

  @Test func otherURLsAreNotWidgetLinks() throws {
    #expect(WidgetLink(url: try #require(URL(string: "https://hasala.app/i/ABC"))) == nil)
    #expect(WidgetLink(url: try #require(URL(string: "hasala://widget/nowhere"))) == nil)
    #expect(WidgetLink(url: try #require(URL(string: "hasala://widget/category"))) == nil)
  }
}
