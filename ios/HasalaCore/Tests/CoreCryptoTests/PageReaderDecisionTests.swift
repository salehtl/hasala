import CorePrimitives
import CoreWire
import Foundation
import Testing

@testable import CoreCrypto

extension OpenOutcome {
  fileprivate var plaintextCount: Int {
    if case .opened(let p) = self { return p.count }
    return 0
  }
}

@Suite("PageReader: one decision for a row that was opened")
struct PageReaderDecisionTests {
  typealias Decision = PageReader.RowDecision

  static let aead = OpenOutcome.setAside(.aeadFailed, alarm: true)
  static let newerFrame = OpenOutcome.hardStop(.updateRequired)
  static let newerOps = OpenOutcome.opened(Data(#"{"v":5,"kind":"ops","ops":[]}"#.utf8))
  static let undecodable = OpenOutcome.opened(Data(#"{"v":4,"kind":"ops","ops":[{}]}"#.utf8))
  static let empty = OpenOutcome.opened(Data(#"{"v":4,"kind":"ops","ops":[]}"#.utf8))

  @Test("a page stopped by the plaintext budget says so; running out on its last row is a whole page")
  func budget() throws {
    let base = try TamperBase.make()
    let dwk = Ed25519.generate()
    let sig = try Ed25519.sign(
      seed: dwk.seed, message: SigningMessage.head(userID: testUser, counter: 2, blobHash: base.frame2.blobHash, writerID: testWriter))
    func row(_ f: SealedFrame, _ counter: Int, sig: Data?) -> PageReader.Row {
      PageReader.Row(
        stream: "hot", writerID: testWriter.string, counter: String(counter), sizeBucket: f.bytes.count, prevHash: f.prevHash.bytes,
        blobHash: f.blobHash.bytes, headSig: sig, blob: f.bytes)
    }
    let state = PageReader.State(
      userID: testUser, opener: base.opener, serverEpoch: nil, pinnedHeads: [:],
      roster: [testWriter: HeadCheck.RosterWriter(dwkPublicKey: dwk.publicKey, revokedAt: nil)], own: nil)
    let page = [row(base.frame1, 1, sig: nil), row(base.frame2, 2, sig: sig)]

    let short = PageReader.read(page, state: state, plaintextBudget: 1)
    #expect(short.stop == .budgetReached && short.stopRow == 0 && short.rows.count == 1)

    let whole = PageReader.read(page, state: state)
    #expect(whole.stop == nil && whole.stopRow == nil && whole.rows.count == 2)

    let plaintext = Self.empty.plaintextCount + base.plaintext2.count
    let exact = PageReader.read(page, state: state, plaintextBudget: plaintext)
    #expect(exact.stop == nil && exact.stopRow == nil && exact.rows.count == 2)
  }

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
