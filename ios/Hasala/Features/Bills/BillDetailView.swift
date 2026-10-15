import HasalaDesign
import HasalaModels
import SwiftUI

/// One bill (Paper "Bills · AXA Insurance (may be late)"), pushed from Home, Activity's
/// "Coming up" and Profile › Bills.
///
/// The foundation's version (plan B7.3): the bill's line from Bills, on today's parts.
// TODO(spec 13 B3): the rose wash and hero, "What we noticed", the payment history and the
// actions (I paid it, Remind me tomorrow, It's cancelled).
struct BillDetailView: View {
  @Bindable var app: AppModel
  let bill: BillID
  @State private var model: BillsViewModel

  init(app: AppModel, bill: BillID) {
    self.app = app
    self.bill = bill
    _model = State(initialValue: BillsViewModel(app: app))
  }

  private var row: BillRowModel? {
    let s = model.snapshot
    return (s.upcoming + s.recentlyPaid).first { $0.id == bill }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let row {
          ListCard { BillRow(row: row, hidden: model.hidden) }
        } else {
          EmptyNote(systemImage: "doc.text", message: "This bill is no longer tracked.")
        }
      }
      .padding(HSpacing.insetPage)
    }
    .background(HColor.surfaceSecondary)
    .navigationTitle(row?.name ?? "Bill")
    .navigationBarTitleDisplayMode(.inline)
  }
}
