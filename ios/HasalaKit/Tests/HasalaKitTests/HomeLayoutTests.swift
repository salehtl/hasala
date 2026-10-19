import Foundation
import HasalaMocks
import HasalaModels
import Testing

@Suite("Home layout")
struct HomeLayoutTests {
  let s = MayaLedger.state
  let now = MayaLedger.now

  func entry(_ kind: HomeWidgetKind, _ config: HomeWidgetConfig? = nil) -> HomeLayout.Entry {
    HomeLayout.Entry(kind, config: config)
  }

  @Test func theDefaultIsTodaysCanvas() {
    let layout = HomeEngine.defaultLayout(s, now: now)
    #expect(layout.ids == ["budgetPace", "nextBill", "netWorth", "project.japan", "goal.emergency", "today"])
    let canvas = HomeEngine.canvas(nil, s, now: now)
    #expect(canvas.map(\.id) == layout.ids)
    #expect(canvas.compactMap(\.widget) == HomeEngine.snapshot(s, now: now).widgets)
    #expect(HomeEngine.canvas(layout, s, now: now) == canvas)
  }

  @Test func theDefaultLeavesOutWhatHasNoData() {
    var empty = s
    empty.bills = []
    empty.accounts = []
    empty.projects = []
    empty.goals = []
    #expect(HomeEngine.defaultLayout(empty, now: now).ids == ["budgetPace", "today"])
  }

  @Test func addingAppendsOnceAndNeedsAConfigWhereOneIsAsked() {
    var layout = HomeLayout([entry(.budgetPace)])
    do { let ok = layout.add(entry(.toReview)); #expect(ok) }
    do { let ok = layout.add(entry(.toReview)); #expect(!ok) }
    do { let ok = layout.add(entry(.categoryWatch)); #expect(!ok) }
    do { let ok = layout.add(entry(.budgetPace, .category("dining"))); #expect(!ok) }
    do { let ok = layout.add(entry(.categoryWatch, .project("japan"))); #expect(!ok) }
    do { let ok = layout.add(entry(.categoryWatch, .category("dining"))); #expect(ok) }
    do { let ok = layout.add(entry(.categoryWatch, .category("groceries"))); #expect(ok) }
    do { let ok = layout.add(entry(.categoryWatch, .category("dining"))); #expect(!ok) }
    #expect(layout.ids == ["budgetPace", "toReview", "categoryWatch.dining", "categoryWatch.groceries"])
    #expect(layout.isOnHome(.toReview))
    #expect(!layout.isOnHome(.categoryWatch))
    #expect(!layout.isOnHome(.today))
  }

  @Test func removingTakesOnlyThatEntry() {
    var layout = HomeEngine.defaultLayout(s, now: now)
    do { let ok = layout.remove("netWorth"); #expect(ok) }
    do { let ok = layout.remove("netWorth"); #expect(!ok) }
    #expect(layout.ids == ["budgetPace", "nextBill", "project.japan", "goal.emergency", "today"])
    for id in layout.ids { layout.remove(id) }
    #expect(layout.isEmpty)
    #expect(HomeEngine.canvas(layout, s, now: now).isEmpty)
  }

  @Test func movingReordersAndStopsAtTheEnds() {
    var layout = HomeEngine.defaultLayout(s, now: now)
    do { let ok = layout.move("today", to: 0); #expect(ok) }
    #expect(layout.ids.first == "today")
    #expect(!layout.canMove("today", by: -1))
    do { let ok = layout.move("today", by: -1); #expect(!ok) }
    do { let ok = layout.move("today", by: 1); #expect(ok) }
    #expect(layout.ids.prefix(2) == ["budgetPace", "today"])
    do { let ok = layout.move("budgetPace", to: 99); #expect(ok) }
    #expect(layout.ids.last == "budgetPace")
    #expect(!layout.canMove("budgetPace", by: 1))
    do { let ok = layout.move("missing", by: 1); #expect(!ok) }
  }

  @Test func configuringChangesWhatAWidgetShows() throws {
    var layout = HomeLayout([entry(.categoryWatch, .category("dining")), entry(.categoryWatch, .category("groceries"))])
    do { let ok = layout.configure("categoryWatch.dining", .category("groceries")); #expect(!ok) }
    do { let ok = layout.configure("categoryWatch.dining", .goal("emergency")); #expect(!ok) }
    do { let ok = layout.configure("categoryWatch.dining", .category("transport")); #expect(ok) }
    #expect(layout.ids == ["categoryWatch.transport", "categoryWatch.groceries"])
    let canvas = HomeEngine.canvas(layout, s, now: now)
    guard case .categoryWatch(let w)? = canvas[0].widget else { Issue.record("no category watch"); return }
    #expect(w.name == "Transport")
  }

  @Test func everyKindInTheLaunchSetResolves() {
    let previews = HomeEngine.previews(s, now: now)
    #expect(HomeWidgetKind.allCases.count == 10)
    for kind in HomeWidgetKind.allCases {
      let item = previews[kind]
      #expect(item?.widget?.kind == kind, "\(kind) has no preview")
      #expect(item?.size == kind.size)
    }
    #expect(HomeEngine.options(.category, s, now: now).map(\.section).first == "Needs")
    #expect(HomeEngine.options(.project, s, now: now).map(\.config) == [.project("japan")])
    #expect(HomeEngine.options(.goal, s, now: now).map(\.config) == [.goal("emergency")])
  }

  func projectWidget(_ project: Project, spending: Int64? = nil) throws -> ProjectWidget {
    var ledger = s
    ledger.projects.append(project)
    if let spending {
      let i = try #require(ledger.txns.firstIndex { $0.direction == .out && !$0.needsReview && $0.projectID == nil })
      ledger.txns[i].amount = .aed(spending)
      ledger.txns[i].projectID = project.id
    }
    let layout = HomeLayout([entry(.project, .project(project.id))])
    let item = try #require(HomeEngine.canvas(layout, ledger, now: now).first)
    guard case .project(let widget)? = item.widget else {
      Issue.record("\(project.id) has no project widget")
      throw CancellationError()
    }
    return widget
  }

  @Test func aProjectWithinBudgetReadsLeft() throws {
    let w = try projectWidget(try #require(s.projects.first { $0.id == "japan" }))
    #expect(w.unit == .left)
    #expect(w.left == .aed(7_140_00))
    #expect(w.progress == Permille.ratio(4_860_00, of: 12_000_00))
    #expect(w.caption.rendered(hidden: false).hasPrefix("of 12,000"))
  }

  @Test func aProjectOverBudgetReadsOverWithAPositiveAmount() throws {
    let p = Project(id: "tiny", name: "Tiny", glyph: .flag, budget: .aed(100_00), starts: nil, ends: nil)
    let w = try projectWidget(p, spending: 350_00)
    #expect(w.unit == .over)
    #expect(w.left == .aed(250_00))
    #expect((w.progress?.value ?? 0) >= 1000)
  }

  @Test func aProjectWithNoBudgetReadsSpentAndHasNoProgress() throws {
    let p = Project(id: "move", name: "Moving", glyph: .flag, budget: nil, starts: nil, ends: nil)
    let w = try projectWidget(p, spending: 350_00)
    #expect(w.unit == .spent)
    #expect(w.left == .aed(350_00))
    #expect(w.progress == nil)
    #expect(w.caption.parts.isEmpty)
    let dated = Project(id: "dated", name: "Dated", glyph: .flag, budget: nil, starts: LocalDate(2026, 12, 14), ends: nil)
    let d = try projectWidget(dated)
    #expect(d.unit == .spent && d.left == .aed(0) && d.progress == nil)
    #expect(d.caption.rendered(hidden: false) == "\(dated.startVerb) 14 Dec")
  }

  @Test func aWidgetWithoutItsDataWaits() {
    var gone = s
    gone.projects = []
    gone.bills = []
    let layout = HomeLayout([entry(.project, .project("japan")), entry(.nextBill), entry(.comingUp), entry(.budgetPace)])
    let canvas = HomeEngine.canvas(layout, gone, now: now)
    #expect(canvas.map(\.isWaiting) == [true, true, true, false])
    #expect(canvas[0].kind.waitingSentence == "Start a project in Plan to see it here.")
  }

  @Test func itRoundTripsThroughJSON() throws {
    let layout = HomeLayout([entry(.today), entry(.goal, .goal("emergency")), entry(.comingUp)])
    let data = try JSONEncoder().encode(layout)
    #expect(try JSONDecoder().decode(HomeLayout.self, from: data) == layout)
  }

  @Test func unknownAndBrokenEntriesAreDropped() throws {
    let json = """
      {"version": 7, "entries": [
        {"kind": "budgetPace", "size": "medium"},
        {"kind": "horoscope", "size": "small"},
        {"kind": "today", "size": "huge"},
        {"kind": "categoryWatch", "size": "small"},
        {"kind": "categoryWatch", "size": "small", "config": {"kind": "weather", "id": "x"}},
        {"kind": "goal", "size": "small", "config": {"kind": "goal", "id": "emergency"}},
        {"kind": "goal", "size": "small", "config": {"kind": "goal", "id": "emergency"}},
        {"kind": "project", "config": {"kind": "category", "id": "dining"}},
        42
      ]}
      """
    let layout = try JSONDecoder().decode(HomeLayout.self, from: Data(json.utf8))
    #expect(layout.ids == ["budgetPace", "today", "goal.emergency"])
    #expect(layout.entries[1].size == .medium)
  }
}
