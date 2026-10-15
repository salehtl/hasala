import CoreGraphics
import HasalaModels
import Testing

@testable import HasalaDesign

/// Every icon parses and stays inside its grid (spec 01 page 05: "Keep the drawing inside about
/// 3 to 21"), and the parser reads the path grammar Paper exports.
@Suite("Icons")
struct IconTests {
  @Test(arguments: HIcon.allCases)
  func everyIconParsesAndStaysInItsBox(icon: HIcon) throws {
    #expect(!icon.elements.isEmpty)
    for element in icon.elements {
      let path = try SVGPath(parsing: element.d)
      #expect(!path.elements.isEmpty, "\(icon): \(element.d)")
      let b = path.bounds
      let box = icon.viewBox
      // Line icons sit in the 24 grid with a margin; the two marks fill their own boxes.
      let margin: CGFloat = icon.role == .filled ? 0 : 1.5
      #expect(b.minX >= margin - 0.01 && b.minY >= margin - 0.01, "\(icon) starts at \(b.origin)")
      #expect(b.maxX <= box - margin + 0.01 && b.maxY <= box - margin + 0.01, "\(icon) ends at \(b.maxX), \(b.maxY)")
    }
    #expect(icon.paths.count == icon.elements.count)
  }

  @Test func theStrokeFollowsTheSize() {
    #expect(HIcon.groceries.stroke(at: 20) == 1.9)
    #expect(HIcon.groceries.stroke(at: 16) == 2.0)
    #expect(HIcon.groceries.stroke(at: 28) == 1.7)
    #expect(HIcon.travel.stroke(at: 20) == 1.7)
    #expect(HIcon.back.stroke(at: 22) == 2.3)
    #expect(HIcon.close.stroke(at: 16) == 2.3)
    #expect(HIcon.chevronRight.stroke(at: 16) == 2.4)
    #expect(HIcon.check.stroke(at: 14) == 2.4)
    #expect(HIcon.tabHome.stroke(at: 24) == 0)
  }

  @Test func everyGlyphHasADrawing() {
    let glyphs: [Glyph] = [
      .review, .insurance, .utilities, .travel, .savingsJar, .dining, .budgetPie, .trendUp, .add, .rent, .groceries,
      .transport, .shopping, .salary, .transfer, .flag, .healthcare, .entertainment, .subscriptions, .investments,
      .debt, .freelance, .refunds, .bank, .tag, .bill, .wallet, .envelope, .rule,
    ]
    #expect(Set(glyphs.map(\.icon)).count == glyphs.count)
    #expect(Glyph.dining.icon == .dining)
    #expect(Glyph.flag.icon == .project)
  }

  @Test func theMarksKeepTheirColours() {
    #expect(HIcon.google.elements.compactMap(\.color).map(\.description) == ["#EA4335", "#4285F4", "#FBBC05", "#34A853"])
    #expect(HIcon.microsoft.elements.compactMap(\.color).map(\.description) == ["#F25022", "#7FBA00", "#00A4EF", "#FFB900"])
    #expect(HIcon.google.viewBox == 48)
    #expect(HIcon.microsoft.viewBox == 23)
  }

  // MARK: Parser

  @Test func absoluteAndRelativeLines() throws {
    let p = try SVGPath(parsing: "M4 10.4 12 4l8 6.4V19H4z")
    #expect(p.elements == [
      .move(CGPoint(x: 4, y: 10.4)), .line(CGPoint(x: 12, y: 4)), .line(CGPoint(x: 20, y: 10.4)),
      .line(CGPoint(x: 20, y: 19)), .line(CGPoint(x: 4, y: 19)), .close,
    ])
  }

  @Test func compactNumbers() throws {
    // "1.5.5" is 1.5 then .5; "-.5" is a number; a sign starts the next number.
    let p = try SVGPath(parsing: "M1.5.5l-.5-1.5h2e1")
    #expect(p.elements == [.move(CGPoint(x: 1.5, y: 0.5)), .line(CGPoint(x: 1, y: -1)), .line(CGPoint(x: 21, y: -1))])
  }

  @Test func relativeMovesRepeatAsLines() throws {
    let p = try SVGPath(parsing: "m2 2 3 0 0 3z m1 1h1")
    #expect(p.elements == [
      .move(CGPoint(x: 2, y: 2)), .line(CGPoint(x: 5, y: 2)), .line(CGPoint(x: 5, y: 5)), .close,
      .move(CGPoint(x: 3, y: 3)), .line(CGPoint(x: 4, y: 3)),
    ])
  }

  @Test func smoothCurvesReflectTheirControl() throws {
    let p = try SVGPath(parsing: "M0 0C0 1 1 2 2 2S4 3 4 4")
    guard case .curve(_, _, let c2) = p.elements[1], case .curve(let end, let c1b, _) = p.elements[2] else {
      Issue.record("expected two curves")
      return
    }
    #expect(c2 == CGPoint(x: 1, y: 2))
    #expect(c1b == CGPoint(x: 3, y: 2))  // the reflection of (1, 2) about (2, 2)
    #expect(end == CGPoint(x: 4, y: 4))
  }

  @Test func quadraticsBecomeCubics() throws {
    let p = try SVGPath(parsing: "M0 0Q3 3 6 0T12 0")
    #expect(p.elements.count == 3)
    guard case .curve(let end, let c1, let c2) = p.elements[1] else {
      Issue.record("expected a curve")
      return
    }
    #expect(end == CGPoint(x: 6, y: 0))
    #expect(abs(c1.x - 2) < 1e-9 && abs(c1.y - 2) < 1e-9)
    #expect(abs(c2.x - 4) < 1e-9 && abs(c2.y - 2) < 1e-9)
  }

  /// A circle written as two arcs comes back as a circle: its box is the circle's.
  @Test func arcsFollowTheEllipse() throws {
    let p = try SVGPath(parsing: circlePath(12, 12, 8.5))
    let b = p.bounds
    #expect(abs(b.minX - 3.5) < 0.05 && abs(b.maxX - 20.5) < 0.05)
    #expect(abs(b.minY - 3.5) < 0.05 && abs(b.maxY - 20.5) < 0.05)
    // Flags written without separators ("0 011.5 1").
    let compact = try SVGPath(parsing: "M10 10a2 2 0 011.5 1")
    guard case .curve(let end, _, _) = compact.elements.last else {
      Issue.record("expected the arc as curves")
      return
    }
    #expect(abs(end.x - 11.5) < 1e-9 && abs(end.y - 11) < 1e-9)
  }

  @Test func roundedRectsKeepTheirBox() throws {
    let p = try SVGPath(parsing: rectPath(3.5, 13, 17, 5.5, r: 2))
    let b = p.bounds
    #expect(abs(b.minX - 3.5) < 0.01 && abs(b.maxX - 20.5) < 0.01)
    #expect(abs(b.minY - 13) < 0.01 && abs(b.maxY - 18.5) < 0.01)
  }

  @Test func badDataThrows() {
    #expect(throws: SVGPath.ParseError.self) { try SVGPath(parsing: "M1 1 X 3") }
    #expect(throws: SVGPath.ParseError.self) { try SVGPath(parsing: "L1 1") }
    #expect(throws: SVGPath.ParseError.self) { try SVGPath(parsing: "M1") }
    #expect(throws: SVGPath.ParseError.self) { try SVGPath(parsing: "M1 1A2 2 0 2 0 3 3") }
  }

  @Test func pathsScaleIntoTheirRect() throws {
    let p = try SVGPath(parsing: "M0 0L24 24")
    let drawn = p.path(in: CGRect(x: 10, y: 10, width: 48, height: 48)).boundingRect
    #expect(drawn == CGRect(x: 10, y: 10, width: 48, height: 48))
  }
}
