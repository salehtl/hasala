import HasalaMocks
import HasalaModels
import Testing

/// Home derived from MayaLedger is the Home board (spec 04 §15.3). Owned by P5 from Stage P.
@Suite("Maya ledger · Home parity")
struct HomeEngineParityTests {
  let s = MayaLedger.state
  let now = MayaLedger.now

  @Test func homeDerivedFromTheLedgerIsTheHomeBoard() {
    let home = HomeEngine.snapshot(s, now: now)
    #expect(home.hero == Maya.home.hero)
    #expect(home.needsYou == Maya.home.needsYou)
    #expect(home.header == Maya.home.header)
    #expect(home.widgets == Maya.home.widgets)
  }
}
