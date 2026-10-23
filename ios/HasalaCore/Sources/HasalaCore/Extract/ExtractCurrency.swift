import Foundation

public enum ExtractCurrency {
  static let isoCodes: Set<String> = RuleMoneyParser.codes.subtracting(["CNH"])
  static let aedAliases: Set<String> = Set(RuleMoneyParser.words.filter { $0.1 == "AED" }.map(\.0))

  public static func iso(_ captured: String) -> String? {
    let trimmed = captured.trimmingCharacters(in: .whitespacesAndNewlines)
    let upper = trimmed.uppercased()
    if isoCodes.contains(upper) { return upper }
    if aedAliases.contains(trimmed.lowercased()) { return "AED" }
    return nil
  }
}
