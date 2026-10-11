// The bundled UAE merchant dictionary (spec 03c §8.5; A-11, C10: bundled, no
// over-the-air feed).
//
// Load (§8.5.3): the bytes must hash to `DictionaryManifest.sha256`, else the
// tier is disabled with the diagnostic `dictionary_digest_mismatch` (never a
// crash); the file is parsed strictly, each entry validated (defects counted,
// content-free); the entries are prepared at priority 0 in the §5.2 order.
import CoreJSON
import CorePrimitives
import CoreResources
import Foundation
import HasalaText

public struct MerchantDictionary: Sendable, Equatable {
  public let bundle: String
  public let entries: [DictEntry]
  /// Entries refused at load (count shown in Settings › Diagnostics, never content).
  public let defects: [Defect]

  public static let empty = MerchantDictionary(bundle: "", entries: [], defects: [])

  public enum LoadError: Error, Equatable, Sendable {
    case missing
    case digestMismatch
    case malformed(String)
  }

  /// The bundled dictionary, or the reason the tier is disabled.
  public static func bundled() -> Result<MerchantDictionary, LoadError> {
    guard let url = CoreResources.bundle.url(forResource: "merchant-dictionary", withExtension: "json"),
      let data = try? Data(contentsOf: url)
    else { return .failure(.missing) }
    return load([UInt8](data), expectedSHA256: DictionaryManifest.sha256)
  }

  /// Parses and validates dictionary bytes (03c §8.5.1).
  public static func load(_ bytes: [UInt8], expectedSHA256: String?) -> Result<MerchantDictionary, LoadError> {
    if let expected = expectedSHA256, Hex.encode(sha256(bytes)) != expected { return .failure(.digestMismatch) }
    guard let doc = try? JSONParser.parse(bytes), let o = doc.objectValue else { return .failure(.malformed("not a JSON object")) }
    guard o["format"]?.stringValue == "hasala.merchant-dictionary", o["format_version"]?.numberValue?.v4Int == 1 else {
      return .failure(.malformed("unknown format"))
    }
    guard let bundle = o["bundle"]?.stringValue, isBundle(bundle) else { return .failure(.malformed("bad bundle")) }
    guard o["taxonomy"]?.numberValue?.v4Int == Int64(TaxonomyV1.version) else { return .failure(.malformed("other taxonomy")) }
    guard let list = o["entries"]?.arrayValue else { return .failure(.malformed("no entries")) }
    var entries: [DictEntry] = []
    var defects: [Defect] = []
    var seen: Set<String> = []
    for (i, raw) in list.enumerated() {
      guard let m = raw["m"]?.stringValue, let p = raw["p"]?.stringValue, let c = raw["c"]?.stringValue else {
        defects.append(Defect(id: "entry \(i)", code: "malformed"))
        continue
      }
      let display = raw["d"]?.stringValue
      if let d = display, TextRules.checkLabel(d) != nil {
        defects.append(Defect(id: "entry \(i)", code: "display_not_a_label"))
        continue
      }
      guard let info = TaxonomyV1.builtin(c), info.kind == .spending else {
        defects.append(Defect(id: "entry \(i)", code: "category_not_spending"))
        continue
      }
      switch Matcher.validateDictEntry(DictEntry(pattern: p, match: m, category: c, display: display)) {
      case .defect(let d): defects.append(d)
      case .entry(let e):
        guard utf8Equal(e.pattern, p) else {
          defects.append(Defect(id: "entry \(i)", code: "pattern_not_canonical"))
          continue
        }
        guard seen.insert(m + "\u{0}" + p).inserted else {
          defects.append(Defect(id: "entry \(i)", code: "duplicate"))
          continue
        }
        entries.append(e)
      }
    }
    return .success(MerchantDictionary(bundle: bundle, entries: entries, defects: defects))
  }

  private static func isBundle(_ s: String) -> Bool {
    // `^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]{1,3}$`
    let u = Array(s.utf8)
    guard (12...14).contains(u.count), u[4] == 0x2e, u[7] == 0x2e, u[10] == 0x2d else { return false }
    return u.enumerated().allSatisfy { i, b in i == 4 || i == 7 || i == 10 || ASCII.isDigit(b) }
  }

  /// The `category_source.entry` of a dictionary decision: `<match>:<pattern>`.
  public static func sourceEntry(_ hit: MatchHit) -> String { "\(hit.match.rawValue):\(hit.pattern)" }
}
