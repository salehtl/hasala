import Foundation

public enum CategoryIconGuess {
  public static let fallback: Glyph = .tag

  static let table: [(glyph: Glyph, words: [String])] = [
    (.refunds, ["refund", "return", "استرداد", "مرتجع"]),
    (.transfer, ["transfer", "تحويل"]),
    (.salary, ["salary", "wage", "bonus", "راتب", "مكافأة"]),
    (.freelance, ["freelance", "مستقل"]),
    (.debt, ["loan", "debt", "mortgage", "قرض", "دين"]),
    (.insurance, ["insurance", "تأمين"]),
    (.investments, ["investment", "stock", "shares", "crypto", "gold", "استثمار", "أسهم", "ذهب"]),
    (.savingsJar, ["savings", "saving", "emergency", "fund", "ادخار", "توفير"]),
    (.subscriptions, ["subscription", "membership", "streaming", "اشتراك", "اشتراكات"]),
    (.utilities, ["utilities", "electricity", "water", "internet", "phone", "mobile", "كهرباء", "ماء", "مياه", "إنترنت", "هاتف", "جوال"]),
    (.rent, ["rent", "home", "house", "housing", "apartment", "flat", "إيجار", "بيت", "منزل", "شقة", "سكن"]),
    (.groceries, ["grocery", "groceries", "supermarket", "market", "vegetables", "fruit", "بقالة", "سوبرماركت", "خضار", "فواكه"]),
    (.dining, ["coffee", "cafe", "restaurant", "food", "lunch", "dinner", "breakfast", "snack", "قهوة", "مطعم", "مطاعم", "طعام", "أكل", "غداء", "عشاء", "فطور"]),
    (.healthcare, ["health", "doctor", "pharmacy", "medicine", "medical", "hospital", "clinic", "dentist", "gym", "fitness", "صحة", "طبيب", "صيدلية", "دواء", "مستشفى", "عيادة", "رياضة"]),
    (.transport, ["car", "fuel", "petrol", "taxi", "metro", "bus", "parking", "transport", "commute", "سيارة", "بنزين", "وقود", "تاكسي", "مترو", "مواقف", "مواصلات"]),
    (.travel, ["travel", "flight", "hotel", "holiday", "vacation", "trip", "سفر", "طيران", "فندق", "عطلة", "رحلة"]),
    (.entertainment, ["fun", "movie", "cinema", "game", "gaming", "concert", "hobby", "hobbies", "سينما", "ألعاب", "ترفيه"]),
    (.shopping, ["shopping", "clothes", "clothing", "fashion", "shoes", "gift", "electronics", "تسوق", "ملابس", "أحذية", "هدايا", "هدية"]),
  ]

  static let folded: [(glyph: Glyph, words: Set<String>)] = table.map { ($0.glyph, Set($0.words.map(fold))) }

  public static func glyph(for name: String) -> Glyph {
    let words = Set(tokens(name).flatMap(forms))
    return folded.first { !$0.words.isDisjoint(with: words) }?.glyph ?? fallback
  }

  static func fold(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for u in s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).unicodeScalars {
      switch u.value {
      case 0x0640, 0x064B...0x065F, 0x0670: continue
      case 0x0629: out.append("\u{0647}")
      case 0x0649: out.append("\u{064A}")
      default: out.append(u)
      }
    }
    return String(out)
  }

  static func tokens(_ name: String) -> [String] {
    fold(name).split { !$0.isLetter && !$0.isNumber }.map(String.init)
  }

  static func forms(_ word: String) -> [String] {
    var out = [word]
    if word.hasPrefix("\u{0627}\u{0644}"), word.count > 3 { out.append(String(word.dropFirst(2))) }
    if word.hasSuffix("s"), word.count > 3 { out.append(String(word.dropLast())) }
    return out
  }
}
