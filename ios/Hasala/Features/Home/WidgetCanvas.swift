import HasalaDesign
import HasalaModels
import SwiftUI

/// Canvas · Your widgets (Paper 14PE-0, page 18 §18.8): "Your widgets" 22/28 bold with "Edit",
/// then the widgets Maya arranges, 12 apart. Mediums take a full row; smalls pair two to a row
/// and a pair shares one height; a lone small keeps its width. At the accessibility text sizes
/// the canvas is one column. The dashed "Add widget" tile ends it.
///
/// "Edit" and "Add widget" open the widget gallery, which isn't designed yet, so only Debug
/// shows them. A widget is one tap target when its screen exists in this build; otherwise it
/// is drawn without a button. Nothing here animates as it appears (owner's motion policy).
struct WidgetCanvas: View {
  var title = "Your widgets"
  let widgets: [HomeWidget]
  let hidden: Bool
  /// "Edit" and "Add widget".
  let editable: Bool
  /// Whether a widget's tap leads anywhere.
  let opens: (String) -> Bool
  /// A widget's tap, by widget id.
  let open: (String) -> Void
  /// "Edit" and "Add widget".
  let edit: () -> Void
  @Environment(\.dynamicTypeSize) private var typeSize

  private var rows: [[HomeWidget]] {
    typeSize.isAccessibilitySize ? widgets.map { [$0] } : widgets.canvasRows
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
        HStack(spacing: HSpacing.widgetGutter) {
          ForEach(row) { widget in
            if opens(widget.id) {
              Button { open(widget.id) } label: { HomeWidgetView(widget, hidden: hidden) }
                .buttonStyle(HPressStyle(in: RoundedRectangle(cornerRadius: HRadius.widget, style: .continuous)))
                .accessibilityIdentifier("widget.\(widget.id)")
            } else {
              HomeWidgetView(widget, hidden: hidden)
                .accessibilityIdentifier("widget.\(widget.id)")
            }
          }
          if row.count == 1, row[0].size == .small, !typeSize.isAccessibilitySize {
            Color.clear.frame(maxWidth: .infinity)
          }
        }
        // Small widgets fill the row's height (at least 175 pt), so a pair stays even.
        .fixedSize(horizontal: false, vertical: true)
      }
      if editable {
        AddWidgetTile { edit() }
          .accessibilityIdentifier("home.addWidget")
          .padding(.top, 12)
      }
    }
    .padding(.horizontal, HSpacing.insetPage)
  }

  /// "Your widgets" and "Edit" 17/24 medium in the link blue, on one baseline.
  private var header: some View {
    ReflowingRow(alignment: .firstTextBaseline) {
      Text(title).hType(.section).foregroundStyle(HColor.textPrimary)
        .accessibilityAddTraits(.isHeader)
    } trailing: {
      if editable {
        // A 24 pt line with a 44 pt target, taken back outside the button.
        Button(action: edit) {
          Text("Edit")
            .hType(.textButton)
            .foregroundStyle(HColor.textLink)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -10)
        .accessibilityIdentifier("home.editWidgets")
      }
    }
  }
}
