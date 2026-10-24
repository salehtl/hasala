import Foundation

struct Mail: Codable {
  var id: String
  var origin: String
  var sender: String
  var receivedAtMs: Int64
  var subject: String
  var text: String
  var listUnsubscribe: Bool
}

struct Truth: Codable, Equatable {
  static let labelExponent = 2

  var isTransaction: Bool
  var amountMinor: Int64?
  var currency: String?
  var merchant: String?
  var direction: String?
}

struct Reading: Equatable {
  var isTransaction = false
  var amountMinor: Int64?
  var currency: String?
  var merchant: String?
  var direction: String?
  var confidence = 0.0
  var note = ""

  static let none = Reading()
}

protocol Reader: AnyObject {
  var name: String { get }
  func reset()
  func read(_ m: Mail) -> Reading
}

extension Reader {
  func reset() {}
}

struct Variant {
  var kind: String
  var mail: Mail
  var truth: Truth
}

protocol Mutation {
  var kind: String { get }
  func apply(_ m: Mail, _ t: Truth) -> Variant?
}
