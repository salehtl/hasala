import CoreTemplate
import Foundation

public enum BankTextSenderKind: String, Sendable, Codable, CaseIterable {
  case bank
  case person
  case unknown
  case none
}

public struct BankTextSender: Sendable, Equatable {
  public let kind: BankTextSenderKind
  public let bank: String?
  let id: String

  init(kind: BankTextSenderKind, bank: String?, id: String) {
    self.kind = kind
    self.bank = bank
    self.id = id
  }

  var layoutKey: String { kind == .bank ? "sms:" + id : "sms:" }
  var learns: Bool { kind == .bank || kind == .none }
}

public enum BankTextSenders {
  public static let knownBankSenders: [(sender: String, bank: String)] = [
    ("EmiratesNBD", "enbd"), ("ENBD", "enbd"), ("ADIB", "adib"), ("ADIBAlerts", "adib"), ("ADCBAlert", "adcb"), ("ADCB", "adcb"),
    ("FAB", "fab"), ("FABBank", "fab"), ("Mashreq", "mashreq"), ("MashreqBank", "mashreq"), ("RAKBANK", "rakbank"),
    ("CBD", "cbd"), ("EIB", "ei"), ("EI-Alert", "ei"), ("HSBC", "hsbc"), ("Citibank", "citi"), ("NBF", "nbf"), ("SIB", "sib"),
    ("AjmanBank", "ajman_bank"), ("UAB", "uab"), ("Liv", "liv"), ("WioBank", "wio"), ("Wio", "wio"), ("AlHilalBank", "alhilal"),
  ]

  public static func bankSenders(templates: [CompiledTemplate]) -> [String: String] {
    var out: [String: String] = [:]
    for (s, b) in knownBankSenders { out[fold(s)] = b }
    for t in templates where t.definition.isSMS {
      for s in t.definition.match.smsSender where !fold(s).isEmpty { out[fold(s)] = t.definition.bank }
    }
    return out
  }

  public static func classify(_ sender: String?, banks: [String: String]) -> BankTextSender {
    let raw = (sender ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return BankTextSender(kind: .none, bank: nil, id: "") }
    let id = fold(raw)
    if let bank = banks[id] { return BankTextSender(kind: .bank, bank: bank, id: id) }
    if isPhoneNumber(raw) { return BankTextSender(kind: .person, bank: nil, id: id) }
    return BankTextSender(kind: .unknown, bank: nil, id: id)
  }

  static func fold(_ s: String) -> String {
    String(String.UnicodeScalarView(s.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.map { u in
      (0x41...0x5a).contains(u.value) ? Unicode.Scalar(u.value + 0x20)! : u
    }))
  }

  static func isPhoneNumber(_ s: String) -> Bool {
    var digits = 0
    for (i, u) in s.unicodeScalars.enumerated() {
      switch u {
      case "0"..."9": digits += 1
      case "+" where i == 0: continue
      case " ", "-", "(", ")", ".": continue
      default: return false
      }
    }
    return (8...15).contains(digits)
  }
}
