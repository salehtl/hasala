import HasalaModels
import SwiftUI

// The first kit's glyph names. Its parts moved to their own files in F1: figures to Money.swift,
// discs to Discs.swift, pills and badges to Chips.swift, headings to Lists.swift, bars to Pace.swift.

public extension Glyph {
  /// The SF Symbol that stood in for this glyph before the custom set (`icon`). Kept until
  /// Stage I for the screens that still name a symbol.
  var symbolName: String {
    switch self {
    case .review: "display"
    case .insurance: "shield"
    case .utilities: "bolt"
    case .travel: "airplane"
    case .savingsJar: "lock"
    case .dining: "fork.knife"
    case .budgetPie: "chart.pie.fill"
    case .trendUp: "chart.line.uptrend.xyaxis"
    case .add: "plus"
    case .rent: "house"
    case .groceries: "basket"
    case .transport: "car"
    case .shopping: "bag"
    case .salary: "briefcase"
    case .transfer: "arrow.left.arrow.right"
    case .flag: "flag"
    case .healthcare: "cross.case"
    case .entertainment: "ticket"
    case .subscriptions: "repeat"
    case .investments: "chart.line.uptrend.xyaxis"
    case .debt: "creditcard"
    case .freelance: "laptopcomputer"
    case .refunds: "receipt"
    case .bank: "building.columns"
    case .tag: "tag"
    case .bill: "doc.text"
    case .wallet: "wallet.bifold"
    case .envelope: "envelope"
    case .rule: "arrow.triangle.branch"
    }
  }
}
