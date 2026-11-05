import SwiftUI

public enum HContrastEdge {
  public static let color = HColor.borderControl
  public static let width: CGFloat = 1

  public static func isShown(contrast: ColorSchemeContrast, forced: Bool) -> Bool {
    forced || contrast == .increased
  }
}

public extension EnvironmentValues {
  @Entry var hIncreasedContrast = false
}

struct ContrastStrokeModifier<S: Shape>: ViewModifier {
  let shape: S
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.hIncreasedContrast) private var forced

  func body(content: Content) -> some View {
    content.overlay {
      if HContrastEdge.isShown(contrast: contrast, forced: forced) {
        shape.stroke(HContrastEdge.color, lineWidth: HContrastEdge.width)
          .allowsHitTesting(false)
      }
    }
  }
}

struct ContrastEdgeModifier<S: InsettableShape>: ViewModifier {
  let shape: S
  let active: Bool
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.hIncreasedContrast) private var forced

  func body(content: Content) -> some View {
    content.overlay {
      if active, HContrastEdge.isShown(contrast: contrast, forced: forced) {
        shape.strokeBorder(HContrastEdge.color, lineWidth: HContrastEdge.width)
          .allowsHitTesting(false)
      }
    }
  }
}

public extension View {
  func hContrastEdge<S: Shape>(_ shape: S) -> some View {
    modifier(ContrastStrokeModifier(shape: shape))
  }

  func hContrastEdge<S: InsettableShape>(_ shape: S, active: Bool = true) -> some View {
    modifier(ContrastEdgeModifier(shape: shape, active: active))
  }
}

public extension Text {
  static func fieldPrompt(_ prompt: String) -> Text {
    Text(prompt).foregroundStyle(HColor.fieldHint)
  }
}

#if canImport(UIKit)
  import UIKit

  public extension NSAttributedString {
    static func fieldPrompt(_ prompt: String) -> NSAttributedString {
      NSAttributedString(string: prompt, attributes: [.foregroundColor: UIColor(HColor.fieldHint)])
    }
  }
#endif
