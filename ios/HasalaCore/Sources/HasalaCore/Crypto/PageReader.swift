// The reader of spec 01 §6.6, composed: one pulled page through R0-R10, in
// order. The first failing step decides.
//
//   page-wide, before any blob is opened (nothing from the page is persisted on
//   a failure): R0 row shape, R1 roster, the own-writer rule, R2 chain from the
//   pinned heads, R2b signed heads (the order of Go's reference reader);
//   then per row: R3-R9 (`Opener`) and R10 (`OpCodec.decodeR10`).
//
// The caller (CoreSync) persists rows, cursor and heads in one transaction, and
// only when nothing hard-stopped (§7 "Client order"). Its two network steps are
// outcomes here, never decided by the reader: `refreshRoster` (R1: re-fetch
// `GET /key-history` once, verify it with `KeyHistoryVerifier`, read the page
// again with `rosterRefreshed`) and `refreshEpoch` (R4: re-read `GET /keys`
// once, read the page again with `serverEpoch`).
import CorePrimitives
import CoreWire
import Foundation

public enum PageReader {
  /// A pulled row as the server serves it.
  public struct Row: Sendable, Hashable {
    public let stream: String
    public let writerID: String
    /// `writer_counter` exactly as the wire carries it (a decimal string): R0
    /// checks its grammar here, not the caller's parser.
    public let counter: String
    public let sizeBucket: Int
    public let prevHash: Data
    public let blobHash: Data
    public let headSig: Data?
    public let blob: Data

    public init(
      stream: String, writerID: String, counter: String, sizeBucket: Int, prevHash: Data, blobHash: Data, headSig: Data?,
      blob: Data
    ) {
      self.stream = stream
      self.writerID = writerID
      self.counter = counter
      self.sizeBucket = sizeBucket
      self.prevHash = prevHash
      self.blobHash = blobHash
      self.headSig = headSig
      self.blob = blob
    }
  }

  /// What the device knows before the page.
  public struct State: Sendable {
    public let userID: UserID
    public let opener: Opener
    /// `current_epoch` from a fresh `GET /keys`, once the reader asked for it.
    public let serverEpoch: UInt32?
    /// Each writer's pinned head; a writer without one starts at the genesis.
    public let pinnedHeads: [WriterID: Chain.Head]
    /// The roster `KeyHistoryVerifier` produced (§10.13; `KeyHistoryVerifier.Roster.forReader`),
    /// never `GET /writers`.
    public let roster: [WriterID: HeadCheck.RosterWriter]
    /// Whether `roster` was re-fetched for this page already (R1's one re-fetch).
    /// While false, an unknown writer is `refreshRoster`; once true, it is
    /// `hardStop(.tampered(.unknownWriter))`.
    public let rosterRefreshed: Bool
    /// The device's own writer and its authored head. `authoredHead` is the
    /// highest counter this device has SEALED for the writer, including the
    /// in-flight record's counters (R-OUT-2; `04` §5.5), not only those the
    /// server acknowledged: a batch the server accepted but whose response was
    /// lost comes back in a pull, and must not read as `ownChainConflict`.
    public let own: (writer: WriterID, authoredHead: Int64)?

    public init(
      userID: UserID, opener: Opener, serverEpoch: UInt32?, pinnedHeads: [WriterID: Chain.Head],
      roster: [WriterID: HeadCheck.RosterWriter], rosterRefreshed: Bool = false,
      own: (writer: WriterID, authoredHead: Int64)?
    ) {
      self.userID = userID
      self.opener = opener
      self.serverEpoch = serverEpoch
      self.pinnedHeads = pinnedHeads
      self.roster = roster
      self.rosterRefreshed = rosterRefreshed
      self.own = own
    }
  }

  public enum RowOutcome: Sendable, Hashable {
    case opened(plaintext: Data, ops: [Op])
    case setAside(SetAsideReason, alarm: Bool)
  }

  public enum Stop: Sendable, Hashable {
    case hardStop(ReaderHardStop)
    /// R6: enter `needsUnlock`; the page stops here and the cursor stays.
    case needsUnlock(epoch: UInt32)
    /// R4: re-read `GET /keys` once and read the page again with `serverEpoch`.
    case refreshEpoch(UInt32)
    /// R1: re-fetch `GET /key-history` once, verify it (§10.13) and read the
    /// page again with the new roster and `rosterRefreshed: true`. Nothing from
    /// the page is persisted.
    case refreshRoster
  }

  public struct Result: Sendable, Hashable {
    /// The rows decided before any stop, in page order.
    public let rows: [RowOutcome]
    /// The stop and the index of the row it names.
    public let stop: Stop?
    public let stopRow: Int?
  }

  public static func read(_ page: [Row], state: State) -> Result {
    func stopped(_ i: Int, _ s: Stop, _ rows: [RowOutcome] = []) -> Result { Result(rows: rows, stop: s, stopRow: i) }

    // R0: shape.
    var checked: [RowShape.Checked] = []
    for (i, r) in page.enumerated() {
      guard
        let c = RowShape.check(
          stream: r.stream, writerID: r.writerID, counter: r.counter, sizeBucket: r.sizeBucket, blob: r.blob,
          prevHash: r.prevHash, blobHash: r.blobHash)
      else { return stopped(i, .hardStop(.tampered(.rowShape))) }
      checked.append(c)
    }
    // R1: the roster, re-fetched once before an unknown writer is tampering.
    for (i, c) in checked.enumerated() where state.roster[c.writerID] == nil {
      return stopped(i, state.rosterRefreshed ? .hardStop(.tampered(.unknownWriter)) : .refreshRoster)
    }
    // Rows of the device's own writer above its authored head, which it did not author.
    if let own = state.own {
      for (i, c) in checked.enumerated() where c.writerID == own.writer && c.counter > own.authoredHead {
        return stopped(i, .hardStop(.tampered(.ownChainConflict)))
      }
    }
    // R2: the chain, per writer, from its pinned head.
    var heads = state.pinnedHeads
    for (i, c) in checked.enumerated() {
      let head = heads[c.writerID] ?? .genesis
      guard c.counter == head.counter + 1, c.prevHash == head.hash,
        Chain.hash(prev: c.prevHash, frame: c.blob) == c.blobHash
      else { return stopped(i, .hardStop(.tampered(.chainBreak))) }
      heads[c.writerID] = Chain.Head(counter: c.counter, hash: c.blobHash)
    }
    // R2b: the signed heads.
    let headRows = zip(checked, page).map {
      HeadCheck.Row(writerID: $0.writerID, counter: $0.counter, blobHash: $0.blobHash, headSig: $1.headSig)
    }
    if let f = HeadCheck.firstFailure(userID: state.userID, rows: headRows, roster: state.roster) {
      return stopped(f.index, .hardStop(.tampered(f.reason)))
    }
    // R3-R10, row by row.
    var out: [RowOutcome] = []
    for (i, c) in checked.enumerated() {
      let envelope: Envelope
      do {
        envelope = try Envelope(userID: state.userID, writerID: c.writerID, counter: c.counter)
      } catch {
        return stopped(i, .hardStop(.tampered(.rowShape)), out)
      }
      switch state.opener.open(c.blob, envelope: envelope, prevHash: c.prevHash, serverEpoch: state.serverEpoch) {
      case .hardStop(let h): return stopped(i, .hardStop(h), out)
      case .needsUnlock(let e): return stopped(i, .needsUnlock(epoch: e), out)
      case .refreshEpoch(let e): return stopped(i, .refreshEpoch(e), out)
      case .setAside(let reason, let alarm): out.append(.setAside(reason, alarm: alarm))
      case .opened(let plaintext):
        switch OpCodec.decodeR10(plaintext) {
        case .ops(let ops): out.append(.opened(plaintext: plaintext, ops: ops))
        case .hardStop(let h): return stopped(i, .hardStop(h), out)
        case .setAside(let reason, _): out.append(.setAside(reason, alarm: false))
        }
      }
    }
    return Result(rows: out, stop: nil, stopRow: nil)
  }
}
