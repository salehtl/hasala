import Foundation

struct Tally {
  var mails = 0
  var txnTrue = 0
  var txnTP = 0
  var txnFP = 0
  var txnFN = 0
  var amountRight = 0
  var amountWrong = 0
  var amountMissing = 0
  var currencyRight = 0
  var directionTotal = 0
  var directionRight = 0
  var directionWrong = 0
  var directionMissing = 0
  var merchantExact = 0
  var merchantClose = 0
  var merchantWrong = 0
  var merchantMissing = 0
  var merchantNoneRight = 0
  var merchantNoneWrong = 0
  var merchantTotal = 0
  var noneTotal = 0
  var confident = 0
  var confidentWrong = 0
  var confidentWrongMerchant = 0

  mutating func add(_ a: Tally) {
    mails += a.mails; txnTrue += a.txnTrue; txnTP += a.txnTP; txnFP += a.txnFP; txnFN += a.txnFN
    amountRight += a.amountRight; amountWrong += a.amountWrong; amountMissing += a.amountMissing
    currencyRight += a.currencyRight; directionTotal += a.directionTotal; directionRight += a.directionRight
    directionWrong += a.directionWrong; directionMissing += a.directionMissing; merchantExact += a.merchantExact; merchantClose += a.merchantClose
    merchantWrong += a.merchantWrong; merchantMissing += a.merchantMissing; merchantNoneRight += a.merchantNoneRight
    merchantNoneWrong += a.merchantNoneWrong; merchantTotal += a.merchantTotal; noneTotal += a.noneTotal
    confident += a.confident; confidentWrong += a.confidentWrong; confidentWrongMerchant += a.confidentWrongMerchant
  }
}

struct Miss: Encodable {
  var reader: String
  var kind: String
  var id: String
  var problem: String
  var got: String
  var want: String
  var note: String
}

enum Score {
  static func norm(_ s: String) -> String {
    let up = s.uppercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
    return String(up).split(separator: " ").joined(separator: " ")
  }

  static func merchantClose(_ a: String, _ b: String) -> Bool {
    let x = norm(a), y = norm(b)
    if x.isEmpty || y.isEmpty { return false }
    if x.contains(y) || y.contains(x) { return true }
    let s = Set(x.split(separator: " ")), t = Set(y.split(separator: " "))
    return Double(s.intersection(t).count) / Double(s.union(t).count) >= 0.5
  }

  static func add(_ r: Reading, _ t: Truth, into a: inout Tally, misses: inout [Miss], reader: String, kind: String, id: String) {
    a.mails += 1
    func miss(_ p: String, _ got: String, _ want: String) {
      misses.append(Miss(reader: reader, kind: kind, id: id, problem: p, got: got, want: want, note: r.note))
    }
    let confident = r.isTransaction && r.confidence >= 0.8
    if confident { a.confident += 1 }
    var wrong = false
    var wrongMerchant = false
    if t.isTransaction { a.txnTrue += 1 }
    switch (t.isTransaction, r.isTransaction) {
    case (true, true): a.txnTP += 1
    case (false, true):
      a.txnFP += 1
      wrong = true
      miss("not_a_transaction", "\(r.amountMinor ?? -1) \(r.currency ?? "")", "none")
    case (true, false):
      a.txnFN += 1
      miss("missed_transaction", "none", "\(t.amountMinor ?? -1) \(t.currency ?? "")")
    default: break
    }
    if t.isTransaction && r.isTransaction {
      if r.amountMinor == nil {
        a.amountMissing += 1
        miss("amount_missing", "nil", "\(t.amountMinor ?? -1)")
      } else if r.amountMinor == t.amountMinor {
        a.amountRight += 1
      } else {
        a.amountWrong += 1
        wrong = true
        miss("amount_wrong", "\(r.amountMinor!)", "\(t.amountMinor ?? -1)")
      }
      if r.currency == t.currency {
        a.currencyRight += 1
      } else {
        wrong = true
        miss("currency_wrong", r.currency ?? "nil", t.currency ?? "nil")
      }
      if let want = t.direction {
        a.directionTotal += 1
        if let got = r.direction {
          if got == want {
            a.directionRight += 1
          } else {
            a.directionWrong += 1
            wrong = true
            miss("direction_wrong", got, want)
          }
        } else {
          a.directionMissing += 1
          miss("direction_missing", "nil", want)
        }
      }
      if let want = t.merchant {
        a.merchantTotal += 1
        if let got = r.merchant {
          if norm(got) == norm(want) {
            a.merchantExact += 1
          } else if merchantClose(got, want) {
            a.merchantClose += 1
          } else {
            a.merchantWrong += 1
            wrongMerchant = true
            miss("merchant_wrong", got, want)
          }
        } else {
          a.merchantMissing += 1
          miss("merchant_missing", "nil", want)
        }
      } else {
        a.noneTotal += 1
        if let got = r.merchant {
          a.merchantNoneWrong += 1
          wrongMerchant = true
          miss("merchant_invented", got, "none")
        } else {
          a.merchantNoneRight += 1
        }
      }
    }
    if confident && wrong { a.confidentWrong += 1 }
    if confident && !wrong && wrongMerchant { a.confidentWrongMerchant += 1 }
  }
}
