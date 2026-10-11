import HasalaDesign
import HasalaModels
import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

/// Pushed editors inside the transaction sheet's own stack (spec 04 §13.3).
enum TransactionRoute: Hashable {
  case category, note, rename, split
}

/// Transaction detail (Paper board): the hero, category with its embedded pace,
/// account and note, where the bank email came from, and every action.
struct TransactionSheet: View {
  @Bindable var app: AppModel
  let model: any TransactionModel
  @State private var path: [TransactionRoute] = []
  @State private var confirmArchive = false
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    NavigationStack(path: $path) {
      Group {
        if let d = model.detail {
          content(d)
        } else {
          EmptyNote(systemImage: "tray", message: "This transaction is no longer here.")
            .padding(HSpacing.insetPage)
        }
      }
      .background(HColor.surfaceSecondary)
      .navigationTitle("Transaction")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        SheetCloseButton(identifier: "txn.close") { dismiss() }
        if let d = model.detail {
          ToolbarItem(placement: .topBarTrailing) {
            Menu {
              Button(d.archived ? "Restore" : "Archive", systemImage: d.archived ? "tray.and.arrow.up" : "archivebox") {
                if d.archived { model.setArchived(false) } else { confirmArchive = true }
              }
              // TODO(03c §3.8 "…" → Edit amount/date): `txn_edited`.
            } label: {
              Image(systemName: "ellipsis").foregroundStyle(MainHeader.iconColor)
            }
            .accessibilityLabel("More")
            .accessibilityIdentifier("txn.more")
          }
        }
      }
      .navigationDestination(for: TransactionRoute.self) { route in
        switch route {
        case .category: CategoryPickerView(model: model) { path.removeAll() }
        case .note: NoteEditorView(note: model.detail?.note ?? "") { model.setNote($0); path.removeAll() }
        case .rename: RenameMerchantView(name: model.merchantName) { model.rename($0); path.removeAll() }
        case .split: SplitEditorView(model: model) { path.removeAll() }
        }
      }
      .confirmationDialog("Archive this transaction?", isPresented: $confirmArchive, titleVisibility: .visible) {
        Button("Archive", role: .destructive) { model.setArchived(true) }
      } message: {
        Text("It leaves your plan and your totals. You can restore it from Activity › Archived.")
      }
    }
    .overlay(alignment: .bottom) { ToastHost(app: app) }
  }

  private func content(_ d: TransactionDetail) -> some View {
    ScrollView {
      VStack(spacing: 18) {
        hero(d)
        rows(d)
        if let p = d.provenance { provenance(p, sortedBy: d.sortedBy) }
        actions(d)
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.bottom, 40)
    }
  }

  private func hero(_ d: TransactionDetail) -> some View {
    VStack(spacing: 6) {
      if let m = d.monogram {
        MonogramDisc(m, size: 56)
      } else {
        HueDisc(hue: d.hue, glyph: d.glyph, size: 56, iconSize: 26)
      }
      Text(d.merchant).hType(.title2).foregroundStyle(HColor.textPrimary).multilineTextAlignment(.center)
        .padding(.top, 6)
        .accessibilityIdentifier("txn.merchant")
      MoneyText(d.amount, figure: .large, unit: .unit, hidden: model.hidden,
                color: d.isIncome ? HColor.moneyIn : HColor.textPrimary, unitGap: 5,
                sign: d.isIncome ? .income : .none)
        .accessibilityIdentifier("txn.amount")
      Text(d.meta).hType(.subheadline).foregroundStyle(HColor.textSecondary).multilineTextAlignment(.center)
      HStack(spacing: 6) {
        if d.needsReview { InfoTag("To review", tone: .accent) }
        if d.isRefund { InfoTag("Refund", tone: .success) }
        if d.isTransfer { InfoTag("Transfer", tone: .accent) }
        if d.archived { InfoTag("Archived", tone: .warning) }
        if let p = d.project { InfoTag(p, tone: .accent) }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 8)
  }

  private func rows(_ d: TransactionDetail) -> some View {
    VStack(spacing: 0) {
      Button { path.append(d.splits.isEmpty ? .category : .split) } label: {
        DetailRow(title: "Category") {
          if !d.splits.isEmpty {
            Text("Split · \(d.splits.count)").hType(.rowTitle).foregroundStyle(HColor.textPrimary)
          } else if let c = d.category {
            HStack(spacing: 6) {
              Circle().fill(c.hue.end).frame(width: 8, height: 8)
              Text(c.name).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
            }
          } else {
            Text("Choose").hType(.rowTitle).foregroundStyle(HColor.textLink)
          }
        }
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("txn.category")

      if let pace = d.pace {
        Divider().padding(.leading, 16)
        VStack(alignment: .leading, spacing: 8) {
          // Title and figures side by side; stacked at the accessibility sizes (spec 04 §17).
          let figures = HStack(alignment: .firstTextBaseline, spacing: 4) {
            MoneyText(pace.left, figure: .compact, hidden: model.hidden, color: HColor.textPrimary)
              .fixedSize()
            PhraseText(MoneyPhrase([.text(pace.left.isNegative ? "over " : "left of "),
                                    .amount(pace.budget, .compact)]), hidden: model.hidden)
              .hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
          }
          if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
              Text(pace.title).hType(.subheadline).foregroundStyle(HColor.textSecondary)
              figures
            }
          } else {
            HStack(alignment: .firstTextBaseline) {
              Text(pace.title).hType(.subheadline).foregroundStyle(HColor.textSecondary)
              Spacer()
              figures
            }
          }
          PaceBar(pace.title, spent: pace.progress, today: pace.today, verdict: pace.verdict)
          HStack {
            DetailLine(parts: [.status(pace.verdict.label, pace.verdict.tone)], hidden: model.hidden)
            Spacer()
            if let projection = pace.projection {
              PhraseText(projection, hidden: model.hidden).hType(.footnote).foregroundStyle(HColor.textSecondary)
            }
          }
        }
        .padding(16)
        .accessibilityElement(children: .combine)
      }

      Divider().padding(.leading, 16)
      // TODO(spec 04 §16.2 T1 AccountPickerView): `txn_annotated{account_id}`.
      DetailRow(title: "Account", chevron: false) {
        Text(d.account ?? "Not set").hType(.rowTitle).foregroundStyle(HColor.textPrimary)
      }
      Divider().padding(.leading, 16)
      Button { path.append(.note) } label: {
        DetailRow(title: "Note") {
          Text(d.note.isEmpty ? "Add a note" : d.note).hType(d.note.isEmpty ? .subheadline : .rowTitle)
            .foregroundStyle(d.note.isEmpty ? HColor.textSecondary : HColor.textPrimary).singleLineAtDefaultTextSize()
        }
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("txn.note")
    }
    .listCard()
  }

  private func provenance(_ p: Provenance, sortedBy: SortedBy?) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      // TODO(spec 04 §16.2 G7): "View the email ›" re-fetches the message on the holder iPhone.
      Text("From your bank").hType(.overline).foregroundStyle(HColor.textSecondary).padding(.leading, 4)
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: "envelope").foregroundStyle(HColor.iconPrimary).frame(width: 24).accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 6) {
            Text(p.title).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
            Text(p.readAt).hType(.footnote).foregroundStyle(HColor.textSecondary)
            Text(verbatim: p.rawMerchant)
              .font(.system(.footnote, design: .monospaced))
              .foregroundStyle(HColor.textPrimary)
              .padding(.horizontal, 12).padding(.vertical, 8)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(HColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
              .accessibilityLabel("As your bank wrote it: \(p.rawMerchant)")
              .accessibilityIdentifier("txn.rawMerchant")
          }
        }
        if let sortedBy {
          Divider()
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(HColor.iconPrimary).frame(width: 24)
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
              Text(sortedBy.title).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
              Text(sortedBy.detail).hType(.footnote).foregroundStyle(HColor.textSecondary)
            }
          }
          .accessibilityElement(children: .combine)
        }
      }
      .padding(16)
      .listCard()
    }
  }

  private func actions(_ d: TransactionDetail) -> some View {
    VStack(spacing: 0) {
      actionRow("Split across categories", "arrow.triangle.split", id: "txn.split") { path.append(.split) }
      Divider().padding(.leading, 52)
      actionRow("Rename merchant", "pencil", id: "txn.rename") { path.append(.rename) }
      Divider().padding(.leading, 52)
      actionRow(d.isRefund ? "Not a refund" : "This is a refund", "arrow.uturn.backward", id: "txn.refund") {
        model.toggleRefund()
      }
      if !d.isTransfer {
        Divider().padding(.leading, 52)
        actionRow("Mark as a transfer", "arrow.left.arrow.right", id: "txn.transfer") { model.markTransfer() }
      }
      Divider().padding(.leading, 52)
      Button {
        if d.archived { model.setArchived(false) } else { confirmArchive = true }
      } label: {
        HStack(spacing: 12) {
          Image(systemName: d.archived ? "tray.and.arrow.up" : "archivebox").frame(width: 24).accessibilityHidden(true)
          Text(d.archived ? "Restore" : "Archive").hType(.rowTitle)
          Spacer()
        }
        .foregroundStyle(d.archived ? HColor.textLink : HColor.listRowDestructive)
        .padding(.horizontal, 16)
        .frame(minHeight: HSpacing.listRowMinHeight)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("txn.archive")
    }
    .listCard()
  }

  private func actionRow(_ title: String, _ icon: String, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: icon).foregroundStyle(HColor.iconPrimary).frame(width: 24).accessibilityHidden(true)
        Text(title).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
        Spacer()
        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
          .foregroundStyle(HColor.listRowChevron).accessibilityHidden(true)
      }
      .padding(.horizontal, 16)
      .frame(minHeight: HSpacing.listRowMinHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(id)
  }
}

/// "Category ……… ● Groceries ›".
struct DetailRow<Value: View>: View {
  let title: String
  var chevron = true
  @ViewBuilder let value: Value

  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    HStack(spacing: 8) {
      // The title and the value stack at the accessibility sizes (spec 04 §17).
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).hType(.callout).foregroundStyle(HColor.textSecondary)
          value
        }
        .padding(.vertical, 8)
        Spacer(minLength: 0)
      } else {
        Text(title).hType(.callout).foregroundStyle(HColor.textSecondary)
        Spacer(minLength: 12)
        value
      }
      if chevron {
        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
          .foregroundStyle(HColor.listRowChevron).accessibilityHidden(true)
      }
    }
    .padding(.horizontal, 16)
    .frame(minHeight: HSpacing.listRowMinHeight)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }
}

/// A small tinted tag ("To review", "Refund").
struct InfoTag: View {
  let text: String
  let tone: StatusTone

  init(_ text: String, tone: StatusTone) {
    self.text = text
    self.tone = tone
  }

  var body: some View {
    Text(text).hType(.footnote.weight(.semibold)).foregroundStyle(tone.foreground)
      .padding(.horizontal, 10).padding(.vertical, 4)
      .background(tone.surface, in: Capsule())
  }
}

#if HASALA_MOCKS
  #Preview("Transaction · Carrefour") {
    let app = AppModel(store: InMemoryLedger())
    TransactionSheet(app: app, model: TransactionViewModel(app: app, id: "carrefour"))
  }
#endif
