import HasalaModels

public enum MayaHistory {
  public static var state: LedgerState {
    var s = MayaLedger.state
    s.txns += txns.map(MayaLedger.keyed)
    return s
  }

  public static let firstDaysNow = LocalDateTime(2026, 10, 3, 11, 20)

  public static var firstDays: LedgerState {
    var s = MayaLedger.state
    s.accounts = []
    s.netWorth = NetWorthHistory()
    s.bills = []
    s.billCandidates = []
    s.txns = [
      Txn(id: "fd-spinneys", merchant: "Spinneys", amount: .aed(338_50), postedAt: LocalDateTime(2026, 10, 2, 18, 10),
          accountID: "enbd", categoryID: "groceries", categorySource: .dictionary),
      Txn(id: "fd-careem", merchant: "Careem", amount: .aed(74_00), postedAt: LocalDateTime(2026, 10, 2, 8, 40),
          accountID: "dib", categoryID: "transport", categorySource: .rule(pattern: "careem")),
      Txn(id: "fd-talabat", merchant: "Talabat", amount: .aed(74_25), postedAt: LocalDateTime(2026, 10, 3, 10, 5),
          accountID: "dib", categoryID: "dining", categorySource: .rule(pattern: "talabat")),
    ]
    return s
  }

  public static var suggested: [Txn] {
    func row(_ id: String, _ merchant: String, _ minor: Int64, _ day: Int, _ hour: Int, _ category: CategoryID,
             _ raw: String) -> Txn {
      Txn(id: id, merchant: merchant, amount: .aed(minor), postedAt: LocalDateTime(2026, 10, day, hour, 15),
          accountID: "dib", categorySource: .model(tag: "cf-clef/1"), needsReview: true, isNewMerchant: true,
          suggestion: category, provenance: MayaLedger.alert(MayaLedger.dib, "\(hour):15", raw))
    }
    return [
      row("sug-shake-9", "Shake Shack", 72_00, 9, 20, "dining", "SHAKE SHACK MOE"),
      row("sug-tim-8", "Tim Hortons", 18_50, 8, 8, "dining", "TIM HORTONS JLT"),
      row("sug-shake-4", "Shake Shack", 64_50, 4, 19, "dining", "SHAKE SHACK MOE"),
      row("sug-almaya-7", "Al Maya Supermarket", 96_40, 7, 18, "groceries", "AL MAYA SUPERMARKET"),
    ]
  }

  public static var rangeReview: [Txn] {
    var copy = h("talabat-8", "Talabat", 88_55, 8, 6, "dining", hour: 20)
    copy.id = "aug-talabat-copy"
    copy.postedAt.minute = 3
    copy.heldCopy = HeldCopy(of: "h-talabat-8", fromOtherInbox: true)
    return [
      Txn(id: "aug-corner-shop", merchant: "Corner Shop", amount: .aed(18_75),
          postedAt: LocalDateTime(2026, 8, 24, 18, 30), accountID: "dib"),
      Txn(id: "sep-steam", merchant: "Steam", amount: .aed(42_00), postedAt: LocalDateTime(2026, 9, 18, 22, 15),
          accountID: "dib", needsReview: true, suggestion: "entertainment", senderUnverified: true),
      copy,
    ]
  }

  static func h(_ id: String, _ merchant: String, _ minor: Int64, _ month: Int, _ day: Int, _ category: CategoryID,
                hour: Int = 12, account: AccountID = "dib", direction: Direction = .out) -> Txn {
    Txn(id: "h-\(id)", merchant: merchant, amount: .aed(minor), direction: direction,
        postedAt: LocalDateTime(2026, month, day, hour, 0), accountID: account, categoryID: category,
        categorySource: .user)
  }

  static func month(_ m: Int, rent: Int64, groceries: Int64, utilities: Int64, transport: Int64, dining: Int64,
                    shopping: Int64, entertainment: Int64, travel: Int64, freelance: Int64 = 0) -> [Txn] {
    var out = [
      h("rent-\(m)", "Al Habtoor", rent, m, 1, "rent", hour: 9, account: "enbd"),
      h("so-\(m)", "Standing order", 3_000_00, m, 2, "savings", hour: 8, account: "enbd"),
      h("sarwa-\(m)", "Sarwa", 2_000_00, m, 2, "investments", hour: 8, account: "enbd"),
      h("du-\(m)", "du", 389_00, m, 5, "utilities", hour: 9, account: "enbd"),
      h("dewa-\(m)", "DEWA", utilities - 389_00, m, 14, "utilities", hour: 9, account: "enbd"),
      h("spinneys-\(m)", "Spinneys", groceries / 2, m, 6, "groceries", account: "enbd"),
      h("waitrose-\(m)", "Waitrose", groceries - groceries / 2, m, 20, "groceries", account: "enbd"),
      h("enoc-\(m)", "ENOC", transport, m, 9, "transport"),
      h("tashas-\(m)", "Tashas", dining, m, 16, "dining"),
      h("noon-\(m)", "Noon", shopping, m, 12, "shopping", account: "enbd"),
      h("vox-\(m)", "VOX Cinemas", entertainment, m, 18, "entertainment"),
      h("netflix-\(m)", "Netflix", 56_00, m, 6, "subscriptions"),
      h("spotify-\(m)", "Spotify", 21_99, m, 8, "subscriptions"),
      h("osn-\(m)", "OSN+", 35_00, m, 10, "subscriptions"),
      h("adobe-\(m)", "Adobe", 138_01, m, 20, "subscriptions"),
      h("salary-\(m)", "Salary · Acme Gulf", 25_000_00, m, 28, "salary", hour: 9, account: "enbd", direction: .in),
    ]
    if travel > 0 { out.append(h("flydubai-\(m)", "flydubai", travel, m, 22, "travel")) }
    if freelance > 0 {
      out.append(h("freelance-\(m)", "Freelance · Studio Noor", freelance, m, 15, "freelance", account: "enbd",
                   direction: .in))
    }
    return out
  }

  public static let txns: [Txn] =
    month(4, rent: 7_500_00, groceries: 2_150_00, utilities: 820_00, transport: 1_250_00, dining: 1_700_00,
          shopping: 1_600_00, entertainment: 1_289_00, travel: 1_500_00)
    + month(5, rent: 7_500_00, groceries: 2_240_25, utilities: 905_00, transport: 1_310_00, dining: 1_820_00,
            shopping: 1_979_00, entertainment: 900_00, travel: 2_000_00)
    + month(6, rent: 7_500_00, groceries: 2_105_40, utilities: 1_180_00, transport: 1_295_00, dining: 1_649_00,
            shopping: 1_700_00, entertainment: 1_100_00, travel: 1_500_00, freelance: 1_500_00)
    + month(7, rent: 7_500_00, groceries: 2_310_43, utilities: 1_390_00, transport: 1_240_00, dining: 1_762_00,
            shopping: 1_850_00, entertainment: 1_400_00, travel: 2_000_00)
    + august + september

  static let august: [Txn] = [
    h("rent-8", "Al Habtoor", 7_500_00, 8, 1, "rent", hour: 9, account: "enbd"),
    h("so-8", "Standing order", 3_000_00, 8, 2, "savings", hour: 8, account: "enbd"),
    h("sarwa-8", "Sarwa", 2_000_00, 8, 2, "investments", hour: 8, account: "enbd"),
    h("vox-8", "VOX Cinemas", 110_00, 8, 2, "entertainment", hour: 21),
    h("enoc-8a", "ENOC", 180_00, 8, 4, "transport", hour: 8),
    h("du-8", "du", 389_00, 8, 5, "utilities", hour: 9, account: "enbd"),
    h("netflix-8", "Netflix", 56_00, 8, 6, "subscriptions", hour: 7),
    h("talabat-8", "Talabat", 88_55, 8, 6, "dining", hour: 20),
    h("spinneys-8a", "Spinneys", 702_40, 8, 8, "groceries", hour: 11, account: "enbd"),
    h("spotify-8", "Spotify", 21_99, 8, 8, "subscriptions", hour: 6),
    h("noon-8", "Noon", 410_60, 8, 9, "shopping", hour: 14, account: "enbd"),
    h("osn-8", "OSN+", 35_00, 8, 10, "subscriptions", hour: 7),
    h("flydubai-8", "flydubai", 1_222_50, 8, 11, "travel", hour: 10),
    h("dewa-8", "DEWA", 1_016_80, 8, 14, "utilities", hour: 9, account: "enbd"),
    h("salik-8", "Salik", 210_00, 8, 14, "transport", hour: 9),
    h("zuma-8", "Zuma", 520_00, 8, 15, "dining", hour: 21),
    h("spinneys-8b", "Spinneys", 640_25, 8, 16, "groceries", hour: 11, account: "enbd"),
    h("tashas-8", "Tashas", 654_00, 8, 19, "dining", hour: 13),
    h("enoc-8b", "ENOC", 175_40, 8, 20, "transport", hour: 8),
    h("adobe-8", "Adobe", 138_01, 8, 20, "subscriptions", hour: 6),
    h("opera-8", "Dubai Opera", 1_200_00, 8, 21, "entertainment", hour: 19),
    h("namshi-8", "Namshi", 1_238_00, 8, 22, "shopping", hour: 16),
    h("careem-8", "Careem", 738_25, 8, 23, "transport", hour: 22),
    h("waitrose-8", "Waitrose", 746_35, 8, 27, "groceries", hour: 18, account: "enbd"),
    h("salary-8", "Salary · Acme Gulf", 25_000_00, 8, 28, "salary", hour: 9, account: "enbd", direction: .in),
    h("pierchic-8", "Pierchic", 650_00, 8, 29, "dining", hour: 21),
    h("bounce-8", "Bounce", 640_00, 8, 30, "entertainment", hour: 15),
  ]

  static let september: [Txn] = [
    h("rent-9", "Al Habtoor", 7_500_00, 9, 1, "rent", hour: 9, account: "enbd"),
    h("so-9", "Standing order", 3_000_00, 9, 2, "savings", hour: 8, account: "enbd"),
    h("sarwa-9", "Sarwa", 2_000_00, 9, 2, "investments", hour: 8, account: "enbd"),
    h("enoc-9a", "ENOC", 172_00, 9, 3, "transport", hour: 8),
    h("starbucks-9a", "Starbucks", 27_00, 9, 3, "dining", hour: 9),
    h("vox-9a", "VOX Cinemas", 95_00, 9, 4, "entertainment", hour: 21),
    h("du-9", "du", 427_90, 9, 5, "utilities", hour: 9, account: "enbd"),
    h("spinneys-9a", "Spinneys", 312_45, 9, 5, "groceries", hour: 11, account: "enbd"),
    h("pierchic-9", "Pierchic", 300_00, 9, 5, "dining", hour: 21),
    h("noon-9", "Noon", 289_00, 9, 6, "shopping", hour: 14, account: "enbd"),
    h("netflix-9", "Netflix", 56_00, 9, 6, "subscriptions", hour: 7),
    h("talabat-9a", "Talabat", 81_50, 9, 7, "dining", hour: 20),
    h("careem-9a", "Careem", 64_50, 9, 8, "transport", hour: 23),
    h("spotify-9", "Spotify", 21_99, 9, 8, "subscriptions", hour: 6),
    h("waitrose-9a", "Waitrose", 268_90, 9, 9, "groceries", hour: 18, account: "enbd"),
    h("common-grounds-9a", "Common Grounds", 52_00, 9, 10, "dining", hour: 10),
    h("osn-9", "OSN+", 35_00, 9, 10, "subscriptions", hour: 7),
    h("opera-9", "Dubai Opera", 850_00, 9, 11, "entertainment", hour: 19),
    h("ikea-9", "IKEA", 640_00, 9, 12, "shopping", hour: 17, account: "enbd"),
    h("rta-9", "RTA Nol top-up", 100_00, 9, 12, "transport", hour: 8),
    h("tashas-9", "Tashas", 288_00, 9, 12, "dining", hour: 13),
    h("bounce-9", "Bounce", 437_50, 9, 13, "entertainment", hour: 15),
    h("dewa-9", "DEWA", 640_50, 9, 14, "utilities", hour: 9, account: "enbd"),
    h("salik-9", "Salik", 205_00, 9, 14, "transport", hour: 9),
    h("salik-9b", "Salik", 200_00, 9, 21, "transport", hour: 9),
    h("starbucks-9b", "Starbucks", 31_00, 9, 15, "dining", hour: 9),
    h("aster-clinic-9", "Aster Clinic", 380_00, 9, 16, "healthcare", hour: 11),
    h("enoc-9b", "ENOC", 168_25, 9, 17, "transport", hour: 8),
    h("talabat-9b", "Talabat", 102_00, 9, 17, "dining", hour: 20),
    h("namshi-9", "Namshi", 451_00, 9, 19, "shopping", hour: 16),
    h("vox-9b", "VOX Cinemas", 110_00, 9, 19, "entertainment", hour: 21),
    h("spinneys-9b", "Spinneys", 455_10, 9, 20, "groceries", hour: 11, account: "enbd"),
    h("talabat-9c", "Talabat", 69_45, 9, 20, "dining", hour: 20),
    h("adobe-9", "Adobe", 138_01, 9, 20, "subscriptions", hour: 6),
    h("starbucks-9c", "Starbucks", 29_00, 9, 22, "dining", hour: 9),
    h("aster-9", "Aster Pharmacy", 75_00, 9, 22, "healthcare", hour: 12),
    h("enoc-9c", "ENOC", 200_00, 9, 24, "transport", hour: 8),
    h("common-grounds-9b", "Common Grounds", 46_00, 9, 24, "dining", hour: 10),
    h("careem-9b", "Careem", 58_00, 9, 25, "transport", hour: 23),
    h("petal-lane-9", "Petal Lane Florist", 220_00, 9, 25, "shopping", hour: 17),
    h("zuma-9", "Zuma", 386_00, 9, 26, "dining", hour: 21),
    h("coca-cola-arena-9", "Coca-Cola Arena", 690_00, 9, 26, "entertainment", hour: 19),
    h("amazon-9", "Amazon.ae", 312_40, 9, 28, "shopping", hour: 12),
    h("salary-9", "Salary · Acme Gulf", 25_000_00, 9, 28, "salary", hour: 9, account: "enbd", direction: .in),
    h("talabat-9d", "Talabat", 74_25, 9, 29, "dining", hour: 20),
    h("waitrose-9b", "Waitrose", 488_10, 9, 29, "groceries", hour: 18, account: "enbd"),
    h("enoc-9d", "ENOC", 175_00, 9, 30, "transport", hour: 8),
  ]
}
