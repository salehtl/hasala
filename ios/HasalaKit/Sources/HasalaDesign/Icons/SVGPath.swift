import CoreGraphics
import SwiftUI

/// SVG path data, parsed once into absolute commands (spec 01 appendix B). Supports M, L, H, V,
/// C, S, Q, T, A and Z in both cases, the compact number syntax Paper exports ("1.5.5", "-.4",
/// "a2 2 0 0 1-2 2", arc flags without separators), and implicit repeats. Geometry is in the
/// path's own units (a 24 × 24 box for icons); `path(in:viewBox:)` scales it into a rect.
public struct SVGPath: Sendable, Hashable {
  /// One drawing step, in absolute coordinates. Smooth and quadratic curves are resolved to
  /// cubics, and arcs to cubic segments, so drawing needs only three operations.
  public enum Element: Sendable, Hashable {
    case move(CGPoint)
    case line(CGPoint)
    case curve(CGPoint, control1: CGPoint, control2: CGPoint)
    case close
  }

  public enum ParseError: Error, Equatable {
    case unexpected(Character, at: Int)
    case missingNumber(at: Int)
    case noCurrentPoint
  }

  public let elements: [Element]

  public init(elements: [Element]) { self.elements = elements }

  /// Parses `d`. Throws on anything outside the grammar above.
  public init(parsing d: String) throws {
    var parser = Parser(Array(d.utf8))
    elements = try parser.parse()
  }

  /// The axis-aligned box around every point the path passes through (end points and curve
  /// extremes are inside the box of their controls, which is what icon bounds need).
  public var bounds: CGRect {
    var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
    func take(_ p: CGPoint) {
      minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y)
    }
    var current = CGPoint.zero
    for e in elements {
      switch e {
      case .move(let p), .line(let p):
        take(p)
        current = p
      case .curve(let p, let c1, let c2):
        for t in stride(from: 0.0, through: 1.0, by: 0.05) {
          take(Self.cubic(current, c1, c2, p, t))
        }
        current = p
      case .close: break
      }
    }
    guard minX.isFinite else { return .null }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  /// The path scaled from `viewBox` into `rect`, keeping its aspect ratio and centring it.
  public func path(in rect: CGRect, viewBox: CGRect = CGRect(x: 0, y: 0, width: 24, height: 24)) -> Path {
    let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
    let dx = rect.minX + (rect.width - viewBox.width * scale) / 2 - viewBox.minX * scale
    let dy = rect.minY + (rect.height - viewBox.height * scale) / 2 - viewBox.minY * scale
    func map(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + dx, y: p.y * scale + dy) }
    var path = Path()
    for e in elements {
      switch e {
      case .move(let p): path.move(to: map(p))
      case .line(let p): path.addLine(to: map(p))
      case .curve(let p, let c1, let c2): path.addCurve(to: map(p), control1: map(c1), control2: map(c2))
      case .close: path.closeSubpath()
      }
    }
    return path
  }

  static func cubic(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p1: CGPoint, _ t: Double) -> CGPoint {
    let u = 1 - t
    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
    return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p1.x, y: a * p0.y + b * c1.y + c * c2.y + d * p1.y)
  }
}

private struct Parser {
  let bytes: [UInt8]
  var i = 0
  var elements: [SVGPath.Element] = []
  var current = CGPoint.zero
  var subpathStart = CGPoint.zero
  /// The second control point of the last cubic, or the control of the last quadratic, for
  /// the smooth commands. Nil after any other command.
  var lastCubicControl: CGPoint?
  var lastQuadControl: CGPoint?
  var hasCurrent = false

  init(_ bytes: [UInt8]) { self.bytes = bytes }

  mutating func parse() throws -> [SVGPath.Element] {
    var command: UInt8?
    while true {
      skipSeparators()
      guard i < bytes.count else { break }
      let b = bytes[i]
      if Self.isCommand(b) {
        command = b
        i += 1
      } else if command == nil || !Self.startsNumber(b) {
        throw SVGPath.ParseError.unexpected(Character(Unicode.Scalar(b)), at: i)
      }
      guard let c = command else { break }
      try run(c)
      // After a moveto, implicit repeats are linetos (SVG 1.1 §8.3.2).
      if c == UInt8(ascii: "M") { command = UInt8(ascii: "L") }
      if c == UInt8(ascii: "m") { command = UInt8(ascii: "l") }
      if c == UInt8(ascii: "Z") || c == UInt8(ascii: "z") { command = nil }
    }
    return elements
  }

  mutating func run(_ c: UInt8) throws {
    let relative = c >= UInt8(ascii: "a")
    let base = relative ? current : .zero
    switch c | 0x20 {  // lower-case
    case UInt8(ascii: "m"):
      let p = try point(base)
      elements.append(.move(p))
      current = p
      subpathStart = p
      hasCurrent = true
      clearSmooth()
    case UInt8(ascii: "l"):
      try needCurrent()
      let p = try point(base)
      elements.append(.line(p))
      current = p
      clearSmooth()
    case UInt8(ascii: "h"):
      try needCurrent()
      let x = try number()
      current = CGPoint(x: relative ? current.x + x : x, y: current.y)
      elements.append(.line(current))
      clearSmooth()
    case UInt8(ascii: "v"):
      try needCurrent()
      let y = try number()
      current = CGPoint(x: current.x, y: relative ? current.y + y : y)
      elements.append(.line(current))
      clearSmooth()
    case UInt8(ascii: "c"):
      try needCurrent()
      let c1 = try point(base), c2 = try point(base), p = try point(base)
      elements.append(.curve(p, control1: c1, control2: c2))
      current = p
      lastCubicControl = c2
      lastQuadControl = nil
    case UInt8(ascii: "s"):
      try needCurrent()
      let c1 = reflect(lastCubicControl)
      let c2 = try point(base), p = try point(base)
      elements.append(.curve(p, control1: c1, control2: c2))
      current = p
      lastCubicControl = c2
      lastQuadControl = nil
    case UInt8(ascii: "q"):
      try needCurrent()
      let q = try point(base), p = try point(base)
      appendQuad(q, to: p)
    case UInt8(ascii: "t"):
      try needCurrent()
      let q = reflect(lastQuadControl)
      let p = try point(base)
      appendQuad(q, to: p)
    case UInt8(ascii: "a"):
      try needCurrent()
      let rx = try number(), ry = try number(), rotation = try number()
      let large = try flag(), sweep = try flag()
      let p = try point(base)
      appendArc(rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep, to: p)
      current = p
      clearSmooth()
    case UInt8(ascii: "z"):
      elements.append(.close)
      current = subpathStart
      clearSmooth()
    default:
      throw SVGPath.ParseError.unexpected(Character(Unicode.Scalar(c)), at: i - 1)
    }
  }

  mutating func clearSmooth() {
    lastCubicControl = nil
    lastQuadControl = nil
  }

  func reflect(_ control: CGPoint?) -> CGPoint {
    guard let control else { return current }
    return CGPoint(x: 2 * current.x - control.x, y: 2 * current.y - control.y)
  }

  func needCurrent() throws {
    if !hasCurrent { throw SVGPath.ParseError.noCurrentPoint }
  }

  mutating func appendQuad(_ q: CGPoint, to p: CGPoint) {
    let c1 = CGPoint(x: current.x + 2 / 3 * (q.x - current.x), y: current.y + 2 / 3 * (q.y - current.y))
    let c2 = CGPoint(x: p.x + 2 / 3 * (q.x - p.x), y: p.y + 2 / 3 * (q.y - p.y))
    elements.append(.curve(p, control1: c1, control2: c2))
    current = p
    lastQuadControl = q
    lastCubicControl = nil
  }

  /// SVG 1.1 appendix F.6: endpoint to centre parameterisation, then one cubic per ≤ 90°.
  mutating func appendArc(rx rxIn: Double, ry ryIn: Double, rotation: Double, large: Bool, sweep: Bool,
                          to p: CGPoint)
  {
    let p0 = current
    if p0 == p { return }
    var rx = abs(rxIn), ry = abs(ryIn)
    if rx == 0 || ry == 0 {
      elements.append(.line(p))
      return
    }
    let phi = rotation * .pi / 180
    let cosPhi = cos(phi), sinPhi = sin(phi)
    let dx2 = (p0.x - p.x) / 2, dy2 = (p0.y - p.y) / 2
    let x1p = cosPhi * dx2 + sinPhi * dy2
    let y1p = -sinPhi * dx2 + cosPhi * dy2
    let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lambda > 1 {
      rx *= lambda.squareRoot()
      ry *= lambda.squareRoot()
    }
    let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    var coef = den == 0 ? 0 : (max(0, num) / den).squareRoot()
    if large == sweep { coef = -coef }
    let cxp = coef * (rx * y1p / ry)
    let cyp = coef * -(ry * x1p / rx)
    let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p.x) / 2
    let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p.y) / 2

    func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
      let dot = ux * vx + uy * vy
      let len = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
      var a = acos(max(-1, min(1, dot / len)))
      if ux * vy - uy * vx < 0 { a = -a }
      return a
    }
    let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if !sweep, delta > 0 { delta -= 2 * .pi }
    if sweep, delta < 0 { delta += 2 * .pi }

    let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
    let step = delta / Double(segments)
    let k = 4.0 / 3.0 * tan(step / 4)
    func onEllipse(_ t: Double) -> (CGPoint, CGPoint) {
      // The point, and the derivative direction (unscaled by k).
      let x = rx * cos(t), y = ry * sin(t)
      let dx = -rx * sin(t), dy = ry * cos(t)
      let point = CGPoint(x: cosPhi * x - sinPhi * y + cx, y: sinPhi * x + cosPhi * y + cy)
      let tangent = CGPoint(x: cosPhi * dx - sinPhi * dy, y: sinPhi * dx + cosPhi * dy)
      return (point, tangent)
    }
    var t = theta1
    var (start, startTangent) = onEllipse(t)
    for s in 0..<segments {
      let t2 = t + step
      let (onArc, endTangent) = onEllipse(t2)
      // The last segment ends exactly on the given point, whatever rounding did.
      let end = s == segments - 1 ? p : onArc
      let c1 = CGPoint(x: start.x + k * startTangent.x, y: start.y + k * startTangent.y)
      let c2 = CGPoint(x: end.x - k * endTangent.x, y: end.y - k * endTangent.y)
      elements.append(.curve(end, control1: c1, control2: c2))
      t = t2
      start = end
      startTangent = endTangent
    }
  }

  // MARK: Lexing

  static func isCommand(_ b: UInt8) -> Bool {
    switch b {
    case UInt8(ascii: "M"), UInt8(ascii: "m"), UInt8(ascii: "L"), UInt8(ascii: "l"), UInt8(ascii: "H"),
         UInt8(ascii: "h"), UInt8(ascii: "V"), UInt8(ascii: "v"), UInt8(ascii: "C"), UInt8(ascii: "c"),
         UInt8(ascii: "S"), UInt8(ascii: "s"), UInt8(ascii: "Q"), UInt8(ascii: "q"), UInt8(ascii: "T"),
         UInt8(ascii: "t"), UInt8(ascii: "A"), UInt8(ascii: "a"), UInt8(ascii: "Z"), UInt8(ascii: "z"):
      true
    default: false
    }
  }

  static func startsNumber(_ b: UInt8) -> Bool {
    (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")) || b == UInt8(ascii: "-") || b == UInt8(ascii: "+")
      || b == UInt8(ascii: ".")
  }

  mutating func skipSeparators() {
    while i < bytes.count, bytes[i] == UInt8(ascii: " ") || bytes[i] == UInt8(ascii: ",")
      || bytes[i] == UInt8(ascii: "\n") || bytes[i] == UInt8(ascii: "\t") || bytes[i] == UInt8(ascii: "\r")
    {
      i += 1
    }
  }

  mutating func point(_ base: CGPoint) throws -> CGPoint {
    let x = try number(), y = try number()
    return CGPoint(x: base.x + x, y: base.y + y)
  }

  /// An arc flag: a single "0" or "1", with or without a separator after it.
  mutating func flag() throws -> Bool {
    skipSeparators()
    guard i < bytes.count else { throw SVGPath.ParseError.missingNumber(at: i) }
    switch bytes[i] {
    case UInt8(ascii: "0"): i += 1; return false
    case UInt8(ascii: "1"): i += 1; return true
    default: throw SVGPath.ParseError.unexpected(Character(Unicode.Scalar(bytes[i])), at: i)
    }
  }

  /// A number in SVG's grammar: sign, digits, one point, an exponent. A second point or a sign
  /// starts the next number ("1.5.5" is 1.5 then .5; "2-3" is 2 then -3).
  mutating func number() throws -> Double {
    skipSeparators()
    let start = i
    if i < bytes.count, bytes[i] == UInt8(ascii: "-") || bytes[i] == UInt8(ascii: "+") { i += 1 }
    var sawDigit = false, sawPoint = false
    while i < bytes.count {
      let b = bytes[i]
      if b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") {
        sawDigit = true
        i += 1
      } else if b == UInt8(ascii: "."), !sawPoint {
        sawPoint = true
        i += 1
      } else if (b == UInt8(ascii: "e") || b == UInt8(ascii: "E")), sawDigit {
        let save = i
        i += 1
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") || bytes[i] == UInt8(ascii: "+") { i += 1 }
        var expDigits = false
        while i < bytes.count, bytes[i] >= UInt8(ascii: "0") && bytes[i] <= UInt8(ascii: "9") {
          i += 1
          expDigits = true
        }
        if !expDigits { i = save }
        break
      } else {
        break
      }
    }
    guard sawDigit, let text = String(bytes: bytes[start..<i], encoding: .ascii), let value = Double(text) else {
      throw SVGPath.ParseError.missingNumber(at: start)
    }
    return value
  }
}
