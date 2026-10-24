#!/usr/bin/env swift
// generate.swift: Paper design tokens -> HasalaDesign/Generated/Tokens.swift.
//
//   swift ios/tools/tokens/generate.swift            # rewrite Tokens.swift
//   swift ios/tools/tokens/generate.swift --check    # exit 1 if Tokens.swift is stale
//   swift ios/tools/tokens/generate.swift --accept-hash  # take a new Paper token set
//
// Run from the repository root. The input is design/tokens/paper-tokens.json, a
// verbatim `get_tokens` export of the private Paper design file (name -> value,
// in the file's order, plus the token-set hash Paper reports). Aliases
// (`var(--x)`) are resolved here, so the Swift side sees only literals; each
// alias keeps a comment naming what it points at. The design is light only, so
// there is one value per token (spec 04 §14.1, §14.2).

import Foundation

struct Token: Decodable { let name: String; let value: String }
struct TokenFile: Decodable { let hash: String; let count: Int; let tokens: [Token] }

let inputPath = "design/tokens/paper-tokens.json"
let outputPath = "ios/HasalaKit/Sources/HasalaDesign/Generated/Tokens.swift"
let checkOnly = CommandLine.arguments.contains("--check")
let acceptHash = CommandLine.arguments.contains("--accept-hash")

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data(("generate.swift: " + message + "\n").utf8))
  exit(1)
}

guard let data = FileManager.default.contents(atPath: inputPath) else {
  fail("cannot read \(inputPath); run from the repository root")
}
let file: TokenFile
do { file = try JSONDecoder().decode(TokenFile.self, from: data) } catch { fail("bad JSON: \(error)") }
guard file.tokens.count == file.count else {
  fail("\(inputPath) says count \(file.count) but holds \(file.tokens.count) tokens")
}

var byName: [String: String] = [:]
for t in file.tokens {
  guard byName[t.name] == nil else { fail("duplicate token \(t.name)") }
  byName[t.name] = t.value
}

/// Follows `var(--x)` chains to a literal; returns the literal and the first alias target.
func resolve(_ name: String, depth: Int = 0) -> (literal: String, aliasOf: String?) {
  guard depth < 16 else { fail("alias cycle at \(name)") }
  guard let raw = byName[name] else { fail("unknown token \(name)") }
  let v = raw.trimmingCharacters(in: .whitespaces)
  if v.hasPrefix("var("), v.hasSuffix(")") {
    let target = String(v.dropFirst(4).dropLast())
    return (resolve(target, depth: depth + 1).literal, target)
  }
  return (v, nil)
}

/// `--color-hue-sky-start` minus its namespace prefix -> `hueSkyStart`; `2xs` -> `xxs`.
func identifier(_ rest: String) -> String {
  let parts = rest.split(separator: "-").map(String.init)
  var out = ""
  for (i, p) in parts.enumerated() {
    var seg = p
    if let first = seg.first, first.isNumber, seg.hasSuffix("xs") || seg.hasSuffix("xl") {
      let n = Int(seg.dropLast(2)) ?? 1
      seg = String(repeating: "x", count: n) + String(seg.suffix(1))
    }
    out += i == 0 ? seg.lowercased() : seg.prefix(1).uppercased() + seg.dropFirst()
  }
  guard let first = out.first, first.isLetter else { fail("cannot name \(rest)") }
  return out
}

struct RGBA { var r: Int; var g: Int; var b: Int; var a: Double }

func parseColor(_ s: String) -> RGBA {
  if s.hasPrefix("#") {
    let hex = String(s.dropFirst())
    guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { fail("bad hex \(s)") }
    if hex.count == 6 {
      return RGBA(r: Int(v >> 16 & 0xFF), g: Int(v >> 8 & 0xFF), b: Int(v & 0xFF), a: 1)
    }
    return RGBA(r: Int(v >> 24 & 0xFF), g: Int(v >> 16 & 0xFF), b: Int(v >> 8 & 0xFF),
                a: Double(v & 0xFF) / 255)
  }
  if s.hasPrefix("rgb("), s.hasSuffix(")") {
    // CSS Color 4 space syntax: rgb(R G B / A%)
    let body = s.dropFirst(4).dropLast()
    let halves = body.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
    let chans = halves[0].split(separator: " ").compactMap { Int($0) }
    guard chans.count == 3 else { fail("bad rgb \(s)") }
    var alpha = 1.0
    if halves.count == 2 {
      let a = halves[1]
      if a.hasSuffix("%"), let p = Double(a.dropLast()) { alpha = p / 100 } else if let f = Double(a) { alpha = f } else { fail("bad alpha \(s)") }
    }
    return RGBA(r: chans[0], g: chans[1], b: chans[2], a: alpha)
  }
  fail("unsupported colour literal \(s)")
}

func px(_ s: String) -> String {
  guard s.hasSuffix("px"), let v = Double(s.dropLast(2)) else { fail("expected px, got \(s)") }
  return fmt(v)
}

func fmt(_ v: Double) -> String {
  v == v.rounded() ? String(Int(v)) : String(v)
}

func fmtAlpha(_ a: Double) -> String {
  // Paper writes percentages with at most one decimal (92.2%), so four places are exact.
  var t = String(format: "%.4f", a)
  while t.hasSuffix("0") { t.removeLast() }
  if t.hasSuffix(".") { t.removeLast() }
  return t
}

// Namespaces, longest prefix first so `--font-weight-` wins over `--font-`.
let namespaces: [(prefix: String, kind: String)] = [
  ("--color-", "color"), ("--font-weight-", "weight"), ("--font-", "family"),
  ("--text-", "size"), ("--leading-", "leading"), ("--tracking-", "tracking"),
  ("--spacing-", "spacing"), ("--radius-", "radius"), ("--container-", "container"),
]

var sections: [String: [String]] = [:]
var colorNames: [String] = []
var seen: [String: Set<String>] = [:]
for t in file.tokens {
  guard let ns = namespaces.first(where: { t.name.hasPrefix($0.prefix) }) else {
    fail("token \(t.name) is in no known namespace")
  }
  let id = identifier(String(t.name.dropFirst(ns.prefix.count)))
  guard seen[ns.kind, default: []].insert(id).inserted else { fail("name clash \(id) in \(ns.kind)") }
  let (lit, alias) = resolve(t.name)
  let note = alias.map { "  // \(t.name) = var(\($0))" } ?? "  // \(t.name)"
  let line: String
  switch ns.kind {
  case "color":
    let c = parseColor(lit)
    line = "  public static let \(id) = HRGBA(\(c.r), \(c.g), \(c.b), \(fmtAlpha(c.a)))\(note)"
    colorNames.append(id)
  case "weight":
    guard let w = Int(lit) else { fail("bad weight \(lit)") }
    line = "  public static let \(id) = \(w)\(note)"
  case "family":
    line = "  public static let \(id) = \"\(lit)\"\(note)"
  case "tracking":
    if lit.hasSuffix("em"), let em = Double(lit.dropLast(2)) {
      line = "  public static let \(id)Em: CGFloat = \(fmt(em))\(note) (em)"
    } else {
      line = "  public static let \(id): CGFloat = \(px(lit))\(note)"
    }
  default:
    line = "  public static let \(id): CGFloat = \(px(lit))\(note)"
  }
  sections[ns.kind, default: []].append(line)
}

let enums: [(kind: String, name: String, doc: String)] = [
  ("color", "HPalette", "Every colour token as 8-bit sRGB plus opacity. `HColor` wraps these as SwiftUI colours."),
  ("family", "HFontFamily", "Font family tokens. Inter is bundled; SF Pro Rounded and SF Pro are the system faces."),
  ("weight", "HFontWeight", "CSS font weights (400 regular … 700 bold)."),
  ("size", "HFontSize", "Font sizes in points."),
  ("leading", "HLeading", "Line heights in points."),
  ("tracking", "HTracking", "Letter spacing in points; `…Em` values are a fraction of the font size."),
  ("spacing", "HSpacing", "Spacing, sizes of controls and insets, in points."),
  ("radius", "HRadius", "Corner radii in points."),
  ("container", "HContainer", "Fixed container widths in points."),
]

var out = """
// Generated by ios/tools/tokens/generate.swift from design/tokens/paper-tokens.json.
// DO NOT EDIT. Change the tokens in Paper, re-export, and run the generator.
// Paper token set \(file.hash), \(file.count) tokens. Light appearance only (spec 04 §14.2).
// swiftlint:disable all

import SwiftUI

public enum HTokens {
  /// The token-set hash Paper reported for the export this file was generated from.
  public static let paperHash = "\(file.hash)"
  /// Number of tokens in that export.
  public static let count = \(file.count)
}


"""
for e in enums {
  out += "/// \(e.doc)\npublic enum \(e.name) {\n"
  out += sections[e.kind, default: []].joined(separator: "\n")
  out += "\n}\n\n"
  if e.kind == "color" {
    out += "/// Every colour token as a SwiftUI colour (sRGB). Same names as `HPalette`.\npublic enum HColor {\n"
    out += colorNames.map { "  public static let \($0) = Color(HPalette.\($0))" }.joined(separator: "\n")
    out += "\n}\n\n"
  }
}
out.removeLast()

let existing = (try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? ""
// A new Paper token set is a design change, not a regeneration: it is taken only
// on purpose, with --accept-hash (spec 04 §14.1).
let hashMarker = "public static let paperHash = \""
let recordedHash = existing.range(of: hashMarker).map { start in
  String(existing[start.upperBound...].prefix { $0 != "\"" })
}
if let recordedHash, recordedHash != file.hash, !acceptHash {
  fail("""
    \(inputPath) is token set \(file.hash) but Tokens.swift was generated from \(recordedHash); \
    re-run with --accept-hash to take the new set
    """)
}
if checkOnly {
  if existing != out {
    fail("\(outputPath) is stale; run `swift ios/tools/tokens/generate.swift` and commit the result")
  }
  print("Tokens.swift is up to date (\(file.count) tokens, set \(file.hash))")
} else {
  do { try out.write(toFile: outputPath, atomically: true, encoding: .utf8) } catch { fail("write: \(error)") }
  print("wrote \(outputPath) (\(file.count) tokens, set \(file.hash))")
}
