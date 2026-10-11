// The fold seam of a pull (spec 04 §5.2 steps 4-5, §5.6): a page the reader
// decided is folded onto a COPY of the state, the incremental invariants run,
// and only a clean result is handed back to be persisted with the page. A
// hard stop keeps the whole page out (the caller persists nothing).
import CoreCrypto
import CoreReplay
import CoreWire

public enum FoldHalt: Error, Sendable, Equatable {
  /// An op or blob newer than this build: the "Update Hasala" wall.
  case updateRequired
  /// The page's seqs do not move forward (a reader or server fault).
  case order(String)
  /// The folded state breaks an invariant: the `inconsistent` wall.
  case inconsistent([Violation])
}

/// One decided row of a page.
public struct FoldRow: Sendable {
  public let seq: Int64
  public let writerID: String
  public let counter: Int64
  public let outcome: PageReader.RowOutcome

  public init(seq: Int64, writerID: String, counter: Int64, outcome: PageReader.RowOutcome) {
    self.seq = seq
    self.writerID = writerID
    self.counter = counter
    self.outcome = outcome
  }
}

public enum LedgerFold {
  /// Folds `rows` onto `state` and checks it; returns the new state, or halts.
  public static func page(_ rows: [FoldRow], onto state: State) throws(FoldHalt) -> State {
    var s = state
    do {
      for r in rows {
        switch r.outcome {
        case .opened(_, let ops):
          try Replay.foldOps(ops, seq: r.seq, writerID: r.writerID, into: &s)
        case .setAside(let reason, _):
          try Replay.foldSetAside(seq: r.seq, writerID: r.writerID, writerCounter: r.counter, reason: reason.rawValue, into: &s)
        }
      }
    } catch {
      switch error {
      case .newerVersion: throw .updateRequired
      case .order(let m): throw .order(m)
      }
    }
    let hard = Invariants.check(s).filter { $0.severity == .hardStop }
    if !hard.isEmpty { throw .inconsistent(hard) }
    return s
  }
}
