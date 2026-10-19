import HasalaDesign
import HasalaModels
import SwiftUI

struct ProjectPickerView: View {
  let app: AppModel
  let txn: TxnID
  let done: () -> Void

  private var current: ProjectID? { app.store.state.txn(txn)?.projectID }

  private var options: [Project] {
    app.store.state.projects.filter { !$0.complete || $0.id == current }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        PlanListCard {
          Button { pick(nil) } label: {
            HListRow(leading: .disc(.other, .close), title: "None", trailing: .check(current == nil))
          }
          .buttonStyle(HRowPressStyle())
          .accessibilityAddTraits(current == nil ? [.isSelected] : [])
          .accessibilityIdentifier("txnProject.none")
          ForEach(options) { p in
            Button { pick(p.id) } label: {
              HListRow(leading: .disc(.peach, p.glyph.icon), title: p.name,
                       supporting: p.complete ? "Completed" : nil, trailing: .check(current == p.id))
            }
            .buttonStyle(HRowPressStyle())
            .accessibilityAddTraits(current == p.id ? [.isSelected] : [])
            .accessibilityIdentifier("txnProject.\(p.id)")
          }
        }
        Text("A project's spending stays out of your monthly budgets unless the project is counted in the plan.")
          .hType(.footnote).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 4)
      }
      .padding(HSpacing.insetPage)
    }
    .background(HColor.sheetSurfaceLarge)
    .navigationTitle("Project")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func pick(_ p: ProjectID?) {
    if p != current { app.perform(.assignProject([txn], p)) }
    done()
  }
}
