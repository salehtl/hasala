// lint-allow: Double JSON.stringify writes a JavaScript Number, which IS an IEEE-754 double; this file reproduces that rendering for the writer's `.javascript` style and is never on a money path (money is a decimal string, spec 03c §1.3).
//
// ECMAScript `Number::toString(x)` (ECMA-262 §6.1.6.1.20), as JSON.stringify
// applies it to a finite number. The shortest round-tripping digits come from
// Swift's `Double.description` (shortest, closest: the same digits ECMAScript
// requires); only the layout is ECMAScript's:
//
//   k ≤ n ≤ 21    digits, then n-k zeros            100, 123456789012345680000
//   0 < n ≤ 21    digits with a point after n       1.5, 123.456
//   -6 < n ≤ 0    "0." then -n zeros, then digits   0.001, 0.000001
//   otherwise     d[.ddd]e±(n-1)                    1e+21, 1.5e-7
//
// where the value is 0.digits × 10^n and k is the digit count.
public enum JSNumber {
  /// The text JSON.stringify writes for the number `literal` denotes:
  /// `null` for a literal that overflows a double (JSON.stringify(Infinity)).
  public static func stringify(literal: String) -> String {
    guard let d = Double(literal), d.isFinite else { return "null" }
    return format(d)
  }

  /// `Number::toString` of a finite double. Zero (either sign) is `"0"`.
  public static func format(_ d: Double) -> String {
    precondition(d.isFinite, "JSNumber.format takes a finite double")
    if d == 0 { return "0" }
    let (digits, n) = shortestDigits(d.magnitude)
    let k = digits.count
    let sign = d < 0 ? "-" : ""
    let body: String
    if k <= n && n <= 21 {
      body = digits + String(repeating: "0", count: n - k)
    } else if 0 < n && n <= 21 {
      let cut = digits.index(digits.startIndex, offsetBy: n)
      body = String(digits[..<cut]) + "." + String(digits[cut...])
    } else if -6 < n && n <= 0 {
      body = "0." + String(repeating: "0", count: -n) + digits
    } else {
      let e = n - 1
      let exp = e < 0 ? "-\(-e)" : "+\(e)"
      let head = digits.prefix(1)
      let tail = digits.dropFirst()
      body = tail.isEmpty ? "\(head)e\(exp)" : "\(head).\(tail)e\(exp)"
    }
    return sign + body
  }

  /// The shortest decimal digit string `s` (no leading or trailing zeros) and
  /// exponent `n` with `x = 0.s × 10^n`, read off Swift's shortest
  /// representation, whatever layout Swift chose for it.
  static func shortestDigits(_ x: Double) -> (String, Int) {
    let text = Array(x.description.utf8)  // e.g. "1.0", "1e-07", "1.2345e+20", "5e-324"
    var mantissa = text[...]
    var exponent = 0
    if let e = text.firstIndex(where: { $0 == 0x65 || $0 == 0x45 }) {
      mantissa = text[..<e]
      var expDigits = text[(e + 1)...]
      var negative = false
      if let f = expDigits.first, f == 0x2b || f == 0x2d {
        negative = f == 0x2d
        expDigits = expDigits.dropFirst()
      }
      for c in expDigits { exponent = exponent * 10 + Int(c - 0x30) }
      if negative { exponent = -exponent }
    }
    var digits: [UInt8] = []
    var point = 0
    var seenPoint = false
    for c in mantissa {
      if c == 0x2e {
        seenPoint = true
        continue
      }
      digits.append(c)
      if !seenPoint { point += 1 }
    }
    while let f = digits.first, f == 0x30 {
      digits.removeFirst()
      point -= 1
    }
    while let l = digits.last, l == 0x30 { digits.removeLast() }
    return (String(decoding: digits, as: UTF8.self), point + exponent)
  }
}
