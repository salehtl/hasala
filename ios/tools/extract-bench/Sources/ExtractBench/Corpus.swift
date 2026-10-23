import CoreNorm
import Foundation

enum Corpus {
  static func loadMaildir(_ dir: String) throws -> [Mail] {
    let names = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".eml") }.sorted()
    var out: [Mail] = []
    for n in names {
      let raw = [UInt8](try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(n)))
      let h = headers(raw)
      let at = h["date"].flatMap(parseDate) ?? 0
      guard let r = try? Normalizer.normalize(version: Normalizer.currentVersion, raw: raw, receivedAtMs: at) else {
        FileHandle.standardError.write("skip (normalize): \(n)\n".data(using: .utf8)!)
        continue
      }
      out.append(
        Mail(
          id: n, origin: "real", sender: domain(h["from"] ?? ""), receivedAtMs: at, subject: r.subject, text: r.text,
          listUnsubscribe: h["list-unsubscribe"] != nil))
    }
    return out.sorted { ($0.receivedAtMs, $0.id) < ($1.receivedAtMs, $1.id) }
  }

  static func loadSynthetic(_ dir: String) throws -> [(Mail, Truth)] {
    let names = try FileManager.default.contentsOfDirectory(atPath: dir).filter {
      $0.hasPrefix("synthetic-") && $0.hasSuffix(".json")
    }.sorted()
    var out: [(Mail, Truth)] = []
    var clock: Int64 = 1_780_000_000_000
    for n in names {
      let d = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(n))) as! [String: Any]
      if (d["template"] as? String ?? "").hasPrefix("synth.") { continue }
      let def = d["definition"] as? [String: Any] ?? [:]
      let match = def["match"] as? [String: Any] ?? [:]
      let sender = (match["sender_domain"] as? [String])?.first ?? "unknown"
      for c in d["cases"] as? [[String: Any]] ?? [] {
        guard let e = c["expect"] as? [String: Any], e["matched"] as? Bool == true else { continue }
        let subject = String(decoding: Data(base64Encoded: c["subject_base64"] as? String ?? "") ?? Data(), as: UTF8.self)
        let body = String(decoding: Data(base64Encoded: c["normalized_body_base64"] as? String ?? "") ?? Data(), as: UTF8.self)
        clock += 60_000
        let merchant = (e["merchant"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let t = Truth(
          isTransaction: true, amountMinor: Int64(e["amount_minor"] as? String ?? ""), currency: e["currency"] as? String,
          merchant: merchant, direction: e["direction"] as? String)
        out.append(
          (
            Mail(
              id: "\(n.dropLast(5))#\(c["name"] as? String ?? "")", origin: "synthetic", sender: sender, receivedAtMs: clock,
              subject: subject, text: body, listUnsubscribe: false), t
          ))
      }
    }
    return out
  }

  static func loadLabels(_ path: String) -> [String: Truth] {
    guard let d = FileManager.default.contents(atPath: path) else { return [:] }
    return (try? JSONDecoder().decode([String: Truth].self, from: d)) ?? [:]
  }

  static func writeJSONL(_ mails: [Mail], to path: String) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var out = Data()
    for m in mails {
      out.append(try enc.encode(m))
      out.append(0x0a)
    }
    try out.write(to: URL(fileURLWithPath: path))
  }

  static func headers(_ raw: [UInt8]) -> [String: String] {
    var end = raw.count
    var i = 0
    while i + 1 < raw.count {
      if raw[i] == 0x0a && raw[i + 1] == 0x0a { end = i; break }
      if i + 3 < raw.count && raw[i] == 0x0d && raw[i + 1] == 0x0a && raw[i + 2] == 0x0d && raw[i + 3] == 0x0a { end = i; break }
      i += 1
    }
    let block = String(decoding: raw[0..<end], as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
    var out: [String: String] = [:]
    var cur: (String, String)?
    for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
      if let f = line.first, f == " " || f == "\t", var c = cur {
        c.1 += " " + line.trimmingCharacters(in: .whitespaces)
        cur = c
        continue
      }
      if let c = cur, out[c.0] == nil { out[c.0] = c.1 }
      guard let colon = line.firstIndex(of: ":") else { cur = nil; continue }
      cur = (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }
    if let c = cur, out[c.0] == nil { out[c.0] = c.1 }
    return out
  }

  static func domain(_ from: String) -> String {
    var s = from
    if let lt = s.lastIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt { s = String(s[s.index(after: lt)..<gt]) }
    guard let at = s.lastIndex(of: "@") else { return "" }
    return s[s.index(after: at)...].trimmingCharacters(in: .whitespaces).lowercased()
  }

  static func parseDate(_ s: String) -> Int64? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    let cleaned = s.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
    for fmt in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z"] {
      f.dateFormat = fmt
      if let d = f.date(from: cleaned) { return Int64(d.timeIntervalSince1970 * 1000) }
    }
    return nil
  }
}
