public extension MoneyFormat {
  static func count(_ n: Int) -> String {
    (n < 0 ? "-" : "") + grouped(UInt64(n.magnitude))
  }
}

public enum Bidi {
  public static func isolate(_ s: String) -> String { "\u{2068}" + s + "\u{2069}" }
}
