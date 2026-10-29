import HasalaModels

public struct MockPerson: Sendable, Hashable {
  public var displayName: String
  public var email: String
  public var emailVerified: Bool
  public var gmailAddress: String
  public var outlookAddress: String
  public var emailHint: String

  public init(
    displayName: String, email: String, emailVerified: Bool = true, gmailAddress: String, outlookAddress: String,
    emailHint: String
  ) {
    self.displayName = displayName
    self.email = email
    self.emailVerified = emailVerified
    self.gmailAddress = gmailAddress
    self.outlookAddress = outlookAddress
    self.emailHint = emailHint
  }

  public static let maya = MockPerson(
    displayName: Maya.displayName, email: "maya@example.com", gmailAddress: "maya@example.com",
    outlookAddress: "maya.k@example.com", emailHint: "m\u{2022}\u{2022}\u{2022}@e\u{2022}\u{2022}\u{2022}.com")

  public static let worst = MockPerson(
    displayName: "عبد الرحمن سعيد خلفان المزروعي",
    email: "bartholomew.fitzgerald@northwind-industries-holdings.example.com", emailVerified: false,
    gmailAddress: "bartholomew.fitzgerald@northwind-industries-holdings.example.com",
    outlookAddress: "first.last+bank-alerts@example.com",
    emailHint: "b" + String(repeating: "\u{2022}", count: 21) + "@n" + String(repeating: "\u{2022}", count: 32)
      + ".example.com")

  public static let one = MockPerson(
    displayName: "Jo", email: "a@b.co", gmailAddress: "a@b.co", outlookAddress: "j@b.co",
    emailHint: "a\u{2022}@b\u{2022}.co")

  public static let huge = MockPerson(
    displayName: "Mohammed Abdulrahman Saeed Khalfan Al Mansoori Al Falasi Hamdan",
    email: "finance.reconciliation.notifications.dubai.branch+hasala@accounts-payable.northwind-industries-holdings.example.com",
    gmailAddress:
      "finance.reconciliation.notifications.dubai.branch+hasala@accounts-payable.northwind-industries-holdings.example.com",
    outlookAddress: MayaWorst.longestAddress,
    emailHint: "f" + String(repeating: "\u{2022}", count: 55) + "@a" + String(repeating: "\u{2022}", count: 50)
      + ".example.com")

  public static func of(_ scenario: Scenario) -> MockPerson {
    switch scenario {
    case .mayaWorst, .mayaWorstTexts: .worst
    case .mayaOne: .one
    case .mayaHuge: .huge
    default: .maya
    }
  }

  public func withEmail(_ address: String) -> MockPerson {
    var p = self
    p.email = address
    p.gmailAddress = address
    p.emailHint = Self.hint(address)
    if let at = address.firstIndex(of: "@") {
      p.outlookAddress = address[..<at] + ".k" + address[at...]
    } else {
      p.outlookAddress = address
    }
    return p
  }

  public static func hint(_ address: String) -> String {
    func masked(_ s: Substring) -> String {
      guard let first = s.first else { return "" }
      return String(first) + String(repeating: "\u{2022}", count: max(1, s.count - 1))
    }
    guard let at = address.firstIndex(of: "@") else { return masked(Substring(address)) }
    let domain = address[address.index(after: at)...]
    let dot = domain.firstIndex(of: ".") ?? domain.endIndex
    return masked(address[..<at]) + "@" + masked(domain[..<dot]) + domain[dot...]
  }

  public var profile: ProfileInfo {
    ProfileInfo(displayName: displayName, email: email, emailVerified: emailVerified, signIn: .passkey)
  }
}

public enum MayaWorst {
  public static let longestAddress =
    "first.last+billing-notifications-and-security-alerts-2026.uae.xy@hq.shared-services.accounts-payable-and-treasury-operations.dubai-international-financial-centre.northwind-industries-holdings-group.middle-east-and-north-africa-regional-office.example.com"

  public static let reviewCount = 1_284

  static func oct(_ d: Int, _ h: Int, _ m: Int) -> LocalDateTime { LocalDateTime(2026, 10, d, h, m) }

  static func edit(_ s: inout LedgerState, _ id: TxnID, _ change: (inout Txn) -> Void) {
    guard let i = s.txns.firstIndex(where: { $0.id == id }) else { return }
    let before = s.txns[i].merchant
    change(&s.txns[i])
    if s.txns[i].merchant != before {
      s.txns[i].merchantKey = s.txns[i].merchant.lowercased()
      s.txns[i].merchantGroup = "n:" + s.txns[i].merchant.lowercased()
    }
  }

  static func estimate(_ t: inout Txn, _ money: Money, home: Int64?, rateMicro: Int64? = nil) {
    t.amount = money
    t.homeMinor = home
    t.homeSource = home == nil ? nil : .rate
    t.homeRateMicro = home == nil ? nil : rateMicro
  }

  static func usd(_ minor: Int64) -> (Money, Int64?) {
    (Money(minor: minor, currency: "USD"), ExchangeRates.convert(minor, MayaBacklog.usdRateMicro))
  }

  static func row(
    _ id: String, _ merchant: String, _ amount: Money, _ at: LocalDateTime, account: AccountID = "dib",
    direction: Direction = .out, category: CategoryID? = nil, source: CategorySource? = .user,
    needsReview: Bool = false, suggestion: CategoryID? = nil, raw: String? = nil, place: String? = nil,
    note: String = "", projectID: ProjectID? = nil, billID: BillID? = nil, isRefund: Bool = false
  ) -> Txn {
    let bank = account == "enbd" ? MayaLedger.enbd : MayaLedger.dib
    return MayaLedger.keyed(
      Txn(
        id: id, merchant: merchant, place: place, amount: amount, direction: direction, postedAt: at, accountID: account,
        categoryID: needsReview ? nil : category, categorySource: needsReview ? nil : source, needsReview: needsReview,
        suggestion: suggestion, note: note, isRefund: isRefund, projectID: projectID, billID: billID,
        provenance: raw.map { MayaLedger.alert(bank, at.time, $0) }))
  }

  static func pad(_ n: Int) -> String {
    let digits = String(n)
    return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
  }

  struct Seeded {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
  }

  static let pool: [(name: String, raw: String, category: CategoryID, low: Int64, high: Int64)] = [
    ("Carrefour", "CARREFOUR MOE", "groceries", 40_00, 900_00),
    ("Lulu Hypermarket", "LULU HYPERMARKET AL BARSHA", "groceries", 30_00, 700_00),
    ("Spinneys", "SPINNEYS MARINA", "groceries", 25_00, 600_00),
    ("Waitrose", "WAITROSE DUBAI MALL", "groceries", 25_00, 650_00),
    ("Union Coop", "UNION COOP AL WARQA", "groceries", 20_00, 480_00),
    ("بقالة الخير", "ALKHAIR GROCERY", "groceries", 5_00, 90_00),
    ("Choithrams", "CHOITHRAMS JUMEIRAH", "groceries", 15_00, 320_00),
    ("Talabat", "TALABAT DUBAI", "dining", 18_00, 240_00),
    ("Deliveroo", "DELIVEROO AE", "dining", 22_00, 260_00),
    ("Starbucks", "STARBUCKS DIFC GATE", "dining", 14_00, 62_00),
    ("Tim Hortons", "TIM HORTONS JLT", "dining", 9_00, 48_00),
    ("مطعم الشرق الأوسط للمأكولات البحرية", "MIDDLE EAST SEAFOOD REST", "dining", 60_00, 640_00),
    ("Ravi Restaurant", "RAVI RESTAURANT SATWA", "dining", 18_00, 95_00),
    ("Zuma", "ZUMA DIFC", "dining", 300_00, 1_800_00),
    ("Shake Shack", "SHAKE SHACK MOE", "dining", 40_00, 140_00),
    ("Careem", "CAREEM HALA RIDE", "transport", 14_00, 140_00),
    ("Uber", "UBER *TRIP HELP.UBER.COM", "transport", 16_00, 160_00),
    ("ENOC", "ENOC 1043", "transport", 80_00, 260_00),
    ("ADNOC", "ADNOC 412 AL KHAIL", "transport", 80_00, 260_00),
    ("Salik", "SALIK RECHARGE", "transport", 50_00, 200_00),
    ("RTA Nol top-up", "(RTA) NOL TOP UP", "transport", 20_00, 100_00),
    ("Dubai Taxi", "DUBAI TAXI CORP", "transport", 12_00, 120_00),
    ("Aster Pharmacy", "ASTER PHARMACY 112", "healthcare", 18_00, 380_00),
    ("Life Pharmacy", "LIFE PHARMACY JBR", "healthcare", 15_00, 260_00),
    ("Mediclinic", "MEDICLINIC CITY HOSPITAL", "healthcare", 150_00, 2_400_00),
    ("Noon", "NOON.COM", "shopping", 25_00, 1_400_00),
    ("Amazon.ae", "AMAZON.AE*MARKETPLACE", "shopping", 20_00, 1_600_00),
    ("Namshi", "NAMSHI.COM", "shopping", 60_00, 900_00),
    ("IKEA", "IKEA FESTIVAL CITY", "shopping", 40_00, 3_200_00),
    ("Sharaf DG", "SHARAF DG MOE", "shopping", 80_00, 6_500_00),
    ("Ace Hardware", "ACE HARDWARE AL QUOZ", "shopping", 25_00, 450_00),
    ("Home Centre", "HOME CENTRE MIRDIF", "shopping", 40_00, 1_900_00),
    ("VOX Cinemas", "VOX CINEMAS MOE", "entertainment", 45_00, 260_00),
    ("Dubai Opera", "DUBAI OPERA", "entertainment", 250_00, 1_800_00),
    ("Coca-Cola Arena", "COCA-COLA ARENA", "entertainment", 150_00, 1_200_00),
    ("Steam", "STEAMPOWERED.COM", "entertainment", 18_00, 260_00),
    ("PlayStation Store", "PLAYSTATION NETWORK", "entertainment", 18_00, 330_00),
    ("flydubai", "FLYDUBAI.COM", "travel", 450_00, 3_800_00),
    ("Emirates", "EMIRATES.COM", "travel", 900_00, 9_500_00),
    ("Booking.com", "BOOKING.COM HOTEL", "travel", 300_00, 4_200_00),
    ("Netflix", "NETFLIX.COM", "subscriptions", 39_00, 69_00),
    ("Spotify", "SPOTIFY P2F3A1", "subscriptions", 21_99, 21_99),
    ("Anghami", "ANGHAMI PLUS", "subscriptions", 19_99, 19_99),
    ("Apple.com", "APPLE.COM/BILL", "subscriptions", 3_99, 49_99),
    ("du", "DU TELECOM", "utilities", 120_00, 520_00),
    ("Etisalat by e&", "ETISALAT E&", "utilities", 120_00, 620_00),
    ("DEWA", "DEWA SMART", "utilities", 280_00, 1_600_00),
    ("Empower", "EMPOWER DISTRICT COOLING", "utilities", 180_00, 900_00),
    ("أحمد بن سعيد للتجارة", "AHMED BIN SAEED TRADING", "shopping", 15_00, 420_00),
    ("مؤسسة عبد الرحمن بن عبد الله للتجارة العامة والمقاولات", "ABDULRAHMAN BIN ABDULLAH GEN TRD", "shopping", 50_00,
     2_200_00),
    ("Al Fardan Exchange", "AL FARDAN EXCHANGE DFC", "transfer", 500_00, 8_000_00),
    ("7-Eleven", "7-ELEVEN JLT", "groceries", 4_00, 60_00),
    ("Brightwell Academy", "BRIGHTWELL ACADEMY FZE", "kids-clubs", 150_00, 2_100_00),
  ]

  static func reviewRows(count: Int, prefix: String, seed: UInt64, startDay: LocalDate, days: Int) -> [Txn] {
    var r = Seeded(seed)
    return (0..<count).map { i in
      let p = pool[r.int(pool.count)]
      let day = startDay.adding(days: r.int(days))
      let hour = day == MayaLedger.now.date ? r.int(13) : r.int(24)
      let minor = p.low + Int64(r.int(Int(max(1, p.high - p.low))))
      let id = "\(prefix)-\(pad(i + 1))"
      let foreign = r.int(20)
      var t = row(
        id, p.name, .aed(minor), LocalDateTime(date: day, hour: hour, minute: r.int(60)),
        account: r.int(3) == 0 ? "enbd" : "dib", needsReview: true,
        suggestion: r.int(3) == 0 ? nil : p.category, raw: p.raw)
      if foreign == 0 {
        let (m, h) = usd(minor * 100 / 367)
        estimate(&t, m, home: h, rateMicro: MayaBacklog.usdRateMicro)
      } else if foreign == 1 {
        estimate(&t, Money(minor: minor * 2 / 5, currency: "JPY"), home: nil)
      } else if foreign == 2 {
        estimate(&t, Money(minor: minor * 10 / 12, currency: "KWD"), home: nil)
      }
      if r.int(9) == 0 { t.isNewMerchant = true }
      return t
    }
  }

  public static var worst: LedgerState {
    var s = MayaHistory.state
    s.profile = MockPerson.worst.profile
    s.mailbox = MailboxHealth(
      status: .working, lastEmail: "on 12 Sep 2025", banks: "Emirates NBD, DIB, ADCB, FAB, Mashreq and RAKBANK",
      unreadable: 1_284)
    s.unreadMail = [
      UnreadMail(id: "unread-adcb-old", provider: .gmail, receivedOn: LocalDate(2025, 12, 14), bank: "Abu Dhabi Commercial Bank"),
      UnreadMail(id: "unread-adcb", provider: .outlook, receivedOn: LocalDate(2026, 10, 9), bank: "Abu Dhabi Commercial Bank"),
    ]
    s.netWorth = NetWorthHistory(monthChange: .aed(-1_234_567_89), spark: [743, 686, 529, 557, 400, 429, 300, 329, 200, 229, 0])

    s.categories = s.categories.map { c in
      var c = c
      if c.id == "emergency-fund" { c.name = "Emergency fund – 6 mo" }
      return c
    }
    s.categories += [
      Category(id: "kids-clubs", name: "Kids' after-school clubs", bucket: .needs, glyph: .tag),
      Category(id: "school-ar", name: "مصاريف المدرسة والأنشطة", bucket: .needs, glyph: .tag),
      Category(id: "dewa-du", name: "DEWA & du", bucket: .needs, glyph: .utilities, role: .bill),
      Category(id: "coffee", name: "Coffee ☕️ & karak", bucket: .wants, glyph: .dining),
      Category(id: "go", name: "Go", bucket: .wants, glyph: .tag),
      Category(id: "home-ar", name: "مصاريف البيت 🏠", bucket: .needs, glyph: .tag, archived: true),
    ]

    s.accounts = [
      Account(id: "enbd", name: "Emirates NBD Platinum Credit Card Supplementary", shortName: "Emirates NBD Visa Infinite Credit",
              last4: "4412", kind: .current, balance: .aed(1_284_507_25),
              detail: "checked on 12 Sep 2025 · 1,284 since"),
      Account(id: "dib", name: "Dubai Islamic Bank Credit Card", shortName: "RAKBANK", last4: "0042", kind: .credit,
              balance: .aed(-1_234_567_89), detail: "statement due Sun 18 Oct"),
      Account(id: "cash", name: "wio Personal", shortName: "wio", kind: .cash, balance: .aed(1), detail: ""),
      Account(id: "sarwa", name: "First Abu Dhabi Bank Investment Portfolio", shortName: "First Abu Dhabi Bank",
              kind: .investment, balance: .aed(12_345_678_90), inPlan: false, detail: "Net worth only · updated 1 Oct"),
      Account(id: "sib", name: "مصرف الشارقة الإسلامي", shortName: "مصرف الشارقة الإسلامي", kind: .current,
              balance: .aed(0)),
    ]

    edit(&s, "talabat") {
      $0.merchant = "مطعم الشرق الأوسط للمأكولات البحرية"
      $0.amount = .aed(1)
      $0.provenance = MayaLedger.alert(MayaLedger.dib, "13:20", "MIDDLE EAST SEAFOOD REST")
    }
    edit(&s, "starbucks") {
      $0.merchant = "AMAZON.AE*MARKETPLACE-PAYMENTS-AE7Q2LX"
      $0.place = nil
      $0.provenance = MayaLedger.alert(MayaLedger.dib, "09:05", "AMAZON.AE*MARKETPLACE-PAYMENTS-AE7Q2LX")
    }
    edit(&s, "steam") {
      $0.merchant = "مطعم ومطبخ الفريج الشعبي"
      $0.place = "البرشاء"
      estimate(&$0, Money(minor: 12_500, currency: "KWD"), home: nil)
      $0.provenance = MayaLedger.alert(MayaLedger.dib, "11:02", "AMAZONMKTPLACEAE*2K4LP0QZ3AMZN.COM/BILLWA")
    }
    edit(&s, "dubai-taxi") {
      $0.merchant = "*Talabat"
      estimate(&$0, Money(minor: 1_500, currency: "JPY"), home: 36_75, rateMicro: 24_500)
    }
    edit(&s, "lulu") {
      $0.merchant = "Lulu Hypermarket Dubai Marina Mall Branch"
      $0.place = "Dubai Marina"
      $0.provenance = MayaLedger.alert(MayaLedger.dib, "18:42", "AMAZONMKTPLACEAE*2K4LP0QZ3AMZN.COM/BILLWA")
    }
    edit(&s, "careem") { $0.merchant = "Jo" }
    edit(&s, "carrefour") {
      $0.merchant = "Carrefour Hypermarket"
      $0.place = "Mall of the Emirates Al Barsha"
    }
    edit(&s, "vox") { $0.merchant = "(Rakuten) Viki" }
    edit(&s, "apple") {
      $0.merchant = "7-Eleven"
      $0.suggestion = "groceries"
    }
    edit(&s, "zuma") { $0.merchant = "مطعم الأمير للمشويات" }
    edit(&s, "noon") {
      $0.merchant = "Café Bateel"
      $0.categoryID = "coffee"
      $0.note = String(
        repeating: "Bought gift boxes for the office Diwali and Eid exchange, ask finance for reimbursement. ", count: 6)
        .prefix(500).description
    }
    edit(&s, "transfer-in") {
      $0.merchant = "Transfer from Emaar Properties PJSC ···0000"
      $0.amount = .aed(1_284_507_25)
    }
    edit(&s, "atm") { $0.merchant = "أحمد بن سعيد للتجارة" }
    edit(&s, "waitrose") { $0.merchant = "CARREFOUR HYPERMARKET MALL OF THE EMIRATES" }
    edit(&s, "common-grounds") {
      $0.note =
        "Split with Aleksandra and Konstantin; they owe me for the birthday cake.\nPaid in full, ask for 120 each by Thursday."
    }
    edit(&s, "ikea") {
      $0.merchant = "Dubai Electricity and Water Authority (DEWA) Smart Payment Kiosk"
      $0.categoryID = "dewa-du"
    }
    edit(&s, "aster") {
      $0.merchant = "The Avenues Kuwait"
      estimate(&$0, Money(minor: 12_345, currency: "KWD"), home: 147_43, rateMicro: 11_942_000)
    }
    edit(&s, "enoc") { $0.merchant = "(RTA) NOL TOP UP" }
    edit(&s, "spinneys") {
      $0.merchant = "Lulu Hypermarket Muscat"
      estimate(&$0, Money(minor: 4_750, currency: "OMR"), home: nil)
    }
    edit(&s, "talabat-3") {
      $0.merchant = "Ichiran Shibuya"
      let (m, h) = usd(45_99)
      estimate(&$0, m, home: h, rateMicro: MayaBacklog.usdRateMicro)
    }
    edit(&s, "rent") { $0.amount = .aed(127_450_00) }
    edit(&s, "spotify") {
      $0.merchant = "Shahid VIP"
      estimate(&$0, Money(minor: 7_500, currency: "KWD"), home: 89_47, rateMicro: 11_929_000)
    }
    edit(&s, "netflix") {
      let (m, h) = usd(9_99)
      estimate(&$0, m, home: h, rateMicro: MayaBacklog.usdRateMicro)
    }
    edit(&s, "emirates") { $0.note = "" }

    let split = [
      SplitLine(id: 1, categoryID: "groceries", amount: .aed(12_345_67)),
      SplitLine(id: 2, categoryID: "kids-clubs", amount: .aed(1)),
      SplitLine(id: 3, categoryID: "school-ar", amount: .aed(120_00),
                note: "Uniforms for the new term: two shirts, one PE kit and the winter jumper; ask about the sibling discount."),
      SplitLine(id: 4, categoryID: "coffee", amount: .aed(134_32)),
    ]
    var splitRow = row("w-split", "Carrefour Hypermarket", .aed(12_600_00), oct(5, 19, 0), account: "enbd",
                       category: "groceries", raw: "CARREFOUR CITY CENTRE MIRDIF", place: "City Centre Mirdif")
    splitRow.splits = split

    s.txns += [
      splitRow,
      row("w-blank", "", .aed(64_00), oct(3, 9, 15), needsReview: true, raw: ""),
      row("w-carrefour-2025", "Carrefour Hypermarket", .aed(288_60), LocalDateTime(2025, 10, 8, 12, 0), account: "enbd",
          category: "groceries", raw: "CARREFOUR MOE"),
      row("w-carrefour-2026", "Carrefour Hypermarket", .aed(301_15), oct(8, 12, 0), account: "enbd", category: "groceries",
          raw: "CARREFOUR MOE"),
      row("w-kids-sep", "Brightwell Academy After-School", .aed(15_00), LocalDateTime(2026, 9, 15, 16, 0),
          category: "kids-clubs", raw: "BRIGHTWELL ACADEMY FZE"),
      row("w-kids-oct", "Brightwell Academy After-School", .aed(2_100_00), oct(4, 16, 0), category: "kids-clubs",
          raw: "BRIGHTWELL ACADEMY FZE"),
      row("w-emergency", "Standing order", .aed(500_00), oct(2, 8, 10), account: "enbd", category: "emergency-fund"),
      row("w-move-hotel", "Rove Downtown", .aed(1_150_00), LocalDateTime(2026, 9, 20, 15, 0), category: "travel",
          raw: "ROVE DOWNTOWN", projectID: "move"),
      row("w-move-refund", "Rove Downtown", .aed(2_400_00), LocalDateTime(2026, 9, 27, 10, 0), direction: .in,
          category: "travel", raw: "ROVE DOWNTOWN REFUND", projectID: "move", isRefund: true),
      row("w-wedding", "Pearl Continental Lahore", .aed(3_250_00), LocalDateTime(2026, 9, 2, 11, 0), category: "travel",
          projectID: "wedding"),
      row("w-salalah", "Salam Air", .aed(1_740_00), LocalDateTime(2026, 9, 30, 9, 0), category: "travel",
          raw: "SALAMAIR", projectID: "salalah"),
      row("w-zero", "Careem", .aed(0), oct(9, 7, 30), category: "transport", raw: "CAREEM HALA RIDE"),
    ]
    let waiting = s.txns.filter(\.needsReview).count
    s.txns += reviewRows(
      count: max(0, reviewCount - waiting), prefix: "w-rev", seed: 1_284, startDay: LocalDate(2025, 8, 1),
      days: MayaLedger.now.date.ordinal - LocalDate(2025, 8, 1).ordinal + 1)

    s.bills = s.bills.map { b in
      var b = b
      switch b.id {
      case "axa": b.name = "شركة أبوظبي الوطنية للتأمين"
      case "dewa":
        b.name = "Dubai Electricity & Water Authority"
        b.categoryID = "dewa-du"
      case "du": b.name = "Etisalat by e& Home Internet and TV"
      case "salary":
        b.name = "Salary · Northwind Industries Holdings"
        b.amount = .aed(125_000_00)
      case "rent": b.name = "Rent · Al Habtoor Group Real Estate (Marina Heights Tower 2)"
      case "netflix": b.amount = Money(minor: 9_99, currency: "USD")
      case "spotify":
        b.name = "Shahid VIP"
        b.amount = Money(minor: 7_500, currency: "KWD")
      default: break
      }
      return b
    }
    s.bills.append(
      MayaLedger.filled(
        Bill(id: "school-bus", name: "Emirates Transport School Bus Fee Al Mizhar", kind: "School transport",
             categoryID: "kids-clubs", amount: .aed(1_050_00), usualDay: 7, nextDue: LocalDate(2026, 3, 7),
             accountID: "enbd", source: .manual)))
    s.billCandidates = [
      BillCandidate(id: "w-cand-apple", name: "APPLE.COM/BILL ITUNES.COM CORK IRL", categoryID: "subscriptions",
                    amount: .aed(14_99), seenCount: 5, everyDays: 30, last: LocalDate(2026, 10, 8)),
      BillCandidate(id: "w-cand-noon", name: "نون", categoryID: "shopping", amount: .aed(49_00), seenCount: 2,
                    everyDays: 30, last: LocalDate(2025, 9, 28)),
      BillCandidate(id: "w-cand-kwd", name: "The Avenues Kuwait Parking", categoryID: "transport",
                    amount: Money(minor: 2_500, currency: "KWD"), seenCount: 3, everyDays: 7, last: LocalDate(2026, 10, 6)),
    ]

    s.projects = [
      Project(id: "japan", name: "Hajj 2027 with my parents and in-laws – flights, hotel and visas", glyph: .travel,
              budget: .aed(12_000_00), starts: LocalDate(2026, 12, 14), ends: LocalDate(2026, 12, 28), startVerb: "flies"),
      Project(id: "japan-2", name: "Japan trip", glyph: .travel, budget: .aed(9_000_00), starts: LocalDate(2027, 3, 20),
              ends: LocalDate(2027, 4, 2), startVerb: "flies"),
      Project(id: "japan-3", name: "Japan trip", glyph: .travel, budget: nil, starts: nil, ends: nil),
      Project(id: "salalah", name: "رحلة العائلة إلى صلالة", glyph: .travel, budget: .aed(4_500_00),
              starts: LocalDate(2026, 10, 11), ends: LocalDate(2026, 10, 15)),
      Project(id: "move", name: "Move", glyph: .flag, budget: nil, starts: nil, ends: nil),
      Project(id: "wedding", name: "Wedding in Lahore — December 2029", glyph: .flag, budget: .aed(85_000_00),
              starts: LocalDate(2029, 10, 9), ends: LocalDate(2029, 12, 20)),
    ]
    s.goals = [
      Goal(id: "emergency", name: "Emergency fund – six months of rent and school fees", glyph: .savingsJar,
           categoryID: "emergency-fund", target: .aed(50_000_00), saved: .aed(55_000_00), by: YearMonth(2027, 1)),
      Goal(id: "car", name: "سيارة جديدة", glyph: .savingsJar, categoryID: "savings", target: .aed(80_000_00),
           saved: .aed(1), by: YearMonth(2028, 6)),
    ]
    s.rules = s.rules.map { r in
      var r = r
      if r.id == "r-careem" {
        r.patterns = [
          "CAREEM HALA RIDE DUBAI ARE", "CAREEM FOOD DUBAI", "CAREEM QUIK", "CAREEM PLUS SUBSCRIPTION",
          "UBER *TRIP HELP.UBER.COM", "UBER *EATS", "CAREEM NOW DXB", "CAREEM BIKE",
        ]
      }
      if r.id == "r-carrefour" {
        r.patterns = [
          "CARREFOUR", "CARREFOUR CITY", "CARREFOUR MARKET", "MAF CARREFOUR", "CRF HYPER", "CARREFOUR EXPRESS",
          "CARREFOUR ONLINE", "MY CLUB CARREFOUR",
        ]
        r.match = .exact
      }
      return r
    }
    s.rules += [
      Rule(id: "r-arabic", patterns: ["مواصلات الإمارات"], categoryID: "transport"),
      Rule(id: "r-z", patterns: ["Z"], match: .startsWith, categoryID: "go"),
    ]

    for (key, minor) in [
      ("shopping", 0), ("kids-clubs", 0), ("rent", 25_000_00), ("groceries", 2_200_00), ("dining", 300_00),
      ("savings", 0), ("investments", 0), ("travel", 0), ("entertainment", 0),
    ] as [(String, Int64)] {
      s.plan.budgets[PlanState.key(key, MayaLedger.october)] = .aed(minor)
    }
    s.plan.incomeByMonth[MayaLedger.october] = .aed(9_000_00)
    MockReach.refresh(&s)
    return s
  }

  public static var empty: LedgerState {
    var s = MayaLedger.state
    s.categories = s.categories.filter(\.builtin)
    s.accounts = []
    s.txns = []
    s.bills = []
    s.billCandidates = []
    s.projects = []
    s.goals = []
    s.rules = []
    s.plan = PlanState(income: .aed(0), payday: 28, startingSplit: [50, 30, 20], budgets: [:])
    s.mailbox = MailboxHealth(status: .working, lastEmail: "", banks: "")
    s.netWorth = NetWorthHistory()
    return s
  }

  public static var one: LedgerState {
    var s = empty
    s.profile = MockPerson.one.profile
    s.categories.append(Category(id: "gym", name: "Gym", bucket: .wants, glyph: .tag))
    s.accounts = [Account(id: "cash", name: "Cash", shortName: "Cash", kind: .cash, balance: .aed(1), detail: "Updated by you")]
    s.txns = [
      row("one-spinneys", "Spinneys", .aed(1), oct(10, 9, 5), account: "cash", needsReview: true,
          suggestion: "groceries", raw: "SPINNEYS MARINA")
    ]
    s.bills = [
      MayaLedger.filled(
        Bill(id: "dewa", name: "DEWA", kind: "Electricity & water", categoryID: "utilities", amount: .aed(489_15),
             usualDay: 9, nextDue: LocalDate(2026, 10, 9), accountID: "cash", history: [LocalDate(2026, 9, 9)]))
    ]
    s.billCandidates = [
      BillCandidate(id: "one-cand", name: "Apple.com/bill", categoryID: "subscriptions", amount: .aed(14_99),
                    seenCount: 2, everyDays: 30, last: LocalDate(2026, 10, 8))
    ]
    s.projects = [
      Project(id: "eid", name: "Eid", glyph: .flag, budget: .aed(1_000_00), starts: LocalDate(2026, 10, 11),
              ends: LocalDate(2026, 10, 13))
    ]
    s.goals = [
      Goal(id: "emergency", name: "Emergency fund", glyph: .savingsJar, categoryID: "savings", target: .aed(50_000_00),
           saved: .aed(1), by: YearMonth(2027, 1))
    ]
    s.rules = [Rule(id: "r-spinneys", patterns: ["spinneys"], categoryID: "groceries")]
    s.plan = PlanState(
      income: .aed(25_000_00), payday: 28, startingSplit: [50, 30, 20],
      budgets: [PlanState.key("groceries", MayaLedger.october): .aed(2_200_00)])
    s.mailbox = MailboxHealth(status: .working, lastEmail: "1 min ago", banks: "DIB", unreadable: 1)
    s.unreadMail = [UnreadMail(id: "one-unread", provider: .gmail, receivedOn: LocalDate(2026, 10, 9), bank: "DIB")]
    s.netWorth = NetWorthHistory(monthChange: .aed(1), spark: [0, 1000])
    MockReach.refresh(&s)
    return s
  }

  public static let hugeTxnCount = 2_500
  public static let hugeReviewCount = 300

  static let billNames: [(String, String, CategoryID, Int64)] = [
    ("Anghami Plus", "Music", "subscriptions", 19_99), ("OSN+", "Streaming", "subscriptions", 35_00),
    ("Shahid VIP", "Streaming", "subscriptions", 25_00), ("YouTube Premium", "Streaming", "subscriptions", 23_99),
    ("iCloud+ 2 TB", "Storage", "subscriptions", 39_99), ("Disney+", "Streaming", "subscriptions", 29_99),
    ("Amazon Prime", "Shopping", "subscriptions", 16_00), ("Careem Plus", "Delivery", "subscriptions", 19_00),
    ("talabat pro", "Delivery", "subscriptions", 25_00), ("noon One", "Shopping", "subscriptions", 25_00),
    ("Fitness First", "Gym", "healthcare", 450_00), ("Gold's Gym", "Gym", "healthcare", 299_00),
    ("Etisalat Postpaid", "Mobile", "utilities", 225_00), ("Virgin Mobile", "Mobile", "utilities", 99_00),
    ("Empower District Cooling", "Cooling", "utilities", 610_00), ("Lootah BCGas", "Gas", "utilities", 85_00),
    ("Nol card auto top-up", "Transport", "transport", 100_00), ("Salik auto top-up", "Tolls", "transport", 200_00),
    ("School fees · GEMS Wellington", "School", "kids-0", 6_250_00), ("Nursery · Blossom", "School", "kids-0", 3_100_00),
    ("Maid agency · Tadbeer", "Household", "rent", 2_800_00), ("Car loan · Emirates NBD", "Loan", "transport", 2_450_00),
    ("Home insurance · Sukoon", "Insurance", "insurance", 95_00), ("Health insurance · Daman", "Insurance", "insurance", 820_00),
    ("Life insurance · MetLife", "Insurance", "insurance", 310_00), ("Storage unit · Sentinel", "Storage", "rent", 540_00),
    ("Parking · Marina Heights", "Parking", "transport", 350_00), ("Microsoft 365", "Software", "subscriptions", 36_99),
    ("Adobe Creative Cloud", "Software", "subscriptions", 138_01), ("Notion Plus", "Software", "subscriptions", 36_00),
    ("Tabby instalment · Sharaf DG", "Instalment", "shopping", 412_25),
  ]

  public static var huge: LedgerState {
    var s = MayaHistory.state
    s.profile = MockPerson.huge.profile
    var r = Seeded(2_500)

    let customActive = 20 - s.categories.filter { !$0.builtin && !$0.archived }.count
    let names = [
      "Kids school & activities", "School runs", "Nanny", "Pets", "Vet", "Gifts", "Charity · Zakat", "Hair & beauty",
      "Laundry", "Home repairs", "Gardening", "Books", "Courses", "Photography", "Cycling", "Padel", "Golf", "Family support",
      "Remittance home", "Visa & Emirates ID", "Car service", "Parking fines", "Wedding", "Ramadan", "Eid gifts",
      "Coffee", "Snacks", "Office lunches", "Baby", "Toys", "Furniture", "Electronics", "Phone repairs", "Clothes",
      "Shoes", "Perfume", "Jewellery", "Camping", "Diving", "Hotel stays", "Desert safari",
    ]
    for (i, name) in names.enumerated() {
      s.categories.append(
        Category(id: "kids-\(i)", name: name,
                 bucket: i % 3 == 2 ? .wants : .needs, glyph: .tag, archived: i >= customActive))
    }

    let extraAccounts: [(String, String, AccountKind)] = [
      ("Mashreq Neo", "Mashreq", .current), ("ADCB TouchPoints Infinite", "ADCB card", .credit),
      ("FAB Cashback Card", "FAB card", .credit), ("wio Personal", "wio", .current),
      ("Liv. by Emirates NBD", "Liv", .current), ("RAKBANK Titanium", "RAKBANK", .credit),
      ("Emirates Islamic Savings", "Emirates Islamic", .current), ("Interactive Brokers", "IBKR", .investment),
    ]
    for (i, a) in extraAccounts.enumerated() {
      s.accounts.append(
        Account(id: "acc-\(i)", name: a.0, shortName: a.1, last4: pad(1_000 + i * 731 % 9_000),
                kind: a.2, balance: .aed(Int64(r.int(9_000_000_00)) - (a.2 == .credit ? 9_000_000_00 : 0)),
                inPlan: a.2 != .investment, detail: "checked in \(i + 1) days ago"))
    }

    let reviewWaiting = s.txns.filter(\.needsReview).count
    let reviewRowsCount = max(0, hugeReviewCount - reviewWaiting)
    let filedCount = max(0, hugeTxnCount - s.txns.count - reviewRowsCount)
    let start = LocalDate(2025, 10, 1)
    let span = MayaLedger.now.date.ordinal - start.ordinal + 1
    var filed: [Txn] = []
    for i in 0..<filedCount {
      let p = pool[r.int(pool.count)]
      let day = start.adding(days: r.int(span))
      let hour = day == MayaLedger.now.date ? r.int(13) : r.int(24)
      let minor = p.low + Int64(r.int(Int(max(1, p.high - p.low))))
      let category = p.category == "kids-clubs" ? "kids-0" : p.category
      var t = row(
        "hg-\(pad(i + 1))", p.name, .aed(minor), LocalDateTime(date: day, hour: hour, minute: r.int(60)),
        account: ["enbd", "dib", "acc-0", "acc-1", "acc-2"][r.int(5)], category: category,
        source: [.user, .dictionary, .rule(pattern: p.raw.lowercased())][r.int(3)], raw: p.raw)
      if category == "transfer" { t.isTransfer = true }
      filed.append(t)
    }
    s.txns += filed
    s.txns += reviewRows(count: reviewRowsCount, prefix: "hg-rev", seed: 300, startDay: start, days: span).map { t in
      var t = t
      if t.suggestion == "kids-clubs" { t.suggestion = "kids-0" }
      return t
    }

    for (i, b) in billNames.enumerated() {
      let day = 1 + (i * 7) % 28
      let due = day < 10 ? LocalDate(2026, 11, day) : LocalDate(2026, 10, day)
      s.bills.append(
        MayaLedger.filled(
          Bill(id: "hg-bill-\(i)", name: b.0, kind: b.1, categoryID: b.2, amount: .aed(b.3), usualDay: day,
               nextDue: i % 9 == 4 ? LocalDate(2026, 10, max(1, day % 9)) : due,
               accountID: i % 2 == 0 ? "enbd" : "dib", source: i % 4 == 0 ? .manual : .detected)))
    }
    s.billCandidates += (0..<30).map { i in
      let p = pool[(i * 7) % pool.count]
      return BillCandidate(
        id: "hg-cand-\(i)", name: p.name, categoryID: p.category == "kids-clubs" ? "kids-0" : p.category,
        amount: .aed(p.low), seenCount: 2 + i % 9, everyDays: [7, 14, 30, 30, 90][i % 5],
        last: MayaLedger.now.date.adding(days: -(i * 11)))
    }
    let places = [
      "Abu Dhabi weekend", "Hatta glamping", "Muscat road trip", "Baku", "Tbilisi", "Istanbul", "London", "Kerala",
      "Colombo", "Bali", "Kitchen refit", "Ramadan", "Eid al-Adha", "Summer camp", "New sofa", "Car service",
      "Moving flat", "Dad's 60th", "Sara's wedding", "Graduation", "Diwali", "Christmas", "Dubai Run", "Padel league",
      "Hajj savings", "Umrah", "Lisbon", "Cape Town", "Zanzibar", "Seychelles", "Maldives", "Vienna", "Prague",
      "Seoul", "Osaka", "Taipei", "Hanoi", "Kathmandu", "Nairobi", "Amman", "Beirut",
    ]
    for (i, name) in places.prefix(41).enumerated() {
      let complete = i >= 11
      let starts = complete ? LocalDate(2024, 1, 1).adding(days: i * 19) : MayaLedger.now.date.adding(days: 5 + i * 23)
      s.projects.append(
        Project(id: "hg-proj-\(i)", name: name, glyph: i % 2 == 0 ? .travel : .flag,
                budget: i % 3 == 0 ? nil : .aed(Int64(1_000_00 + i * 750_00)), starts: starts, ends: starts.adding(days: 6),
                complete: complete, completedOn: complete ? starts.adding(days: 7) : nil))
    }
    let goalNames = [
      "House deposit", "New car", "Kids' university", "Wedding", "Hajj", "Retirement top-up", "Laptop", "Sabbatical",
      "Gold",
    ]
    for (i, name) in goalNames.enumerated() {
      s.goals.append(
        Goal(id: "hg-goal-\(i)", name: name, glyph: .savingsJar, categoryID: "savings",
             target: .aed(Int64(10_000_00 * (i + 1))), saved: .aed(Int64(r.int(10_000_00 * (i + 1)))),
             by: YearMonth(2027 + i % 4, 1 + i % 12)))
    }
    for i in 0..<(300 - s.rules.count) {
      let p = pool[i % pool.count]
      s.rules.append(
        Rule(id: "hg-rule-\(i)", patterns: [p.raw + (i < pool.count ? "" : " \(pad(i))")],
             match: [.contains, .startsWith, .exact][i % 3], categoryID: p.category == "kids-clubs" ? "kids-0" : p.category))
    }

    var budgets = s.plan.budgets
    for c in s.categories where c.kind == .spending && !c.archived {
      for m in 0..<13 {
        let ym = m < 3 ? YearMonth(2025, 10 + m) : YearMonth(2026, m - 2)
        if budgets[PlanState.key(c.id, ym)] == nil {
          budgets[PlanState.key(c.id, ym)] = .aed(Int64(100_00 + (c.name.count * 37_00)))
        }
      }
    }
    s.plan.budgets = budgets
    s.mailbox = MailboxHealth(
      status: .working, lastEmail: "just now",
      banks: "Emirates NBD, DIB, ADCB, FAB, Mashreq, RAKBANK, Emirates Islamic and wio", unreadable: 12_840)
    MockReach.refresh(&s)
    return s
  }
}
