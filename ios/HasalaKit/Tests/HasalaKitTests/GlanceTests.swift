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
    #expect(w.billNamed == "Wed · DEWA")
    #expect(MoneyFormat.short(w.spent.minor) == "11.1K")
  }

  @Test func theLaunchSetIsFilled() {
    let w = snapshot()
    #expect(w.budgetPace?.rows.count == 3)
    #expect(w.nextBill?.caption == "Expected Wed · DEWA")
    #expect(w.netWorth != nil)
    #expect(w.projects.first?.name == "Japan trip")
    #expect(w.goals.first?.name == "Emergency fund")
    #expect(w.today?.rows.count == 3)
    #expect(!w.categories.isEmpty)
    #expect(w.lockScreenDetails == false)
    #expect(w.lockShowsAmounts == false)
  }

  @Test func projectsAndGoalsAreChosenByID() throws {
    var w = snapshot()
    let p = try #require(w.projects.first)
    let g = try #require(w.goals.first)
    #expect(p.id != nil && g.id != nil)
    #expect(w.project(p.id) == p)
    #expect(w.goal(g.id) == g)
    #expect(w.project(nil) == p)
    #expect(w.goal(nil) == g)
    #expect(w.project(p.name) == nil)
    #expect(w.goal(g.name) == nil)
    #expect(w.project("gone") == nil)
    #expect(w.goal("gone") == nil)
    var twin = p
    twin.id = "twin"
    w.projects.append(twin)
    #expect(w.project("twin")?.id == "twin")
    #expect(w.project(p.id)?.id == p.id)
  }

  @Test func aChosenCategoryThatLeftTheListIsNotReplacedByAnother() throws {
    var state = s
    let dining = try #require(snapshot().categories.first { $0.name == "Dining" })
    #expect(snapshot().category(dining.id) == dining)
    let key = PlanState.key(dining.id, MayaLedger.october)
    state.plan.budgets[key] = .aed(0)
    let zeroed = snapshot(state: state)
    #expect(!zeroed.categories.isEmpty)
    #expect(zeroed.category(dining.id) == nil)
    #expect(zeroed.category("gone") == nil)
    #expect(zeroed.category(nil) != nil)
    state.plan.budgets[key] = .aed(1_000_00)
    #expect(snapshot(state: state).category(dining.id)?.id == dining.id)
  }

  @Test func aChosenTargetThatLeftTheListStaysChosen() {
    struct Pick: Equatable {
      let id: String
      let name: String
    }
    let known = [Pick(id: "dining", name: "Dining"), Pick(id: "rent", name: "Rent")]
    let picks = WidgetSnapshot.chosen(["rent", "gone"], known: known, id: \.id) { Pick(id: $0, name: "Removed") }
    #expect(picks == [Pick(id: "rent", name: "Rent"), Pick(id: "gone", name: "Removed")])
    #expect(WidgetSnapshot.chosen(["gone"], known: [Pick](), id: \.id) { Pick(id: $0, name: "Removed") }.map(\.id) == ["gone"])
    #expect(WidgetSnapshot.chosen([], known: known, id: \.id) { Pick(id: $0, name: "Removed") }.isEmpty)
  }

  @Test func diningIsWatchedOnTrack() throws {
    let dining = try #require(snapshot().categories.first { $0.name == "Dining" })
    #expect(MoneyFormat.string(dining.left.minor, style: .rounded) == "957")
    #expect(dining.verdict == .onTrack)
    #expect(dining.caption.rendered(hidden: false) == "Dining · 43 a day")
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
    #expect(r.caption.rendered(hidden: false) == "827 to sort")
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

  @Test func noFileAndAFileThatCannotBeUsedAreDifferent() throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    #expect(store.load() == .absent)
    let snap = sample()
    try store.write(snap)
    #expect(store.load() == .usable(snap))
    var older = snap
    older.version = WidgetSnapshot.currentVersion - 1
    try store.write(try WidgetSnapshotStore.encode(older))
    #expect(store.load() == .unusable)
    #expect(store.read() == nil)
    try store.write(Data("not json".utf8))
    #expect(store.load() == .unusable)
    store.clear()
    #expect(store.load() == .absent)
  }

  @Test func aFileTheSystemWillNotOpenCannotBeUsed() throws {
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    try store.write(sample())
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: store.fileURL.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path) }
    #expect(store.load() == .unusable)
    #expect(store.read() == nil)
  }

  @Test func aVersionTwoSnapshotReadsAsNothing() throws {
    var snap = sample()
    snap.version = 2
    #expect(WidgetSnapshotStore.decode(try WidgetSnapshotStore.encode(snap)) == nil)
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
