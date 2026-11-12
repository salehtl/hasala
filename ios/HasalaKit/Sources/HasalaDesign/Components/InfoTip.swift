import SwiftUI

public struct InfoTip: View {
  let message: String
  let topic: String
  @State private var shown = false
  @ScaledMetric(relativeTo: .subheadline) private var glyph: CGFloat = 15

  public init(_ message: String, about topic: String) {
    self.message = message
    self.topic = topic
  }

  public var body: some View {
    Button {
      shown = true
    } label: {
      Image(systemName: "info.circle")
        .font(.system(size: glyph, weight: .regular))
        .foregroundStyle(HColor.iconSecondary)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.vertical, -12)
    .padding(.horizontal, -12)
    .accessibilityLabel("About \(topic)")
    .accessibilityHint("Shows more detail")
    .popover(isPresented: $shown, arrowEdge: .top) {
      Text(message)
        .hType(.subheadline)
        .foregroundStyle(HColor.textPrimary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 280, alignment: .leading)
        .padding(16)
        .presentationCompactAdaptation(.popover)
    }
  }
}

extension View {
  public func infoTip(_ message: String?, about topic: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      self
      if let message {
        InfoTip(message, about: topic)
      }
    }
  }
}
