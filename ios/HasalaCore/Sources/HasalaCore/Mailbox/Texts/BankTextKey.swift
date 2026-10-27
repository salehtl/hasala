import CorePrimitives
import Foundation

public enum BankTextKey {
  public static let secretBytes = 32
  public static let channel = "sms"

  public static func ingestID(secret: Data, sender: String?, normalizedText: String, arrivalMinuteMs: Int64, n: Int) -> String? {
    guard secret.count == secretBytes, n >= 0 else { return nil }
    var message = Data()
    for field in [
      Data(channel.utf8), Data((sender ?? "").utf8), Data(normalizedText.utf8), Data(String(arrivalMinuteMs / 60_000).utf8),
      Data(String(n).utf8),
    ] {
      var length = UInt32(field.count).bigEndian
      withUnsafeBytes(of: &length) { message.append(contentsOf: $0) }
      message.append(field)
    }
    return Hex.encode(hmacSHA256(key: secret, message: message))
  }
}
