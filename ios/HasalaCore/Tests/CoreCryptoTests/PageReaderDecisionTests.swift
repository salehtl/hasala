import CoreCrypto
import CoreWire
import Foundation
import Testing

@Suite("PageReader: one decision for a row that was opened")
struct PageReaderDecisionTests {
  typealias Decision = PageReader.RowDecision

  static let aead = OpenOutcome.setAside(.aeadFailed, alarm: true)
  static let newerFrame = OpenOutcome.hardStop(.updateRequired)
  static let newerOps = OpenOutcome.opened(Data(#"{"v":5,"kind":"ops","ops":[]}"#.utf8))
  static let undecodable = OpenOutcome.opened(Data(#"{"v":4,"kind":"ops","ops":[{}]}"#.utf8))
  static let empty = OpenOutcome.opened(Data(#"{"v":4,"kind":"ops","ops":[]}"#.utf8))

  @Test("a frame or an op version above this build stops the page, unless newer rows are set aside")
  func newer() {
    let stop = Decision.stop(.hardStop(.updateRequired))
    let aside = Decision.row(.setAside(.opsUndecodable, alarm: false))
    #expect(PageReader.decide(Self.newerFrame, setsAsideNewer: false) == stop)
    #expect(PageReader.decide(Self.newerOps, setsAsideNewer: false) == stop)
    #expect(PageReader.decide(Self.newerFrame, setsAsideNewer: true) == aside)
    #expect(PageReader.decide(Self.newerOps, setsAsideNewer: true) == aside)
  }

  @Test("every other outcome is the same whether or not newer rows are set aside", arguments: [false, true])
  func rest(setsAsideNewer: Bool) {
    func decide(_ o: OpenOutcome) -> Decision { PageReader.decide(o, setsAsideNewer: setsAsideNewer) }
    #expect(decide(Self.aead) == .row(.setAside(.aeadFailed, alarm: true)))
    #expect(decide(.setAside(.payloadInvalid, alarm: false)) == .row(.setAside(.payloadInvalid, alarm: false)))
    #expect(decide(Self.undecodable) == .row(.setAside(.opsUndecodable, alarm: false)))
    #expect(decide(.needsUnlock(epoch: 3)) == .stop(.needsUnlock(epoch: 3)))
    #expect(decide(.refreshEpoch(3)) == .stop(.refreshEpoch(3)))
    #expect(decide(.hardStop(.tampered(.aadMismatch))) == .stop(.hardStop(.tampered(.aadMismatch))))
    #expect(decide(Self.empty) == .row(.opened(plaintext: Data(#"{"v":4,"kind":"ops","ops":[]}"#.utf8), ops: [])))
  }
}
