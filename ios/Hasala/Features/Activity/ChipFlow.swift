import SwiftUI

/// Chips in rows that wrap at the width offered, never scrolling sideways (Paper "Choice
/// chips": "Rows wrap with gap 8"): the category picker, the pick sheet's projects, the split
/// shortcuts, Search's recent searches.
///
/// Like the shared `FlowLayout`, but it measures and places with one rule and allows half a
/// point of rounding. `FlowLayout` reports the width of its widest row, and is then placed in a
/// box rounded to the pixel grid that can be a fraction narrower; the last chip of that row
/// wraps at placement onto a row it never reserved, over whatever sits below (the pick sheet's
/// "Japan trip" landed on the rule checkbox). `requests/p6.md` asks for the same fix there.
struct ChipFlow: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = Self.rows(subviews.map { $0.sizeThatFits(.unspecified) }, width: proposal.width, spacing: spacing)
    let height = rows.reduce(CGFloat(0)) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
    let widest = rows.map(\.width).max() ?? 0
    return CGSize(width: proposal.width.map { min(widest, $0) } ?? widest, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    var y = bounds.minY
    for row in Self.rows(sizes, width: bounds.width, spacing: spacing) {
      var x = bounds.minX
      for i in row.indices {
        subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sizes[i]))
        x += sizes[i].width + spacing
      }
      y += row.height + spacing
    }
  }

  struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  /// The rows `sizes` break into at `width` (one row when there is no width to fit). A chip
  /// wider than the whole width takes a row of its own.
  static func rows(_ sizes: [CGSize], width: CGFloat?, spacing: CGFloat) -> [Row] {
    let limit = (width ?? .infinity) + 0.5
    var rows: [Row] = []
    var row = Row()
    for (i, size) in sizes.enumerated() {
      let next = row.indices.isEmpty ? size.width : row.width + spacing + size.width
      if !row.indices.isEmpty, next > limit {
        rows.append(row)
        row = Row()
      }
      row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
      row.height = max(row.height, size.height)
      row.indices.append(i)
    }
    if !row.indices.isEmpty { rows.append(row) }
    return rows
  }
}
