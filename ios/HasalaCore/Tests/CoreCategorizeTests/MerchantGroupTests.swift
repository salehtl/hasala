import HasalaText
import Testing

@testable import CoreCategorize

@Suite struct MerchantGroupTests {
  static let dictionary = try! MerchantDictionary.bundled().get()
  static let groups = MerchantGroup(dictionary: dictionary)

  static func key(_ raw: String) -> String { groups.key(raw: raw) }

  @Test func threeTailscaleSpellingsShareAKey() {
    let keys = ["TAILSCALE INC", "TAILSCALE.COM 4155550100 US", "PADDLE.NET* TAILSCALE"].map(Self.key)
    #expect(keys == ["n:tailscale", "n:tailscale", "n:tailscale"])
  }

  @Test func alNoorTradingIsNotAlNoorPharmacy() {
    #expect(Self.key("AL NOOR TRADING LLC") == "n:al noor trading")
    #expect(Self.key("AL NOOR PHARMACY") == "n:al noor pharmacy")
    #expect(Self.key("Al Noor Trading L.L.C.") == Self.key("AL NOOR TRADING"))
  }

  @Test func facilitatorsKeepTheMerchantAfterTheStar() {
    #expect(Self.key("PAYPAL *NETFLIX") != Self.key("PAYPAL *SPOTIFY"))
    #expect(Self.key("PAYPAL *TAILSCALE") == "n:tailscale")
    #expect(Self.key("PAYPAL *FIGMA") != Self.key("PAYPAL *LINEAR"))
    #expect(Self.key("GOOGLE *DUOLINGO") == "n:duolingo")
    #expect(Self.key("SQ *BLUE BOTTLE CAFE 12") == "n:blue bottle cafe")
    #expect(Self.key("SP * HOMEWARE STUDIO") == "n:homeware studio")
    #expect(Self.key("PAYPAL *") == "n:paypal")
    #expect(Self.key("PAYPAL *GOOGLE *DUOLINGO") == "n:duolingo")
  }

  @Test func aReferenceAfterAFacilitatorKeepsThePrefix() {
    #expect(Self.key("AMZN Mktp US*2K1AB3CD4") == "n:amzn mktp")
    #expect(Self.key("AMZN MKTP US*9Z8YX7W") == "n:amzn mktp")
  }

  @Test func otherStarsDropWhatFollows() {
    #expect(Self.key("SOME SHOP*REF 123") == "n:some shop")
    #expect(Self.key("OTHER SHOP*REF 123") == "n:other shop")
    #expect(Self.key("*TAILSCALE") == "n:tailscale")
    #expect(Self.key("**") == "n:**")
  }

  @Test func noiseIsStrippedOnlyAtTheEdges() {
    #expect(Self.key("ZEN GARDEN FZE") == Self.key("zen garden fzco"))
    #expect(Self.key("BLUE OCEAN TRDG EST") == "n:blue ocean")
    #expect(Self.key("CAFE NERO 0042 DUBAI AE") == "n:cafe nero 0042 dubai")
    #expect(Self.key("7-ELEVEN 1234") == "n:7-eleven")
    #expect(Self.key("123456") == "n:123456")
    #expect(Self.key("www.tailscale.com") == "n:tailscale")
    #expect(Self.key("INC") == "n:inc")
    #expect(Self.key("US") == "n:us")
    #expect(Self.key("مطعم السلام 12") == "n:مطعم السلام")
  }

  @Test func theDictionaryWinsInMatcherOrder() {
    #expect(Self.key("PAYPAL *NETFLIX") == "d:netflix")
    #expect(Self.key("NETFLIX.COM") == "d:netflix")
    #expect(Self.key("CAREEM RIDE") == "d:careem")
    #expect(Self.key("CAREEM FOOD 12") == "d:careem food")
    #expect(Self.key("طلبات") == "d:talabat")
    let hit = Matcher.firstHit("CAREEM FOOD 12", Matcher.prepare(rules: [], entries: Self.dictionary.entries))
    #expect(hit?.display == "Careem Food")
  }

  @Test func userRulesAndCategoriesAreNotInputs() {
    let rule = RuleInput(id: "r1", patterns: ["careem"], match: "contains", category: "dining", priority: 10)
    let withRule = Categorizer(rules: [rule], dictionary: Self.dictionary, categories: BuiltinCategories())
    #expect(withRule.decide(merchantRaw: "CAREEM RIDE", direction: .debit).category == "dining")
    #expect(Self.key("CAREEM RIDE") == "d:careem")
  }

  @Test func anEntryWithoutADisplayNameKeysByItsPattern() throws {
    let bare = MerchantDictionary(bundle: "2026.01.01-1", entries: [DictEntry(pattern: "tailscale", match: "contains", category: "subscriptions")], defects: [])
    #expect(MerchantGroup.key(raw: "TAILSCALE INC", dictionary: bare) == "e:contains:tailscale")
    #expect(MerchantGroup.key(raw: "TAILSCALE INC", dictionary: .empty) == "n:tailscale")
  }

  @Test func emptyAndSpaceOnlySubjectsHaveNoKey() {
    #expect(Self.key("") == "")
    #expect(Self.key(" \t ") == "")
  }

  @Test func spellingsDifferingInNormalizationStayApart() {
    let nfc = "CAF\u{00C9} BLEU"
    let nfd = "CAFE\u{0301} BLEU"
    #expect(!utf8Equal(Self.key(nfc), Self.key(nfd)))
  }

  @Test func keysAreAtMost256Scalars() {
    let long = String(repeating: "abcdefgh ", count: 60)
    #expect(Self.key(long).unicodeScalars.count == MerchantGroup.maxKeyRunes)
  }

  @Test func eachDisplayNameOfTheBundledDictionaryHasOneCategory() {
    var categories: [ExactKey: String] = [:]
    for e in Self.dictionary.entries {
      let k = ExactKey(Canon.canonical(e.display ?? ""))
      if let c = categories[k] {
        #expect(utf8Equal(c, e.category), "\(k.value): \(c) and \(e.category)")
      } else {
        categories[k] = e.category
      }
    }
    #expect(!categories.keys.contains(ExactKey("")))
  }
}
