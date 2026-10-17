import SwiftUI

/// Two or three views of one thing (page 12 §05): a 36 track in `apple-fills-tertiary` with a
/// white thumb that slides to the selected segment (`.thumbSlide`; with Reduce Motion it
/// jumps). Segments share the width; labels are one word, 14/18, 600 selected and 500 not. At
/// the accessibility text sizes the control becomes a list with ticks.
public struct HSegmentedControl<Value: Hashable>: View {
  let items: [Value]
  @Binding var selection: Value
  let title: (Value) -> String
  @Environment(\.dynamicTypeSize) private var typeSize
  @ResolvedMotion private var motion: MotionPolicy
  @Namespace private var thumb

  public init(_ items: [Value], selection: Binding<Value>, title: @escaping (Value) -> String) {
    self.items = items
    _selection = selection
    self.title = title
  }

  public var body: some View {
    if typeSize.isAccessibilitySize { list } else { track }
  }

  private var track: some View {
    HStack(spacing: 0) {
      ForEach(Array(items.enumerated()), id: \.element) { index, item in
        let selected = item == selection
        Button {
          withAnimation(motion.animation(.thumbSlide)) { selection = item }
        } label: {
          Text(title(item))
            .hType(HType(size: 14, leading: 18, weight: selected ? .semibold : .medium, textStyle: .subheadline))
            .foregroundStyle(HColor.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background {
              if selected {
                Capsule()
                  .fill(HColor.appleSegmentedControlSelectedFill)
                  .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 2)
                  .overlay { Capsule().strokeBorder(.black.opacity(0.04), lineWidth: 0.5) }
                  .matchedGeometryEffect(id: "thumb", in: thumb)
              }
            }
            // Drawn 36 tall; the hit area reaches 44.
            .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue("\(index + 1) of \(items.count)")
      }
    }
    .padding(2)
    .frame(minHeight: 36)
    .background(HColor.appleFillsTertiary, in: Capsule())
  }

  private var list: some View {
    VStack(spacing: 0) {
      ForEach(Array(items.enumerated()), id: \.element) { index, item in
        let selected = item == selection
        Button {
          selection = item
        } label: {
          HStack(spacing: 12) {
            Text(title(item)).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
            Spacer(minLength: 8)
            if selected { HIconView(.check, size: 22, color: HColor.listRowCheck) }
          }
          .padding(.horizontal, HSpacing.listRowInsetInline)
          .frame(minHeight: HSpacing.listRowMinHeight)
          .contentShape(Rectangle())
        }
        .buttonStyle(HRowPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue("\(index + 1) of \(items.count)")
        if index < items.count - 1 { HDivider(inset: .text16) }
      }
    }
    .listCard()
    .clipShape(RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
  }
}

public extension HSegmentedControl where Value == String {
  /// Segments whose values are their labels.
  init(_ items: [String], selection: Binding<String>) {
    self.init(items, selection: selection) { $0 }
  }
}
