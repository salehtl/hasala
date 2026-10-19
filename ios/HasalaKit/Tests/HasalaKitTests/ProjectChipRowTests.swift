import HasalaMocks
import HasalaModels
import Testing

@Suite("Projects · chip on rows")
struct ProjectChipRowTests {
  let now = MayaLedger.now
  let japan = MiniTxnRow.Project(id: "japan", name: "Japan trip")

  func state() throws -> LedgerState {
    var s = MayaLedger.state
    let talabat = try #require(s.txns.firstIndex { $0.id == "talabat" })
    s.txns[talabat].projectID = "japan"
    let i = try #require(s.projects.firstIndex { $0.id == "japan" })
    s.projects[i].countInPlan = true
    return s
  }

  @Test func activityHistoryRowsCarryTheirProject() throws {
    let s = try state()
    let rows = ActivityEngine.snapshot(s, now: now, filter: .all).days.flatMap(\.rows)
    #expect(rows.first { $0.id == "talabat" }?.project == japan)
    #expect(rows.first { $0.id == "talabat-3" }?.project == nil)
    let searched = ActivityEngine.snapshot(s, now: now, filter: TxnFilter(text: "Emirates")).days.flatMap(\.rows)
    #expect(searched.first { $0.id == "emirates" }?.project == japan)
  }

  @Test func aCategoryListInActivityCarriesTheProject() throws {
    let s = try state()
    let rows = ActivityEngine.snapshot(s, now: now, filter: TxnFilter(category: "dining")).rows
    #expect(rows.first { $0.id == "talabat" }?.project == japan)
  }

  @Test func searchAnswersCarryTheProject() throws {
    let s = try state()
    let a = AskEngine.answer(s, filter: AskFilter(merchants: ["Emirates"]))
    #expect(a.rows.first { $0.id == "emirates" }?.project == japan)
  }

  @Test func aCategoryDetailListCarriesTheProject() throws {
    let s = try state()
    let d = try #require(PlanEngine.category("dining", s, now: now))
    #expect(d.transactions.first { $0.id == "talabat" }?.project == japan)
    #expect(d.transactions.first { $0.id == "talabat-3" }?.project == nil)
  }

  @Test func theProjectsOwnListAddTransactionsAndTodayLeaveItOut() throws {
    let s = try state()
    let p = try #require(PlanEngine.project("japan", s, now: now))
    #expect(p.transactions.contains { $0.id == "talabat" })
    #expect(p.transactions.allSatisfy { $0.project == nil })
    let candidates = PlanEngine.projectCandidates("other", s, filter: ProjectCandidateFilter())
    #expect(candidates.contains { $0.id == "talabat" })
    #expect(candidates.allSatisfy { $0.project == nil })
    guard case .today(let today)? = HomeEngine.snapshot(s, now: now).widgets.first(where: { $0.id == "today" }) else {
      Issue.record("Today is missing")
      return
    }
    #expect(today.rows.contains { $0.id == "t.talabat" })
    #expect(today.rows.allSatisfy { $0.project == nil })
  }
}
