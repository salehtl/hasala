import HasalaDesign
import HasalaModels
import SwiftUI

struct CategoryFormIDs: Hashable {
  var name: String
  var icon: String

  static let editor = CategoryFormIDs(name: "categoryEditor.name", icon: "categoryEditor.icon")
}

struct CategoryNameIconForm<Between: View>: View {
  @Binding private var name: String
  @Binding private var glyph: Glyph
  private let hue: Hue
  private let ids: CategoryFormIDs
  private let nameFocus: FocusState<Bool>.Binding
  private let between: Between
  @ScaledMetric(relativeTo: .body) private var iconCell: CGFloat = 52
  @Environment(\.dynamicTypeSize) private var typeSize

  init(
    name: Binding<String>, glyph: Binding<Glyph>, hue: Hue, ids: CategoryFormIDs = .editor, nameFocus: FocusState<Bool>.Binding,
    @ViewBuilder between: () -> Between
  ) {
    _name = name
    _glyph = glyph
    self.hue = hue
    self.ids = ids
    self.nameFocus = nameFocus
    self.between = between()
  }

  var body: some View {
    CategoryFormField("Name") {
      TextField("Coffee", text: $name)
        .hType(.body)
        .foregroundStyle(HColor.fieldText)
        .textInputAutocapitalization(.words)
        .focused(nameFocus)
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(HColor.fieldSurfaceOnGrouped, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
        .accessibilityLabel("Name")
        .accessibilityIdentifier(ids.name)
    }
    between
    CategoryFormField("Icon") {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: iconCell), spacing: 8)], spacing: 8) {
        ForEach(CategoryLimits.glyphs, id: \.self) { g in
          Button { glyph = g } label: {
            CategoryDisc(hue: hue, icon: g.icon, size: typeSize.isAccessibilitySize ? .s56 : .s40)
              .padding(3)
              .overlay { Circle().strokeBorder(glyph == g ? hue.ink : .clear, lineWidth: 2) }
              .frame(maxWidth: .infinity, minHeight: max(44, iconCell))
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(CategoryLimits.glyphName(g))
          .accessibilityAddTraits(glyph == g ? [.isSelected] : [])
          .accessibilityIdentifier("\(ids.icon).\(g.rawValue)")
        }
      }
    }
  }
}

extension CategoryNameIconForm where Between == EmptyView {
  init(name: Binding<String>, glyph: Binding<Glyph>, hue: Hue, ids: CategoryFormIDs = .editor, nameFocus: FocusState<Bool>.Binding) {
    self.init(name: name, glyph: glyph, hue: hue, ids: ids, nameFocus: nameFocus) { EmptyView() }
  }
}

struct CategoryFormField<Content: View>: View {
  private let title: String
  private let content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).hType(.overline).foregroundStyle(HColor.textGroupedHeader)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 4)
        .accessibilityAddTraits(.isHeader)
      content
    }
  }
}
