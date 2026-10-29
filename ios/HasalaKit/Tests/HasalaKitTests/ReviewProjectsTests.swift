import HasalaMocks
import HasalaModels
import Testing

@Suite("Review · projects")
struct ReviewProjectsTests {
  func state(_ projects: [Project]) -> LedgerState {
    var s = MayaLedger.state
    s.projects = projects
    return s
  }

  func project(_ id: ProjectID, _ starts: LocalDate?, _ ends: LocalDate?, complete: Bool = false) -> Project {
    Project(id: id, name: id.capitalized, glyph: .flag, budget: nil, starts: starts, ends: ends, complete: complete)
  }

  @Test func projectsKeepTheirOrderAndThoseWhoseDatesCoverTheDayAreSuggested() {
    let s = state([
      project("later", LocalDate(2026, 12, 14), LocalDate(2026, 12, 28)),
      project("now", LocalDate(2026, 10, 1), LocalDate(2026, 10, 31)),
      project("before", LocalDate(2026, 9, 1), LocalDate(2026, 9, 30)),
      project("also", LocalDate(2026, 10, 9), LocalDate(2026, 10, 9)),
    ])
    let choices = ReviewEngine.projectChoices(s, on: LocalDate(2026, 10, 9))
    #expect(choices.map(\.id) == ["later", "now", "before", "also"])
    #expect(choices.map(\.suggested) == [false, true, false, true])
    #expect(choices[1].name == "Now" && choices[1].glyph == .flag)
  }

  @Test func bothEndsAreInclusive() {
    let s = state([project("trip", LocalDate(2026, 12, 14), LocalDate(2026, 12, 28))])
    #expect(ReviewEngine.projectChoices(s, on: LocalDate(2026, 12, 14)).first?.suggested == true)
    #expect(ReviewEngine.projectChoices(s, on: LocalDate(2026, 12, 28)).first?.suggested == true)
    #expect(ReviewEngine.projectChoices(s, on: LocalDate(2026, 12, 13)).first?.suggested == false)
    #expect(ReviewEngine.projectChoices(s, on: LocalDate(2026, 12, 29)).first?.suggested == false)
  }

  @Test func aMissingDateIsOpenEnded() {
    let s = state([
      project("until", nil, LocalDate(2026, 10, 1)),
      project("since", LocalDate(2026, 11, 1), nil),
      project("open", nil, nil),
      project("from", LocalDate(2026, 10, 1), nil),
    ])
    let choices = ReviewEngine.projectChoices(s, on: LocalDate(2026, 10, 9))
    #expect(choices.map(\.id) == ["until", "since", "open", "from"])
    #expect(choices.map(\.suggested) == [false, false, true, true])
  }

  @Test func completedProjectsAreLeftOut() {
    let s = state([
      project("done", nil, nil, complete: true),
      project("open", LocalDate(2026, 12, 1), nil),
    ])
    let choices = ReviewEngine.projectChoices(s, on: LocalDate(2026, 10, 9))
    #expect(choices.map(\.id) == ["open"])
    #expect(choices.first?.suggested == false)
    #expect(ReviewEngine.projectChoices(state([]), on: LocalDate(2026, 10, 9)).isEmpty)
  }
}
