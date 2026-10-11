// Review lanes (spec 03c §3.7, port of `sources/review.ts` with v4 precedence):
// superseded → none; archived → none; unparsed → unreadable; a possible
// duplicate with no disposition → duplicate; needs_review → needs_review; no
// category (and not split) or a model suggestion → uncategorized. The deck
// shows the needs_review and uncategorized lanes. "Skip for now" is
// device-local, never an op.
import CoreReplay

public enum ReviewLane: String, Sendable, CaseIterable {
  case unreadable, duplicate
  case needsReview = "needs_review"
  case uncategorized

  public var inDeck: Bool { self == .needsReview || self == .uncategorized }
}

public enum ReviewQueue {
  public static func lane(_ t: Txn) -> ReviewLane? {
    if t.supersededBy != nil { return nil }
    if t.annotation("archived") != nil { return nil }
    if t.unparsed { return .unreadable }
    if t.possibleDuplicateOf != nil && t.duplicateDisposition == nil { return .duplicate }
    if t.needsReview { return .needsReview }
    if (t.category == nil && t.splits.isEmpty) || t.categorySource?.kind == .model { return .uncategorized }
    return nil
  }
}
