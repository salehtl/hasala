import CoreGraphics
import SwiftUI
import Testing

@testable import HasalaDesign

@MainActor
@Suite("Glass badges")
struct GlassBadgeTests {
  static let inset: CGFloat = 12

  struct Pixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    func badgePoints(near target: (Double, Double, Double)) -> [(x: Int, y: Int)] {
      var points: [(x: Int, y: Int)] = []
      for y in 0..<height {
        for x in 0..<width {
          let i = (y * width + x) * 4
          let r = Double(bytes[i]) / 255, g = Double(bytes[i + 1]) / 255, b = Double(bytes[i + 2]) / 255
          if abs(r - target.0) < 0.06 && abs(g - target.1) < 0.06 && abs(b - target.2) < 0.06 {
            points.append((x, y))
          }
        }
      }
      return points
    }
  }

  func render<V: View>(_ view: V, direction: LayoutDirection = .leftToRight) throws -> Pixels {
    let renderer = ImageRenderer(
      content: view
        .padding(Self.inset)
        .background(Color.white)
        .environment(\.layoutDirection, direction)
        .environment(\.colorScheme, .light))
    renderer.scale = 1
    let image = try #require(renderer.cgImage)
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
      CGContext(
        data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return Pixels(width: width, height: height, bytes: bytes)
  }

  var badgeFill: (Double, Double, Double) {
    var environment = EnvironmentValues()
    environment.colorScheme = .light
    let c = HColor.badgeCount.resolve(in: environment)
    return (Double(c.red), Double(c.green), Double(c.blue))
  }

  @Test func aPairedButtonLeavesItsBadgeOutOfTheGlass() throws {
    let paired = try render(
      GlassIconButton(.bell, label: "Notifications", badge: 4) {}
        .environment(\.hGlassPaired, true))
    #expect(paired.badgePoints(near: badgeFill).isEmpty)

    let alone = try render(GlassIconButton(.bell, label: "Notifications", badge: 4) {})
    #expect(!alone.badgePoints(near: badgeFill).isEmpty)
  }

  @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft])
  func thePairDrawsTheBadgePastTheCapsuleOnTheBell(direction: LayoutDirection) throws {
    let pixels = try render(
      GlassButtonPair {
        GlassIconButton(.magnifier, label: "Search") {}
        GlassIconButton(.bell, label: "Notifications", badge: 4) {}
      },
      direction: direction)
    let points = pixels.badgePoints(near: badgeFill)
    #expect(!points.isEmpty)
    let top = Int(Self.inset)
    #expect(points.contains { $0.y < top })
    let middle = pixels.width / 2
    if direction == .leftToRight {
      #expect(points.allSatisfy { $0.x > middle })
    } else {
      #expect(points.allSatisfy { $0.x < middle })
    }
  }

  @Test(arguments: [12, 100])
  func aLongCountStaysOnOneLine(count: Int) throws {
    let views: [AnyView] = [
      AnyView(GlassIconButton(.bell, label: "Notifications", badge: count) {}),
      AnyView(
        GlassButtonPair {
          GlassIconButton(.magnifier, label: "Search") {}
          GlassIconButton(.bell, label: "Notifications", badge: count) {}
        }),
    ]
    for view in views {
      let points = try render(view).badgePoints(near: badgeFill)
      try #require(!points.isEmpty)
      let height = points.map(\.y).max()! - points.map(\.y).min()! + 1
      let width = points.map(\.x).max()! - points.map(\.x).min()! + 1
      #expect(height <= 21)
      #expect(width > height)
    }
  }

  @Test func aPairWithNoCountDrawsNoBadge() throws {
    let pixels = try render(
      GlassButtonPair {
        GlassIconButton(.magnifier, label: "Search") {}
        GlassIconButton(.bell, label: "Notifications", badge: 0) {}
      })
    #expect(pixels.badgePoints(near: badgeFill).isEmpty)
  }
}
