import HasalaDesign
import HasalaModels
import SwiftUI

/// Home · Notifications (Paper 11Y9-0, all clear 12AC-0; spec 10 §4): the bell's large sheet,
/// grey with white cards. "Needs a look" lists what wants an action, newest first; with nothing
/// there it becomes "Nothing needs you · We'll tell you when something does." "Earlier" keeps
/// what came before, and a "Notification settings" link closes the list (both Debug only: there
/// is no notification history or in-app setting behind them in a Release build, plan B7.6
/// decision 12).
///
/// Tapping a row closes the sheet and opens its screen (`HomeModel.openNotification`): a bill
/// or Bills inside Home, Plan's category, Profile › Bank alerts (queued behind this sheet), or
/// the review deck once the sheet has gone.
struct NotificationsSheet: View {
  @Bindable var app: AppModel
  @State private var model: HomeViewModel
  /// What waits for the sheet to be gone (the review cover).
  @State private var afterClose: (@MainActor () -> Void)?
  @Environment(\.dismiss) private var dismiss

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: HomeViewModel(app: app))
  }

  private var bell: Bell { model.bell }
  private var hidden: Bool { app.amountsHidden }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          if bell.needsALook.isEmpty {
            NothingNeedsYou()
              .accessibilityIdentifier("bell.allClear")
          } else {
            section("Needs a look", bell.needsALook, markAll: bell.unread > 0)
          }
          if !bell.earlier.isEmpty {
            section("Earlier", bell.earlier, markAll: false)
          }
          if BuildSurface.showsUnfinished {
            Button { app.router.open(.profile, profile: [.notifications]) } label: {
              Text("Notification settings")
                .hType(.subheadline.weight(.medium))
                .foregroundStyle(HColor.textLink)
                .frame(maxWidth: .infinity, minHeight: HSpacing.targetMinimum)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, -6)
            .accessibilityIdentifier("bell.settings")
          }
        }
        .padding(.horizontal, HSpacing.insetPage)
        // Paper: the 48 header, 18, then the content 6 down, so "Needs a look" starts 48 under
        // the header's centre line. The system bar's own height leaves 9 of that to us.
        .padding(.top, 15)
        .padding(.bottom, 40)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bell.sheet")
      }
      .background(HColor.sheetSurfaceLarge)
      .navigationTitle("Notifications")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        SheetCloseButton(identifier: "bell.close") { dismiss() }
        ToolbarItem(placement: .principal) {
          Text("Notifications").hType(.headline).foregroundStyle(HColor.textPrimary)
            .accessibilityAddTraits(.isHeader)
        }
      }
      .overlay(alignment: .bottom) { ToastHost(app: app, placement: .bottom) }
    }
    .presentationDetents([.large])
    // Paper draws the grabber (36 × 5) over the header.
    .presentationDragIndicator(.visible)
    .presentationCornerRadius(HRadius.sheetLarge)
    .presentationBackground(HColor.sheetSurfaceLarge)
    .onDisappear {
      let next = afterClose
      afterClose = nil
      next?()
    }
  }

  /// A heading 22/28 bold over one white card of rows, 12 apart; dividers inset 68.
  private func section(_ title: String, _ items: [NotificationItem], markAll: Bool) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      SideBySideOrStacked(spacing: 12, lineSpacing: 4) {
        heading(title)
        if markAll { markAllButton.padding(.vertical, -8) }
      }
      HListCard {
        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
          if i > 0 { HDivider(inset: .disc68) }
          Button { open(item) } label: { NotificationRow(item, hidden: hidden) }
            .buttonStyle(HRowPressStyle())
            .accessibilityIdentifier("bell.row.\(item.id)")
        }
      }
    }
  }

  private func heading(_ title: String) -> some View {
    Text(title).hType(.section).foregroundStyle(HColor.textPrimary)
      .accessibilityAddTraits(.isHeader)
  }

  private var markAllButton: some View {
    Button { model.markAllRead() } label: {
      Text("Mark all as read")
        .hType(.subheadline.weight(.medium))
        .foregroundStyle(HColor.textLink)
        .frame(minHeight: HSpacing.targetMinimum)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("bell.markAllRead")
  }

  private func open(_ item: NotificationItem) {
    afterClose = model.openNotification(item.destination)
  }
}
