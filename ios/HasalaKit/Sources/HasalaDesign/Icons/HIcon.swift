import HasalaModels
import SwiftUI

// Hasala's own icons (spec 01 page 05, appendix B): plain line drawings on a 24 grid, round
// caps and joins, kept inside about 3–21. They replace SF Symbols for categories, glass
// buttons, tab glyphs, row icons and provider marks. Every path is copied from the Paper
// boards ("Source" in each comment); the few the boards do not draw are marked "drawn to the
// page 05 rules". The size sets the stroke (`HIconView`), the container sets the colour.

/// One stroke or fill of an icon, in its viewBox units.
public struct IconElement: Sendable, Hashable {
  public enum Paint: Sendable, Hashable {
    case stroke(width: CGFloat, roundCaps: Bool, roundJoins: Bool)
    case fill
  }

  /// SVG path data; rects and circles are written as paths.
  public let d: String
  public let paint: Paint
  /// A fixed colour (third-party marks, the white door on Home); nil takes the icon's colour.
  public let color: HRGBA?

  init(_ d: String, _ paint: Paint, color: HRGBA? = nil) {
    self.d = d
    self.paint = paint
    self.color = color
  }
}

/// Every icon in the app.
public enum HIcon: String, CaseIterable, Sendable, Hashable {
  // Categories (40 pt disc, 20 pt icon, bucket ink).
  case rent, utilities, groceries, transport, healthcare, insurance
  case dining, entertainment, shopping, travel, subscriptions
  case savings, investments, debt
  case salary, freelance
  case transfer, refunds, project
  // Glass buttons and navigation.
  case eye, eyeSlash, bell, back, close, add, more, share, filter, done
  case tabHome, tabPlan, tabReview, tabActivity, magnifier
  // Rows, cards and screens.
  case check, chevronRight, chevronDown, chevronUp, minus, delete
  case lock, lockKeyhole, key, shield, shieldCheck, privacy, faceID, passkey, password
  case envelope, mailX, phone, iPad, cloud, paper, info, calendar, clock, history
  case download, trash, linkOff, wand, rule, split, pencil, refund, swap, archive
  case globe, appearance, help, tag, receipt, bank, cash, trendUp, monitor, chat, mic, cameraSlash, swipe
  case gauge, reviewSheet
  // Other companies' marks, in their own colours (page 15 · Mailboxes).
  case google, microsoft

  /// How the stroke follows the size (page 05 §5.1).
  public enum Role: Sendable, Hashable {
    /// Names a thing (categories, header and row icons): 1.9, 2.0 at 16 pt, 1.7 at 28 pt and up.
    case describing
    /// A single mark you press or follow (back, close, add, chevrons, checks): its drawn width.
    case acting
    /// Filled shapes (tab glyphs, More, marks): no stroke.
    case filled
  }
}

public extension HIcon {
  var role: Role {
    switch self {
    case .back, .close, .add, .check, .done, .chevronRight, .chevronDown, .chevronUp, .minus: .acting
    case .more, .tabHome, .tabPlan, .tabReview, .google, .microsoft: .filled
    default: .describing
    }
  }

  /// The side of the square viewBox the elements are drawn in.
  var viewBox: CGFloat {
    switch self {
    case .google: 48
    case .microsoft: 23
    default: 24
    }
  }

  /// The main stroke width as drawn (the width a size rule replaces).
  var drawnStroke: CGFloat { HIcon.drawings[self]?.drawnStroke ?? 0 }

  /// The stroke for this icon at `size` points, in viewBox units.
  func stroke(at size: CGFloat) -> CGFloat {
    switch role {
    case .filled: 0
    case .acting: drawnStroke
    case .describing:
      if size <= 16 { 2.0 } else if size >= 28 { 1.7 } else { drawnStroke }
    }
  }

  /// The elements as Paper draws them.
  var elements: [IconElement] { HIcon.drawings[self]?.elements ?? [] }

  /// The parsed paths, one per element (parsed once per process).
  var paths: [SVGPath] { HIcon.drawings[self]?.paths ?? [] }

  /// Every element parses (IconTests checks this on the real data).
  private static let drawings: [HIcon: IconDrawing] = {
    var out: [HIcon: IconDrawing] = [:]
    for icon in HIcon.allCases {
      let elements = icon.drawnElements
      var stroke: CGFloat = 0
      for e in elements {
        if case .stroke(let w, _, _) = e.paint {
          stroke = w
          break
        }
      }
      out[icon] = IconDrawing(
        elements: elements,
        paths: elements.map { (try? SVGPath(parsing: $0.d)) ?? SVGPath(elements: []) },
        drawnStroke: stroke)
    }
    return out
  }()
}

private struct IconDrawing: Sendable {
  let elements: [IconElement]
  let paths: [SVGPath]
  let drawnStroke: CGFloat
}

// MARK: - The drawings

private func line(_ d: String, _ w: CGFloat = 1.9, caps: Bool = true, joins: Bool = true) -> IconElement {
  IconElement(d, .stroke(width: w, roundCaps: caps, roundJoins: joins))
}

private func fill(_ d: String, _ color: HRGBA? = nil) -> IconElement { IconElement(d, .fill, color: color) }

/// `<rect>` as path data: corners of radius `r` (SVG `rx`).
func rectPath(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: CGFloat = 0) -> String {
  func n(_ v: CGFloat) -> String {
    let s = String(format: "%.3f", v)
    return s.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
  }
  if r <= 0 { return "M\(n(x)) \(n(y))H\(n(x + w))V\(n(y + h))H\(n(x))Z" }
  return "M\(n(x + r)) \(n(y))H\(n(x + w - r))A\(n(r)) \(n(r)) 0 0 1 \(n(x + w)) \(n(y + r))"
    + "V\(n(y + h - r))A\(n(r)) \(n(r)) 0 0 1 \(n(x + w - r)) \(n(y + h))H\(n(x + r))"
    + "A\(n(r)) \(n(r)) 0 0 1 \(n(x)) \(n(y + h - r))V\(n(y + r))A\(n(r)) \(n(r)) 0 0 1 \(n(x + r)) \(n(y))Z"
}

/// `<circle>` as path data: two half arcs.
func circlePath(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> String {
  "M\(cx - r) \(cy)A\(r) \(r) 0 1 0 \(cx + r) \(cy)A\(r) \(r) 0 1 0 \(cx - r) \(cy)Z"
}

private let white = HRGBA(255, 255, 255, 1)

private extension HIcon {
  var drawnElements: [IconElement] {
    switch self {
    // Source: appendix B (page 05 category set).
    case .rent:
      [line("M4 10.4 12 4l8 6.4V19a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 19z", caps: false),
       line("M9.5 20.5V15h5v5.5", caps: false)]
    case .utilities:
      [line("M13 2.5 5.5 13.5h5.5l-1 8 7.5-11h-5.5l1-8Z", caps: false)]
    case .groceries:
      [line("M3.5 9.5h17l-1.7 9.2a2 2 0 0 1-2 1.6H7.2a2 2 0 0 1-2-1.6z", caps: false),
       line("M8.5 9.5 11 4.5M15.5 9.5 13 4.5M9.5 13.5V17M14.5 13.5V17", joins: false)]
    case .transport:
      [line("M5 13.5 6.8 8.4A2 2 0 0 1 8.7 7h6.6a2 2 0 0 1 1.9 1.4l1.8 5.1", caps: false),
       line(rectPath(3.5, 13, 17, 5.5, r: 2), caps: false, joins: false),
       line("M6.5 18.5V20M17.5 18.5V20", joins: false)]
    case .healthcare:
      [line("M9.5 4h5v5.5H20v5h-5.5V20h-5v-5.5H4v-5h5.5z", caps: false)]
    case .insurance:
      [line("M12 3.5 19 6v5.5c0 4.3-2.9 7.6-7 9-4.1-1.4-7-4.7-7-9V6z", caps: false),
       line("m9 12 2.2 2.2L15.5 10")]
    case .dining:
      [line("M7 3.5v17M4.5 3.5v5a2.5 2.5 0 0 0 5 0v-5"),
       line("M17.5 20.5v-17c-2.2 1-3.5 3.6-3.5 7V14h3.5")]
    case .entertainment:
      [line("M3.5 7.5A1.5 1.5 0 0 1 5 6h14a1.5 1.5 0 0 1 1.5 1.5v2.7a2 2 0 0 0 0 3.6v2.7A1.5 1.5 0 0 1 19 18H5a1.5 1.5 0 0 1-1.5-1.5v-2.7a2 2 0 0 0 0-3.6z", caps: false),
       line("M14.5 7v1.6M14.5 11.2v1.6M14.5 15.4V17", joins: false)]
    case .shopping:
      [line("M5.5 8h13l-1 12.5h-11z", caps: false),
       line("M9 10.5V7a3 3 0 0 1 6 0v3.5", joins: false)]
    case .travel:
      [line("M17.8 19.2 16 11l3.5-3.5C21 6 21.5 4 21 3c-1-.5-3 0-4.5 1.5L13 8 4.8 6.2c-.5-.1-.9.1-1.1.5l-.3.5c-.2.5-.1 1 .3 1.3L9 12l-2 3H4l-1 1 3 2 2 3 1-1v-3l3-2 3.5 5.3c.3.4.8.5 1.3.3l.5-.2c.4-.3.6-.7.5-1.2z", 1.7, caps: false)]
    case .subscriptions:
      [line("M17 3.5l3 3-3 3M7 20.5l-3-3 3-3"),
       line("M4 11.5v-1a4 4 0 0 1 4-4h12M20 12.5v1a4 4 0 0 1-4 4H4", joins: false)]
    case .savings:
      [line("M8.5 3.5h7M9 3.5v2.3a4.6 4.6 0 0 0-3 4.3V18a2.5 2.5 0 0 0 2.5 2.5h7A2.5 2.5 0 0 0 18 18v-7.9a4.6 4.6 0 0 0-3-4.3V3.5"),
       line("M6 13h12", caps: false, joins: false)]
    case .investments:
      [line("M3.5 20.5h17", joins: false),
       line("M5 15.5l5-5 3.5 3.5L20 7.5M15.5 7.5H20V12")]
    case .debt:
      [line(rectPath(3, 5.5, 18, 13, r: 2.5), caps: false, joins: false),
       line("M3 10h18M7 15h3.5", joins: false)]
    case .salary:
      [line(rectPath(3.5, 7.5, 17, 12, r: 2.5), caps: false, joins: false),
       line("M9 7.5V6a2 2 0 0 1 2-2h2a2 2 0 0 1 2 2v1.5M3.5 13h17", joins: false)]
    case .freelance:
      [line(rectPath(5, 5, 14, 10, r: 1.5), caps: false, joins: false),
       line("M3 19h18l-1.6-4H4.6z", caps: false)]
    case .transfer:
      [line("M4 8.5h14.5L15 5M20 15.5H5.5L9 19")]
    case .refunds:
      [line("M6 3.5h12v17l-2-1.4-2 1.4-2-1.4-2 1.4-2-1.4-2 1.4z", caps: false),
       line("M9 8.5h6M9 12h6M9 15.5h3", joins: false)]
    case .project:
      [line("M5.5 21V4", joins: false),
       line("M5.5 4.5h11.5l-2.2 3.7 2.2 3.8H5.5", caps: false)]

    // Source: appendix B (page 05 glass set and tab bar).
    case .eye:
      [line("M2.8 12s3.4-6.3 9.2-6.3 9.2 6.3 9.2 6.3-3.4 6.3-9.2 6.3S2.8 12 2.8 12Z", caps: false),
       line(circlePath(12, 12, 2.9), caps: false, joins: false)]
    case .eyeSlash:
      [line("M9.6 6a9.8 9.8 0 0 1 2.4-.3c5.8 0 9.2 6.3 9.2 6.3a16 16 0 0 1-2.5 3.3M14.1 14.2A2.9 2.9 0 0 1 9.8 9.9M6.4 7.3C4 8.9 2.8 12 2.8 12s3.4 6.3 9.2 6.3c1.9 0 3.5-.6 4.9-1.5"),
       line("M4 4l16 16", joins: false)]
    case .bell:
      [line("M6 16V11a6 6 0 1 1 12 0v5l1.5 2h-15L6 16Z", caps: false),
       line("M10 20.5a2 2 0 0 0 4 0", joins: false)]
    case .back:
      [line("M14.5 5.5 8 12l6.5 6.5", 2.3)]
    case .close:
      [line("M6.5 6.5l11 11M17.5 6.5l-11 11", 2.3, joins: false)]
    case .add:
      [line("M12 5v14M5 12h14", 2.3, joins: false)]
    case .more:
      [fill(circlePath(5.5, 12, 1.9)), fill(circlePath(12, 12, 1.9)), fill(circlePath(18.5, 12, 1.9))]
    case .share:
      [line("M12 3.8v10.7M8.2 7.4 12 3.6l3.8 3.8"),
       line("M8.5 10.5H7.2a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h9.6a2 2 0 0 0 2-2v-6a2 2 0 0 0-2-2h-1.3", joins: false)]
    case .filter:
      [line("M4 7.5h9.5M18.5 7.5H20M4 16.5h1.5M10.5 16.5H20", joins: false),
       line(circlePath(16, 7.5, 2.4), caps: false, joins: false),
       line(circlePath(8, 16.5, 2.4), caps: false, joins: false)]
    case .done, .check:
      [line("M5.5 12.5l4.2 4.2 8.8-9.2", 2.4)]
    case .tabHome:
      [fill("M3 10a2 2 0 0 1 .709-1.528l7-5.999a2 2 0 0 1 2.582 0l7 5.999A2 2 0 0 1 21 10v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"),
       fill("M10 21v-6.5a.5.5 0 0 1 .5-.5h3a.5.5 0 0 1 .5.5V21", white)]
    case .tabPlan:
      [fill("M10.6 4.2a8.9 8.9 0 1 0 9.2 9.2h-9.2z"), fill("M13 2.1v8.9h8.9A8.9 8.9 0 0 0 13 2.1Z")]
    case .tabReview:
      [fill(rectPath(6, 2.5, 12, 3, r: 1.5)), fill(rectPath(4.5, 6.5, 15, 3, r: 1.5)),
       fill(rectPath(3, 10.5, 18, 11, r: 3))]
    case .tabActivity, .history:
      [line("M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8", 2),
       line("M3 3v5h5", 2), line("M12 7v5l4 2", 2)]
    case .magnifier:
      [line(circlePath(10.5, 10.5, 6.5), 2.2, caps: false, joins: false),
       line("M15.5 15.5 20 20", 2.4, joins: false)]

    // Source: P1 and P2 screens (rows, cards, sheets), read from the boards' JSX.
    case .chevronRight:  // Every row chevron (list-row-chevron, 16 pt).
      [line("M9 5.5 15.5 12 9 18.5", 2.4)]
    case .chevronDown:  // Period pill, 14 pt.
      [line("M6 9.5l6 6 6-6", 2.6)]
    case .chevronUp:  // Drawn to the page 05 rules: the period chevron turned over.
      [line("M6 14.5l6-6 6 6", 2.6)]
    case .minus:  // Dining budget stepper.
      [line("M5.5 12h13", 2.3, joins: false)]
    case .delete:  // Amount keypad delete key, 26 pt.
      [line("M9 5.5h10a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H9l-6-6.5z", caps: false),
       line("m11.5 9.5 5 5M16.5 9.5l-5 5", joins: false)]
    case .lock:  // Setup dock note (16 pt); recovery "Only you have them".
      [line(rectPath(5, 10.5, 14, 10, r: 2.5), caps: false, joins: false),
       line("M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5", joins: false)]
    case .lockKeyhole:  // Account frozen hero (30 pt, 1.8).
      [line(rectPath(5, 10.5, 14, 10, r: 2.6), 1.8, caps: false, joins: false),
       line("M8.2 10.5V8a3.8 3.8 0 0 1 7.6 0v2.5", 1.8, joins: false),
       line("M12 14.2v2.6", 1.8, joins: false)]
    case .key:  // Frozen "Sign in fully to unfreeze"; keep-safe cards.
      [line(circlePath(8, 12, 4), caps: false, joins: false),
       line("M12 12h8.5M17.5 12v3M20.5 12v2.2", joins: false)]
    case .shield:  // Frozen note "Didn't freeze it yourself?".
      [line("M12 3l7 3v5.5c0 4.3-3 7.9-7 9.5-4-1.6-7-5.2-7-9.5V6z", caps: false)]
    case .shieldCheck:  // Profile › Sign-in & security row.
      [line("M12 3.5 5 6.2v5.3c0 4.3 2.9 7.6 7 9 4.1-1.4 7-4.7 7-9V6.2l-7-2.7Z", 1.8, caps: false),
       line("m9 12 2.2 2.2L15.5 10", 1.8)]
    case .privacy:  // Profile › Privacy and data.
      [line("M12 3.5 19 6v5.5c0 4.3-2.9 7.6-7 9-4.1-1.4-7-4.7-7-9V6z", 1.8, caps: false),
       line(circlePath(12, 10.5, 1.8), 1.8, caps: false, joins: false),
       line("M12 12.3v3.2", 1.8, joins: false)]
    case .faceID:  // Sign-in & security passkey plate; Face ID lock row.
      [line("M3.5 8V6a2.5 2.5 0 0 1 2.5-2.5h2M16 3.5h2A2.5 2.5 0 0 1 20.5 6v2M20.5 16v2a2.5 2.5 0 0 1-2.5 2.5h-2M8 20.5H6A2.5 2.5 0 0 1 3.5 18v-2", joins: false),
       line("M8.5 9v1.5M15.5 9v1.5M12 9v4h-1M9 16a4.5 4.5 0 0 0 6 0")]
    case .passkey:  // Sign-in & security, a passkey on another account.
      [line(circlePath(9, 8, 3.5), caps: false, joins: false),
       line("M3 19c.6-3.3 3-5 6-5 1.4 0 2.6.3 3.6 1", joins: false),
       line(circlePath(17.5, 13.5, 2.5), caps: false, joins: false),
       line("M17.5 16v4.5M17.5 19h1.8", joins: false)]
    case .password:  // Sign-in & security, password row.
      [line(rectPath(2.5, 7, 19, 10, r: 3), caps: false, joins: false),
       line("M7 10.5v3M5.7 11.2l2.6 1.6M8.3 11.2l-2.6 1.6M12 10.5v3M10.7 11.2l2.6 1.6M13.3 11.2l-2.6 1.6", 1.5,
            joins: false),
       line("M16 13.5h3", joins: false)]
    case .envelope:  // Transaction detail provenance; bank email notes.
      [line(rectPath(3.5, 5.5, 17, 13, r: 2.5), caps: false, joins: false),
       line("m4.5 7.5 7.5 5.5 7.5-5.5")]
    case .mailX:  // Delete account, "access to your mailboxes is removed".
      [line("M20.5 11V8a2.5 2.5 0 0 0-2.5-2.5H5.5A2.5 2.5 0 0 0 3 8v8a2.5 2.5 0 0 0 2.5 2.5h6.5"),
       line("m3.8 7 8.2 6 8.2-6M16 15.5l4.5 4.5M20.5 15.5 16 20")]
    case .phone:  // Devices, "This iPhone"; recovery "For a new iPhone".
      [line(rectPath(6.5, 2.5, 11, 19, r: 2.8), caps: false, joins: false),
       line("M10.5 18.5h3", joins: false)]
    case .iPad:  // Devices, "Maya's iPad".
      [line(rectPath(4, 3, 16, 18, r: 2.5), caps: false, joins: false),
       line("M11 18h2", joins: false)]
    case .cloud:  // Who can see what, Cloudflare.
      [line("M7 18.5h10.5a3.5 3.5 0 0 0 .4-7A5.5 5.5 0 0 0 7.3 10 4.3 4.3 0 0 0 7 18.5Z", caps: false)]
    case .paper:  // Recovery phrase rows ("Write them on paper").
      [line("M6.5 3.5h8l3 3v14h-11z", caps: false),
       line("M9 11h6M9 14.5h6M9 18h3.5", joins: false)]
    case .info:  // Project card, "Not counted in your monthly plan" (14 pt).
      [line(circlePath(12, 12, 8.5), 2, caps: false, joins: false),
       line("M12 11v5.5M12 7.5v.5", 2.2, joins: false)]
    case .calendar:  // Drawn to the page 05 rules (no board draws one yet).
      [line(rectPath(3.5, 5, 17, 15.5, r: 2.5), caps: false, joins: false),
       line("M3.5 10h17M8 3v4M16 3v4", joins: false)]
    case .clock:  // Delete account, "within 30 days".
      [line(circlePath(12, 12, 8.5), caps: false, joins: false), line("M12 7.5V12l3 2")]
    case .download:  // Export your data (CSV).
      [line("M12 4v11M7.5 10.5 12 15l4.5-4.5M5 19.5h14", 1.8)]
    case .trash:  // Delete account, "erased here and on our server".
      [line("M4.5 7h15M9.5 7V4.5h5V7M6.5 7l.9 12.2a1.5 1.5 0 0 0 1.5 1.3h6.2a1.5 1.5 0 0 0 1.5-1.3L17.5 7")]
    case .linkOff:  // Delete account, "passkeys and password stop working".
      [line("M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1.2 1.2"),
       line("M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1.2-1.2"),
       line("M4 4l16 16", joins: false)]
    case .wand:  // Plan · Dining, "Rules that sort into Dining".
      [line("M4.5 19.5 14 10", joins: false),
       line("M16.5 3.5v3M15 5h3M19.5 9v2.5M18.25 10.25h2.5M10 4v2M9 5h2", 1.7, joins: false)]
    case .rule:  // Provenance, "Sorted by your rule".
      [line(circlePath(6, 5.5, 2.3), caps: false, joins: false),
       line("M6 8v4.5a3.5 3.5 0 0 0 3.5 3.5H19", joins: false),
       line("M15.5 12.5 19 16l-3.5 3.5")]
    case .split:  // Transaction actions, "Split across categories".
      [line("M12 21v-7.5L6 7.5M12 13.5l6-6"), line("M5.5 11.5v-4.5H10M18.5 11.5v-4.5H14")]
    case .pencil:  // "Rename merchant".
      [line("M4.5 19.5h4l10.3-10.3a2.1 2.1 0 0 0-3-3L5.5 16.5z", caps: false),
       line("m14 8 3 3", joins: false)]
    case .refund:  // "This is a refund".
      [line("M9 14.5 4 9.5l5-5"), line("M4.5 9.5h10a5 5 0 0 1 0 10H11", joins: false)]
    case .swap:  // "Mark as a transfer".
      [line("M16.5 3.5 20 7l-3.5 3.5M20 7H5M7.5 13.5 4 17l3.5 3.5M4 17h15")]
    case .archive:  // "Archive".
      [line(rectPath(3.5, 4.5, 17, 4.5, r: 1.5), caps: false, joins: false),
       line("M5 9v8.5a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V9M10 13h4")]
    case .globe:  // Settings, Currency.
      [line(circlePath(12, 12, 8.5), 1.8, caps: false, joins: false),
       line("M3.5 12h17M12 3.5c2.3 2.4 3.4 5.2 3.4 8.5s-1.1 6.1-3.4 8.5c-2.3-2.4-3.4-5.2-3.4-8.5s1.1-6.1 3.4-8.5Z", 1.8,
            caps: false, joins: false)]
    case .appearance:  // Settings, Appearance.
      [line(circlePath(12, 12, 8.5), 1.8, caps: false, joins: false), fill("M12 3.5a8.5 8.5 0 0 1 0 17z")]
    case .help:  // Settings, Get help.
      [line(circlePath(12, 12, 8.5), 1.8, caps: false, joins: false),
       line("M9.6 9.6a2.5 2.5 0 0 1 4.8.8c0 1.7-2.4 2-2.4 3.6", 1.8), fill(circlePath(12, 16.9, 1.1))]
    case .tag:  // Your money, Categories and rules.
      [line("M3.5 4.8v6.4c0 .4.2.8.4 1.1l8 8a1.5 1.5 0 0 0 2.1 0l6.3-6.3a1.5 1.5 0 0 0 0-2.1l-8-8a1.5 1.5 0 0 0-1.1-.4H4.8a1.3 1.3 0 0 0-1.3 1.3Z", caps: false),
       fill(circlePath(8.2, 8.2, 1.6))]
    case .receipt:  // Your money, Bills.
      [line("M6 3.5h12v17l-2-1.3-2 1.3-2-1.3-2 1.3-2-1.3-2 1.3z", caps: false),
       line("M9 8.5h6M9 12h6M9 15.5h3", joins: false)]
    case .bank:  // Your money, Accounts.
      [line("M3.5 9 12 4.5 20.5 9"), line("M6 10.5v6.5M10 10.5v6.5M14 10.5v6.5M18 10.5v6.5M3.5 19.5h17", joins: false)]
    case .cash:  // Accounts, Cash.
      [line(rectPath(2.5, 6, 19, 12, r: 2.5), caps: false, joins: false),
       line(circlePath(12, 12, 2.6), caps: false, joins: false),
       line("M6 9.5v.01M18 14.5v.01", 2.4, joins: false)]
    case .trendUp:  // Net worth widget.
      [line("M5 15.5l5-5 3.5 3.5L20 7.5M15.5 7.5H20V12", 2)]
    case .gauge:
      [line("M4 15a8 8 0 0 1 16 0", 2), line("M12 15l3.5-4.5", 2), fill(circlePath(12, 15, 1.6))]
    case .reviewSheet:
      [line(rectPath(5, 4, 14, 16, r: 3), 2, caps: false, joins: false), line("M9 9h6M9 13h4", 2, joins: false)]
    case .monitor:  // Notifications, "6 transactions to sort" (the To review glyph).
      [line(rectPath(4, 5, 16, 11, r: 2.5), caps: false, joins: false), line("M7 19.5h10", joins: false)]
    case .chat:  // Search, Try asking.
      [line("M5 5h14a1.5 1.5 0 0 1 1.5 1.5v8.5a1.5 1.5 0 0 1-1.5 1.5h-7.5L7 20v-3.5H5A1.5 1.5 0 0 1 3.5 15V6.5A1.5 1.5 0 0 1 5 5z", 2,
            caps: false)]
    case .mic:  // Search field, dictation.
      [fill(rectPath(9, 3, 6, 11, r: 3)), line("M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21", 2, joins: false)]
    case .cameraSlash:  // Recovery phrase, "No screenshots or copying".
      [line(rectPath(3, 6, 18, 13, r: 3), caps: false, joins: false),
       line(circlePath(12, 12.5, 3.2), caps: false, joins: false),
       line("M8.5 6l1.2-2h4.6l1.2 2M3 3l18 18")]
    case .swipe:  // Settings, Swipe directions.
      [line("M4 12h16M8 8l-4 4 4 4M16 8l4 4-4 4", 1.8)]

    // Source: appendix B and page 15 · Mailboxes. Never recoloured.
    case .google:
      [fill("M24 9.5c3.540 0 6.710 1.220 9.210 3.600l6.850-6.850C35.900 2.380 30.470 0 24 0 14.620 0 6.510 5.380 2.560 13.220l7.980 6.190C12.430 13.720 17.740 9.500 24 9.500z", HRGBA(0xEA, 0x43, 0x35, 1)),
       fill("M46.980 24.550c0-1.570-.150-3.090-.380-4.550H24v9.020h12.940c-.580 2.960-2.260 5.480-4.780 7.180l7.730 6c4.510-4.180 7.090-10.360 7.090-17.650z", HRGBA(0x42, 0x85, 0xF4, 1)),
       fill("M10.530 28.590c-.480-1.450-.760-2.990-.760-4.590s.270-3.140.760-4.590l-7.980-6.190C.920 16.460 0 20.120 0 24c0 3.880.920 7.540 2.560 10.780l7.970-6.190z", HRGBA(0xFB, 0xBC, 0x05, 1)),
       fill("M24 48c6.480 0 11.930-2.130 15.890-5.810l-7.730-6c-2.150 1.450-4.920 2.300-8.160 2.300-6.260 0-11.570-4.220-13.470-9.910l-7.980 6.190C6.510 42.620 14.620 48 24 48z", HRGBA(0x34, 0xA8, 0x53, 1))]
    case .microsoft:
      [fill(rectPath(0, 0, 11, 11), HRGBA(0xF2, 0x50, 0x22, 1)), fill(rectPath(12, 0, 11, 11), HRGBA(0x7F, 0xBA, 0x00, 1)),
       fill(rectPath(0, 12, 11, 11), HRGBA(0x00, 0xA4, 0xEF, 1)), fill(rectPath(12, 12, 11, 11), HRGBA(0xFF, 0xB9, 0x00, 1))]
    }
  }
}

/// An icon at a size and colour. The stroke follows the size (page 05): describing icons
/// draw 1.9 (2.0 at 16 pt and under, 1.7 at 28 and up); acting icons keep their drawn width.
/// Decorative by default: the row or button around it carries the words.
public struct HIconView: View {
  let icon: HIcon
  let size: CGFloat
  let color: Color
  let strokeWidth: CGFloat?

  /// `strokeWidth` overrides the size rule, in grid units (settings rows draw 1.8).
  public init(_ icon: HIcon, size: CGFloat = 24, color: Color = HColor.iconPrimary, strokeWidth: CGFloat? = nil) {
    self.icon = icon
    self.size = size
    self.color = color
    self.strokeWidth = strokeWidth
  }

  public var body: some View {
    Canvas { context, canvasSize in
      let box = CGRect(origin: .zero, size: canvasSize)
      let viewBox = CGRect(x: 0, y: 0, width: icon.viewBox, height: icon.viewBox)
      let unit = min(canvasSize.width, canvasSize.height) / icon.viewBox
      let target = strokeWidth ?? icon.stroke(at: size)
      let base = icon.drawnStroke
      for (element, svg) in zip(icon.elements, icon.paths) {
        let path = svg.path(in: box, viewBox: viewBox)
        let shading = GraphicsContext.Shading.color(element.color.map { Color($0) } ?? color)
        switch element.paint {
        case .fill:
          context.fill(path, with: shading)
        case .stroke(let width, let roundCaps, let roundJoins):
          let drawn = base > 0 ? width * target / base : width
          context.stroke(path, with: shading, style: StrokeStyle(
            lineWidth: drawn * unit, lineCap: roundCaps ? .round : .butt, lineJoin: roundJoins ? .round : .miter))
        }
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

public extension Glyph {
  /// The drawing for this semantic glyph.
  var icon: HIcon {
    switch self {
    case .review: .monitor
    case .insurance: .insurance
    case .utilities: .utilities
    case .travel: .travel
    case .savingsJar: .savings
    case .dining: .dining
    case .budgetPie: .tabPlan
    case .trendUp: .trendUp
    case .add: .add
    case .rent: .rent
    case .groceries: .groceries
    case .transport: .transport
    case .shopping: .shopping
    case .salary: .salary
    case .transfer: .transfer
    case .flag: .project
    case .healthcare: .healthcare
    case .entertainment: .entertainment
    case .subscriptions: .subscriptions
    case .investments: .investments
    case .debt: .debt
    case .freelance: .freelance
    case .refunds: .refunds
    case .bank: .bank
    case .tag: .tag
    case .bill: .receipt
    case .wallet: .cash
    case .envelope: .envelope
    case .rule: .rule
    }
  }
}
