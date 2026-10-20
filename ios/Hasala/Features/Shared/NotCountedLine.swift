import HasalaDesign
import HasalaModels
import SwiftUI

struct NotCountedLine: View {
  let text: String
  let spoken: String
  let icon: HIcon
  let id: String
  let action: () -> Void

  @Environment(\.dynamicTypeSize) private var typeSize
  @ScaledMetric(relativeTo: .subheadline) private var lane: CGFloat = 20

  var body: some View {
    Button(action: action) {
      if typeSize.isAccessibilitySize {
        HStack(alignment: .top, spacing: 12) {
          mark(32, glyph: 18, stroke: 2.2)
            .frame(height: lane)
          label
        }
        .padding(.vertical, 10)
      } else {
        HStack(spacing: 8) {
          mark(20, glyph: 12, stroke: 2.4)
          label
          HIconView(.chevronRight, size: 14, color: HColor.iconTertiary, strokeWidth: 2.4)
        }
      }
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity, minHeight: HSpacing.targetMinimum, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier(id)
  }

  private var label: some View {
    Text(text)
      .hType(.subheadline)
      .foregroundStyle(HColor.textOnWashSecondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func mark(_ side: CGFloat, glyph: CGFloat, stroke: CGFloat) -> some View {
    Circle()
      .fill(Hue.peach.perceptualGradient)
      .frame(width: side, height: side)
      .overlay { HIconView(icon, size: glyph, color: Hue.peach.ink, strokeWidth: stroke) }
      .accessibilityHidden(true)
  }
}

extension NotCountedLine {
  init(_ mark: TotalMark, line: String, id: String, inProfileSheet: Bool, app: AppModel) {
    self.init(text: line, spoken: line, icon: .globe, id: id) {
      let path: [ProfileRoute] = [.exchangeRates] + (mark.currency.map { [.editRate($0)] } ?? [])
      if inProfileSheet {
        app.router.profile.append(contentsOf: path)
      } else {
        app.router.open(.profile, profile: path)
      }
    }
  }
}
