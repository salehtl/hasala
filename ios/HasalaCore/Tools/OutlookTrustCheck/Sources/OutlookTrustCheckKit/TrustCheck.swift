import CoreMail
import Foundation

public enum TrustExpectation: String, Sendable, CaseIterable {
  case pass
  case untrusted
}

public enum TrustProvider: String, Sendable, CaseIterable {
  case outlook
  case gmail
}

public enum Status: String, Sendable {
  case pass = "PASS"
  case fail = "FAIL"
  case needsData = "NEEDS-DATA"
}

public enum Group: String, Sendable {
  case plain
  case junk
  case forwarded
}

public struct MessageInput: Sendable {
  public let group: Group
  public let bytes: [UInt8]?

  public init(group: Group, bytes: [UInt8]?) {
    self.group = group
    self.bytes = bytes
  }
}

public struct CheckLine: Sendable, Equatable {
  public let id: String
  public let status: Status
  public let detail: String
  public let expectation: String

  public var text: String { "\(id) \(status.rawValue) \(detail) | expect: \(expectation)" }
}

public struct Report: Sendable {
  public let lines: [String]
  public let checks: [CheckLine]

  public var failed: Bool { checks.contains { $0.status == .fail } }
  public var exitCode: Int32 { failed ? 1 : 0 }
  public var text: String { (lines + [""] + checks.map(\.text)).joined(separator: "\n") + "\n" }
}

public enum TrustCheck {
  public static let maxFileBytes = 25 * 1024 * 1024

  public static let expectations: [String: String] = [
    "C1": "exactly one Microsoft-form A-R per genuine alert, topmost among the A-Rs",
    "C2": "exactly one X-MS-Exchange-Organization-AuthAs: Anonymous and one -AuthSource ending in .prod.outlook.com",
    "C3": "every spoof probe or copied message is not pass",
    "C5": "an alert from Junk Email and an auto-forwarded alert both report dmarc=pass compauth=pass and verdict pass",
    "C6": "every genuine alert is pass with its bank domain; every C3 probe is untrusted",
    "C7": "no genuine alert carries a second Microsoft-form A-R (a bank tenant's would make it multiple_ar)",
    "G1": "exactly one mx.google.com A-R per genuine alert, topmost among the A-Rs",
    "G2": "every genuine alert is pass with an aligned DKIM domain",
    "G3": "every copied or forged message is not pass",
  ]

  public static func probe(bytes: [UInt8]) -> AuthResults.OutlookTrustProbe {
    AuthResults.outlookTrustProbe(MailHeaders.headerBlock(rawMessage: bytes))
  }

  public static func gmailProbe(bytes: [UInt8]) -> AuthResults.GmailTrustProbe {
    AuthResults.gmailTrustProbe(MailHeaders.headerBlock(rawMessage: bytes))
  }

  static func index(_ i: Int, of count: Int) -> String {
    let width = max(2, String(count).count)
    let n = String(i + 1)
    return "#" + String(repeating: "0", count: width - n.count) + n
  }

  public static func runGmail(_ inputs: [MessageInput], expect: TrustExpectation, domains: [String] = []) -> Report {
    var lines: [String] = []
    var probes: [AuthResults.GmailTrustProbe] = []
    var unreadable = 0
    for (i, input) in inputs.enumerated() {
      let tag = input.group == .plain ? "" : " [\(input.group.rawValue)]"
      guard let bytes = input.bytes else {
        unreadable += 1
        lines.append("\(index(i, of: inputs.count))\(tag) unreadable")
        continue
      }
      let p = gmailProbe(bytes: bytes)
      probes.append(p)
      lines.append("\(index(i, of: inputs.count))\(tag) \(p.line)")
    }
    var checks: [CheckLine] = []
    func add(_ id: String, _ status: Status, _ detail: String) {
      checks.append(CheckLine(id: id, status: status, detail: detail, expectation: expectations[id] ?? ""))
    }
    if unreadable > 0 {
      checks.append(
        CheckLine(
          id: "READ", status: .fail, detail: "\(unreadable) file(s) could not be read",
          expectation: "every .eml in the folder is readable and under \(maxFileBytes / 1024 / 1024) MB"))
    }
    let total = probes.count
    switch expect {
    case .pass:
      if total == 0 {
        for id in ["G1", "G2"] { add(id, .needsData, "no genuine alerts in this folder") }
        return Report(lines: lines, checks: checks)
      }
      let g1 = probes.filter(\.g1).count
      add("G1", g1 == total ? .pass : .fail, "\(g1)/\(total) have one mx.google.com A-R, topmost")
      let g2 = probes.filter { p in
        guard p.analysis.verdict.trusted, let d = p.analysis.domain else { return false }
        return domains.isEmpty || domains.contains { d == $0 || d.hasSuffix("." + $0) }
      }.count
      let scope = domains.isEmpty ? "" : " under \(domains.joined(separator: ","))"
      add("G2", g2 == total ? .pass : .fail, "\(g2)/\(total) pass with a verified domain\(scope)")
      add("G3", .needsData, "this folder is for --expect pass; run the copied folder with --expect untrusted")
    case .untrusted:
      if total == 0 {
        add("G3", .needsData, "no copied or forged messages in this folder")
      } else {
        let passed = probes.filter { $0.analysis.verdict.trusted }.count
        let passDomains = Array(Set(probes.compactMap { $0.analysis.domain })).sorted()
        let leak = passDomains.isEmpty ? "" : " pass_domains=\(passDomains.joined(separator: ","))"
        add("G3", passed == 0 ? .pass : .fail, "\(total - passed)/\(total) are not pass\(leak)")
      }
      for id in ["G1", "G2"] { add(id, .needsData, "this folder is for --expect untrusted; run the genuine folder with --expect pass") }
      checks.sort { order($0.id) < order($1.id) }
    }
    return Report(lines: lines, checks: checks)
  }

  public static func run(_ inputs: [MessageInput], expect: TrustExpectation, domains: [String] = []) -> Report {
    var lines: [String] = []
    var probes: [(group: Group, probe: AuthResults.OutlookTrustProbe)] = []
    var unreadable = 0
    let width = max(2, String(inputs.count).count)
    for (i, input) in inputs.enumerated() {
      let n = String(i + 1)
      let index = "#" + String(repeating: "0", count: width - n.count) + n
      let tag = input.group == .plain ? "" : " [\(input.group.rawValue)]"
      guard let bytes = input.bytes else {
        unreadable += 1
        lines.append("\(index)\(tag) unreadable")
        continue
      }
      let p = probe(bytes: bytes)
      probes.append((input.group, p))
      lines.append("\(index)\(tag) \(p.line)")
    }
    var checks: [CheckLine] = []
    func add(_ id: String, _ status: Status, _ detail: String) {
      checks.append(CheckLine(id: id, status: status, detail: detail, expectation: expectations[id] ?? ""))
    }
    let total = probes.count
    if unreadable > 0 {
      checks.append(
        CheckLine(
          id: "READ", status: .fail, detail: "\(unreadable) file(s) could not be read",
          expectation: "every .eml in the folder is readable and under \(maxFileBytes / 1024 / 1024) MB"))
    }

    func trustedDomainOK(_ p: AuthResults.OutlookTrustProbe) -> Bool {
      guard p.analysis.verdict.trusted, let d = p.analysis.domain else { return false }
      if domains.isEmpty { return true }
      return domains.contains { d == $0 || d.hasSuffix("." + $0) }
    }

    switch expect {
    case .pass:
      let need = "no genuine alerts in this folder"
      if total == 0 {
        for id in ["C1", "C2", "C5", "C6", "C7"] { add(id, .needsData, need) }
        return Report(lines: lines, checks: checks)
      }
      let c1 = probes.filter { $0.probe.c1 }.count
      add("C1", c1 == total ? .pass : .fail, "\(c1)/\(total) have one Microsoft-form A-R, topmost")
      let c2 = probes.filter { $0.probe.c2 }.count
      add("C2", c2 == total ? .pass : .fail, "\(c2)/\(total) have one AuthAs Anonymous and one prod.outlook.com AuthSource")
      let junk = probes.filter { $0.group == .junk }
      let fwd = probes.filter { $0.group == .forwarded }
      func c5ok(_ p: AuthResults.OutlookTrustProbe) -> Bool {
        p.dmarc == "pass" && p.compauth == "pass" && p.analysis.verdict.trusted
      }
      let c5bad = (junk + fwd).filter { !c5ok($0.probe) }.count
      let c5detail = "junk=\(junk.count) forwarded=\(fwd.count) not_pass=\(c5bad)"
      if c5bad > 0 {
        add("C5", .fail, c5detail)
      } else if junk.isEmpty || fwd.isEmpty {
        add("C5", .needsData, c5detail + " (put the files in junk/ and forwarded/ subfolders)")
      } else {
        add("C5", .pass, c5detail)
      }
      let c6 = probes.filter { trustedDomainOK($0.probe) }.count
      let scope = domains.isEmpty ? "" : " under \(domains.joined(separator: ","))"
      add("C6", c6 == total ? .pass : .fail, "\(c6)/\(total) pass with a verified domain\(scope)")
      let c7 = probes.filter { $0.probe.secondAR != .none }.count
      let c7from = probes.filter { $0.probe.secondAR == .fromDomain }.count
      add("C7", c7 == 0 ? .pass : .fail, "\(c7)/\(total) carry a second Microsoft-form A-R (from_domain=\(c7from))")
    case .untrusted:
      let need = "this folder is for --expect untrusted; run the genuine folder with --expect pass"
      if total == 0 {
        add("C3", .needsData, "no probe or copied messages in this folder")
        add("C6", .needsData, "untrusted half: no messages")
      } else {
        let passed = probes.filter { $0.probe.analysis.verdict.trusted }.count
        let passDomains = Array(Set(probes.compactMap { $0.probe.analysis.domain })).sorted()
        let leak = passDomains.isEmpty ? "" : " pass_domains=\(passDomains.joined(separator: ","))"
        add("C3", passed == 0 ? .pass : .fail, "\(total - passed)/\(total) are not pass\(leak)")
        add("C6", passed == 0 ? .pass : .fail, "untrusted half: \(total - passed)/\(total) untrusted")
      }
      for id in ["C1", "C2", "C5", "C7"] { add(id, .needsData, need) }
      checks.sort { order($0.id) < order($1.id) }
    }
    return Report(lines: lines, checks: checks)
  }

  static func order(_ id: String) -> Int {
    ["READ", "C1", "C2", "C3", "C5", "C6", "C7", "G1", "G2", "G3"].firstIndex(of: id) ?? 99
  }

  public static func collect(directory: URL) throws -> [MessageInput] {
    let fm = FileManager.default
    var entries: [(path: String, group: Group, url: URL)] = []
    func emls(in dir: URL) throws -> [URL] {
      try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        .filter { $0.pathExtension.caseInsensitiveCompare("eml") == .orderedSame }
        .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
    for url in try emls(in: directory) { entries.append((url.lastPathComponent, .plain, url)) }
    for sub in [Group.junk, Group.forwarded] {
      let dir = directory.appendingPathComponent(sub.rawValue, isDirectory: true)
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
      for url in try emls(in: dir) { entries.append((sub.rawValue + "/" + url.lastPathComponent, sub, url)) }
    }
    entries.sort { $0.path < $1.path }
    return entries.map { e in
      let size = (try? e.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
      guard size <= maxFileBytes, let data = try? Data(contentsOf: e.url) else {
        return MessageInput(group: e.group, bytes: nil)
      }
      return MessageInput(group: e.group, bytes: [UInt8](data))
    }
  }

  public static func insideRepository(_ dir: URL) -> Bool {
    var parts = dir.standardizedFileURL.pathComponents
    while !parts.isEmpty {
      let path = NSString.path(withComponents: parts + ["private-fixtures.lock"])
      if FileManager.default.fileExists(atPath: path) { return true }
      parts.removeLast()
    }
    return false
  }

  public static let usage = """
    usage: outlook-trust-check [--provider outlook|gmail] --expect pass|untrusted [--domains d1,d2] <dir>
      <dir>            a folder of .eml files outside the repository; junk/ and forwarded/
                       subfolders are read too (C5)
      --provider       outlook (the default: checks C1-C7) or gmail (the Gmail rule: G1-G3)
      --expect pass    genuine bank alerts (C1, C2, C5, C6, C7; Gmail: G1, G2)
      --expect untrusted
                       copied messages or spoof probes (C3, and the untrusted half of C6; Gmail: G3)
      --domains        optional comma-separated bank domains; C6 and G2 then also require the
                       verified domain to be one of them or a subdomain
    exit: 0 no FAIL, 1 a FAIL, 64 usage
    """

  public struct Arguments: Sendable, Equatable {
    public let provider: TrustProvider
    public let expect: TrustExpectation
    public let domains: [String]
    public let directory: String

    public init(expect: TrustExpectation, domains: [String], directory: String, provider: TrustProvider = .outlook) {
      self.provider = provider
      self.expect = expect
      self.domains = domains
      self.directory = directory
    }
  }

  public static func parse(_ args: [String]) -> Arguments? {
    var provider = TrustProvider.outlook
    var expect: TrustExpectation? = nil
    var domains: [String] = []
    var dir: String? = nil
    var i = 0
    while i < args.count {
      let a = args[i]
      switch a {
      case "--provider":
        guard i + 1 < args.count, let p = TrustProvider(rawValue: args[i + 1]) else { return nil }
        provider = p
        i += 2
      case "--expect":
        guard i + 1 < args.count, let e = TrustExpectation(rawValue: args[i + 1]) else { return nil }
        expect = e
        i += 2
      case "--domains":
        guard i + 1 < args.count else { return nil }
        domains = args[i + 1].split(separator: ",").map { String($0).lowercased() }.filter { !$0.isEmpty }
        i += 2
      default:
        guard !a.hasPrefix("-"), dir == nil else { return nil }
        dir = a
        i += 1
      }
    }
    guard let expect, let dir else { return nil }
    return Arguments(expect: expect, domains: domains, directory: dir, provider: provider)
  }
}
