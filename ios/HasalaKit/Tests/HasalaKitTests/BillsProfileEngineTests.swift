import HasalaMocks
import HasalaModels
import Testing

/// Bills and Profile over MayaLedger reproduce their boards. Owned by P8 from Stage P.
@Suite("Maya ledger · Bills and profile parity")
struct BillsProfileEngineParityTests {
  let s = MayaLedger.state
  let now = MayaLedger.now

  @Test func billsMatchComingUpAndFound() {
    let b = BillsEngine.snapshot(s, now: now)
    #expect(b.next14 == .aed(1_039_15))
    #expect(b.incomeLine?.rendered(hidden: false) == "+25,000.00 expected Wed 28 Oct")
    #expect(b.needsALook.map(\.name) == ["AXA Insurance", "du"])
    #expect(b.needsALook[1].body.rendered(hidden: false) == "Charged 38.90 more than usual (389.00) on Mon 5 Oct.")
    #expect(b.upcoming.map(\.name) ==
      ["AXA Insurance", "DEWA", "Salary · Acme Gulf", "Rent · Al Habtoor", "Netflix", "Spotify"])
    #expect(b.recentlyPaid.map(\.name) == ["Spotify", "Netflix", "du", "Rent · Al Habtoor"])
    #expect(b.paidThisMonth == .aed(8_005_89))
    #expect(b.found.first?.evidence == ["Seen 5×", "Every ~30 days", "Last on 8 Oct"])
    #expect(b.tracked == 9)
  }

  @Test func profileCounts() {
    let p = ProfileEngine.snapshot(s, now: now)
    #expect(p.accounts.rendered(hidden: false) == "4 · net worth 227,568")
    #expect(p.bills == "9 tracked · 1 new found")
    #expect(p.categoriesAndRules.hasPrefix("18 categories"))
    #expect(p.projects?.rendered(hidden: false) == "Japan trip · 7,140.00 left")
    #expect(p.emailLine == "maya@example.com · Verified")
  }
}
