// Generates ios/HasalaCore/Sources/HasalaCore/Norm/CharsetTables.swift (spec 04 §1.1, §2.2
// CoreNorm) from reference/ledgerd-client/src/norm/charset-tables.ts.
//
//   swift ios/tools/charset-tables/generate.swift           # rewrite the Swift file
//   swift ios/tools/charset-tables/generate.swift --check   # exit 1 if it is stale
//
// Run from the repository root. The chain of custody is:
//
//   Go's charset registry (go-message/charset + golang.org/x/text, the normalizer's own)
//     --(server/internal/norm TestWriteTwinArtifacts, with a Go freshness test)-->
//   reference/ledgerd-client/src/norm/charset-tables.ts
//     --(this script; CoreNormTests re-parses the TypeScript file and compares)-->
//   CharsetTables.swift
//
// so the Swift tables equal Go's by construction. The platform's own converters
// (String.Encoding.windowsCP1256, CFStringConvertEncoding) are never used: they follow
// Apple's mapping tables, which disagree with Go's at undefined positions exactly as
// TextDecoder does (windows-1252 at 5 bytes, iso-8859-6 at 32).
import Foundation

let tsPath = "reference/ledgerd-client/src/norm/charset-tables.ts"
let swiftPath = "ios/HasalaCore/Sources/HasalaCore/Norm/CharsetTables.swift"

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("charset-tables: \(message)\n".utf8))
  exit(1)
}

guard let source = try? String(contentsOfFile: tsPath, encoding: .utf8) else {
  fail("cannot read \(tsPath); run from the repository root")
}
let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

/// The lines strictly between `const <name>... = [` (or `{`) and the closing `];` / `};`.
func block(_ name: String) -> [String] {
  guard let start = lines.firstIndex(where: { $0.hasPrefix("const \(name):") }) else {
    fail("\(tsPath) has no `const \(name)`")
  }
  var out: [String] = []
  for line in lines[(start + 1)...] {
    if line == "];" || line == "};" { return out }
    out.append(line)
  }
  fail("`const \(name)` is not terminated")
}

/// Decodes one JavaScript double-quoted string literal (the subset the Go writer emits:
/// `\u{h…}`, `\uXXXX`, `\t \n \r \" \\` and printable ASCII).
func jsString(_ literal: Substring) -> [Unicode.Scalar] {
  var out: [Unicode.Scalar] = []
  var it = Array(literal.unicodeScalars)[...]
  guard it.first == "\"", it.last == "\"" else { fail("not a string literal: \(literal.prefix(40))") }
  it = it.dropFirst().dropLast()
  while let c = it.popFirst() {
    guard c == "\\" else {
      out.append(c)
      continue
    }
    guard let e = it.popFirst() else { fail("dangling backslash") }
    switch e {
    case "t": out.append("\t")
    case "n": out.append("\n")
    case "r": out.append("\r")
    case "\"": out.append("\"")
    case "\\": out.append("\\")
    case "u":
      var hex = ""
      if it.first == "{" {
        it = it.dropFirst()
        while let h = it.popFirst(), h != "}" { hex.unicodeScalars.append(h) }
      } else {
        for _ in 0..<4 { if let h = it.popFirst() { hex.unicodeScalars.append(h) } }
      }
      guard let v = UInt32(hex, radix: 16), let s = Unicode.Scalar(v) else { fail("bad \\u escape \(hex)") }
      out.append(s)
    default: fail("unexpected escape \\\(e)")
    }
  }
  return out
}

/// `  "label": 12,` lines.
func labelMap(_ name: String) -> [(String, Int)] {
  block(name).compactMap { line -> (String, Int)? in
    let t = line.trimmingCharacters(in: .whitespaces)
    guard t.hasPrefix("\""), let colon = t.range(of: "\": ") else { return nil }
    let label = String(t[t.index(after: t.startIndex)..<colon.lowerBound])
    let num = t[colon.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ", "))
    guard let n = Int(num) else { fail("bad index in \(name): \(line)") }
    return (label, n)
  }
}

/// `  "label", // comment` lines.
func labelList(_ name: String) -> [String] {
  block(name).compactMap { line -> String? in
    let t = line.trimmingCharacters(in: .whitespaces)
    guard t.hasPrefix("\""), let end = t.dropFirst().firstIndex(of: "\"") else { return nil }
    return String(t[t.index(after: t.startIndex)..<end])
  }
}

let tables: [[UInt32]] = block("TABLES").map { line in
  var t = Substring(line.trimmingCharacters(in: .whitespaces))
  if t.hasSuffix(",") { t = t.dropLast() }
  let scalars = jsString(t)
  guard scalars.count == 256 else { fail("a table has \(scalars.count) entries, not 256") }
  return scalars.map(\.value)
}
guard !tables.isEmpty else { fail("no tables") }
for t in tables where t.contains(where: { $0 > 0xFFFF }) { fail("a table maps outside the BMP: \(t)") }

let singleByte = labelMap("SINGLE_BYTE")
let wordSingleByte = labelMap("WORD_SINGLE_BYTE")
for (label, i) in singleByte + wordSingleByte where i >= tables.count { fail("\(label) -> \(i) is out of range") }
let unsupported = labelList("UNSUPPORTED")
let passthrough = labelList("PASSTHROUGH")
let unresolved = labelList("UNRESOLVED")
let wordUnsupported = labelList("WORD_UNSUPPORTED")
let wordPassthrough = labelList("WORD_PASSTHROUGH")

func hex(_ v: UInt32) -> String {
  let s = String(v, radix: 16, uppercase: true)
  return "0x" + String(repeating: "0", count: max(0, 4 - s.count)) + s
}
func quoted(_ s: String) -> String { "\"\(s)\"" }

var out = """
  // Code generated by ios/tools/charset-tables/generate.swift. DO NOT EDIT.
  //
  // Regenerate from the repository root with
  //   swift ios/tools/charset-tables/generate.swift
  // after reference/ledgerd-client/src/norm/charset-tables.ts changes (itself generated by
  // server/internal/norm TestWriteTwinArtifacts from the Go normalizer's charset registry).
  // CoreNormTests re-reads that TypeScript file and fails if this one has drifted from it.
  //
  // Each table is 256 UTF-16 code units: tables[i][byte] is the character the byte decodes
  // to, U+FFFD where the encoding leaves the byte undefined. Every entry is in the BMP.

  enum CharsetTables {
    /// Byte tables, deduplicated: many labels alias one encoding.
    static let tables: [[UInt16]] = [

  """
for t in tables {
  out += "    [\n"
  for row in stride(from: 0, to: 256, by: 16) {
    out += "      " + t[row..<(row + 16)].map(hex).joined(separator: ", ") + ",\n"
  }
  out += "    ],\n"
}
out += "  ]\n\n"

func emitMap(_ doc: String, _ name: String, _ entries: [(String, Int)]) {
  out += "  /// \(doc)\n  static let \(name): [String: Int] = [\n"
  for (l, i) in entries { out += "    \(quoted(l)): \(i),\n" }
  out += "  ]\n\n"
}
func emitSet(_ doc: String, _ name: String, _ entries: [String]) {
  out += "  /// \(doc)\n  static let \(name): Set<String> = [\n"
  for l in entries { out += "    \(quoted(l)),\n" }
  out += "  ]\n\n"
}
emitMap("Body labels decoded through a single-byte table (index into `tables`).", "singleByte", singleByte)
emitSet("Body labels Go decodes with a stateful or multi-byte codec: refused, never guessed.", "unsupported", unsupported)
emitSet("Body labels whose bytes reach stage 3 undecoded with no error.", "passthrough", passthrough)
emitSet(
  "Body labels the registry cannot resolve (listed for the record; any unlisted label is unresolved too).",
  "unresolved", unresolved)
emitMap("RFC 2047 encoded-word labels (htmlindex alone) decoded through a single-byte table.", "wordSingleByte", wordSingleByte)
emitSet("Encoded-word labels htmlindex resolves to a multi-byte or stateful codec.", "wordUnsupported", wordUnsupported)
emitSet("Encoded-word labels htmlindex resolves to UTF-8, decoded one word at a time.", "wordPassthrough", wordPassthrough)
out.removeLast()
out += "}\n"

if CommandLine.arguments.dropFirst().first == "--check" {
  let current = (try? String(contentsOfFile: swiftPath, encoding: .utf8)) ?? ""
  if current != out { fail("\(swiftPath) is stale; run swift ios/tools/charset-tables/generate.swift") }
  print("charset-tables: \(swiftPath) is current (\(tables.count) tables)")
} else {
  do { try out.write(toFile: swiftPath, atomically: true, encoding: .utf8) } catch { fail("cannot write \(swiftPath): \(error)") }
  print("charset-tables: wrote \(swiftPath) (\(tables.count) tables, \(singleByte.count) body labels)")
}
