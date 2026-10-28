import HasalaDesign
import HasalaModels
import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

/// Activity · Transaction detail (Paper 3FZ-0): one large sheet with everything about a
/// transaction. The 56 disc, merchant and amount; the details card (category with this
/// month's budget beside it, account, note); where it came from (the bank's own words, and
/// the rule that sorted it); the actions; Archive on its own. Choose a category, Split, the
/// note and the rename push inside the sheet (a sheet never opens a sheet, page 14).
struct TransactionSheet: View {
  @Bindable var app: AppModel
  let model: any TransactionModel
  @State private var confirmArchive = false
  @State private var confirmApart = false
  @ScaledMetric(relativeTo: .subheadline) private var senderLane: CGFloat = 20
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    NavigationStack(path: Bindable(app.router).transaction) {
      Group {
        if let d = model.detail {
          content(d)
        } else {
          Text("This transaction is no longer here.")
            .hType(.subheadline).foregroundStyle(HColor.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .background(HColor.sheetSurfaceLarge)
      .navigationTitle("Transaction")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        SheetCloseButton(identifier: "txn.close") { dismiss() }
        if let d = model.detail {
          ToolbarItem(placement: .topBarTrailing) {
            Menu {
              Button(d.archived ? "Restore" : "Archive") {
                if d.archived { model.setArchived(false) } else { confirmArchive = true }
              }
              // TODO(03c §3.8 "…" → Edit amount/date): `txn_edited`.
            } label: {
              // Paper "Glass button · More": the kit's dots in the glass glyph's ink, as on
              // the deck, not the app tint.
              HIconView(.more, size: HSpacing.iconGlass, color: HColor.iconGlass)
            }
            .accessibilityLabel("More")
            .accessibilityIdentifier("txn.more")
          }
        }
      }
      .navigationDestination(for: TransactionRoute.self) { route in
        switch route {
        case .category: CategoryPickerView(model: model) { app.router.transaction.removeAll() }
        case .note:
          NoteEditorView(note: model.detail?.note ?? "") {
            if model.setNote($0) { app.router.transaction.removeAll() }
          }
        case .rename:
          RenameMerchantView(name: model.merchantName) {
            if model.rename($0) { app.router.transaction.removeAll() }
          }
        case .split: SplitEditorView(model: model) { app.router.transaction.removeAll() }
        case .project:
          if let d = model.detail {
            ProjectPickerView(app: app, txn: d.id) { app.router.transaction.removeAll() }
          }
        case .reviewReason(let reason):
          ReviewReasonPage(
            reason: reason, sort: { app.router.transaction.removeAll() },
            archive: { model.setArchived(true) },
            merge: { model.resolve(reason, merge: true) },
            keepBoth: { model.resolve(reason, merge: false) })
        }
      }
      .confirmationDialog("Archive this transaction?", isPresented: $confirmArchive, titleVisibility: .visible) {
        Button("Archive", role: .destructive) { model.setArchived(true) }
      } message: {
        Text("It leaves your plan and your totals. You can restore it from Activity › Archived.")
      }
      .confirmationDialog("Keep as two transactions?", isPresented: $confirmApart, titleVisibility: .visible) {
        Button("Keep both") { model.keepApart() }
      } message: {
        Text("Both emails will count in your totals. Do this only if you made two payments.")
      }
    }
    .overlay(alignment: .bottom) { ToastHost(app: app, placement: .bottom) }
    .presentationBackground(HColor.sheetSurfaceLarge)
    // Paper "Large sheet": the grabber over the header.
    .presentationDragIndicator(.visible)
  }

  private func push(_ route: TransactionRoute) { app.router.transaction.append(route) }

  private func content(_ d: TransactionDetail) -> some View {
    ScrollView {
      VStack(spacing: 16) {
        summary(d)
        if let reason = d.reviewReason { reasonCallout(reason, line: d.reasonLine) }
        details(d)
        if d.isSample {
          sampleNote
        } else if let p = d.provenance {
          provenance(p, d)
        }
        if d.combined { combined }
        actions(d)
        archive(d)
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
      .padding(.bottom, 40)
    }
    .scrollEdgeEffectStyle(.soft, for: .bottom)
  }

  // MARK: Summary

  /// The 56 disc (or the grey monogram before it is sorted), the merchant 22/28 bold, the
  /// amount at large size and "Fri 9 Oct, 19:12 · Emirates NBD ···4412".
  private func summary(_ d: TransactionDetail) -> some View {
    VStack(spacing: 12) {
      if let m = d.monogram {
        MerchantMonogram(letter: m, size: 56)
      } else {
        CategoryDisc(hue: d.hue, icon: d.glyph.icon, size: .s56)
      }
      VStack(spacing: 2) {
        Text(d.merchant).hType(.section).foregroundStyle(HColor.textPrimary)
          .multilineTextAlignment(.center)
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier("txn.merchant")
        let home = d.home ?? HomeAmount(shown: d.amount)
        MoneyText(home.shown, figure: .large, unit: .unit, hidden: model.hidden,
                  color: d.isIncome ? HColor.moneyIn : HColor.moneyOut,
                  unitColor: d.isIncome ? HColor.moneyIn : HColor.textPrimary, unitGap: 5,
                  sign: d.isIncome ? .income : .none, approx: home.estimate)
          .accessibilityIdentifier("txn.amount")
        if home.notCounted {
          Text("Not counted").hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textSecondary)
            .accessibilityIdentifier("txn.notCounted")
        } else if let o = home.original, !model.hidden {
          Text("\(o.currency) \(MoneyFormat.string(o))").hType(.subheadline).foregroundStyle(HColor.textSecondary)
            .accessibilityIdentifier("txn.original")
        }
        Text(d.meta).hType(.subheadline).foregroundStyle(HColor.textSecondary)
          .multilineTextAlignment(.center)
          .padding(.top, 2)
        if let line = home.estimateLine {
          Text(line).hType(.footnote).foregroundStyle(HColor.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
            .accessibilityIdentifier("txn.estimate")
        }
      }
      let tags = tags(d)
      if !tags.isEmpty {
        // One or two short pills, centred; a column at the accessibility sizes.
        let layout = typeSize.isAccessibilitySize
          ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        layout { pills(tags) }
      }
    }
    .frame(maxWidth: .infinity)
  }

  private func pills(_ tags: [StatusPill]) -> some View {
    ForEach(tags, id: \.text) { StatusPillView($0, size: .s26, surface: .tinted) }
  }

  /// What the details don't say on their own: still to review, a refund, a transfer,
  /// archived.
  private func tags(_ d: TransactionDetail) -> [StatusPill] {
    var out: [StatusPill] = []
    if d.needsReview { out.append(StatusPill("To review", tone: .accent)) }
    if d.isRefund { out.append(StatusPill("Refund", tone: .success)) }
    if d.isTransfer { out.append(StatusPill("Transfer", tone: .accent, showsDot: false)) }
    if d.archived { out.append(StatusPill("Archived", tone: .warning)) }
    return out
  }

  private func reasonCallout(_ reason: TxnReviewReason, line: String?) -> some View {
    let ink = ReviewReasonStyle.ink(reason)
    return Button { push(.reviewReason(reason)) } label: {
      HStack(alignment: .top, spacing: 12) {
        HIconView(ReviewReasonStyle.icon(reason), size: 20, color: ink, strokeWidth: 1.9)
          .frame(height: senderLane)
        VStack(alignment: .leading, spacing: 2) {
          Text(reason.title)
            .hType(.subheadline.weight(.semibold))
            .foregroundStyle(ink)
          Text(line ?? reason.detail)
            .hType(.footnote)
            .foregroundStyle(ink)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        HIconView(.chevronRight, size: 16, color: ink)
          .frame(maxHeight: .infinity)
      }
      .padding(.vertical, 14)
      .padding(.horizontal, 16)
      .background(ReviewReasonStyle.surface(reason), in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(reason.title). \(line ?? reason.detail)")
    .accessibilityHint("Shows what this means and what to do")
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("txn.reviewReason.\(reason.rawValue)")
  }

  // MARK: Details

  /// Category (with this month's budget for it), Account and Note, in one white card with
  /// full-width dividers inside its 16 inset.
  private func details(_ d: TransactionDetail) -> some View {
    VStack(spacing: 0) {
      Button { push(d.splits.isEmpty ? .category : .split) } label: {
        categoryRow(d).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Category, \(categoryValue(d))")
      .accessibilityAddTraits(.isButton)
      .accessibilityIdentifier("txn.category")

      if let pace = d.pace {
        HDivider(inset: .none)
        BudgetContext(pace: pace, hidden: model.hidden)
      }

      HDivider(inset: .none)
      // TODO(spec 04 §16.2 T1 AccountPickerView): `txn_annotated{account_id}`. No chevron
      // until the account can change.
      KeyValueRow("Account", value: d.account ?? "Not set", placeholder: d.account == nil)

      HDivider(inset: .none)
      Button { push(.note) } label: {
        KeyValueRow("Note", value: d.note.isEmpty ? "Add a note" : d.note, chevron: true, placeholder: d.note.isEmpty)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(d.note.isEmpty ? "Note, Add a note" : "Note, \(d.note)")
      .accessibilityAddTraits(.isButton)
      .accessibilityIdentifier("txn.note")

      if d.project != nil || !model.projects.isEmpty {
        HDivider(inset: .none)
        Button { push(.project) } label: {
          KeyValueRow("Project", value: d.project ?? "None", chevron: true, placeholder: d.project == nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Project, \(d.project ?? "None")")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("txn.project")
      }
    }
    .padding(.horizontal, 16)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }

  private func categoryValue(_ d: TransactionDetail) -> String {
    if !d.splits.isEmpty { return "Split · \(d.splits.count)" }
    return d.category?.name ?? "Choose a category"
  }

  @ViewBuilder private func categoryRow(_ d: TransactionDetail) -> some View {
    if d.splits.isEmpty, let c = d.category {
      KeyValueRow("Category", value: c.name, dot: c.hue, chevron: true)
    } else {
      KeyValueRow("Category", value: categoryValue(d), chevron: true, placeholder: d.category == nil && d.splits.isEmpty)
    }
  }

  // MARK: Provenance

  /// "FROM YOUR BANK": the alert it was read from, when, the bank's words as written (mono),
  /// and the rule that sorted it. "View the email" waits for the email view (Debug only).
  private func provenance(_ p: Provenance, _ d: TransactionDetail) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center) {
        Text("From your bank").hType(.overline).foregroundStyle(HColor.textGroupedHeader)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 8)
        if BuildSurface.showsUnfinished, !p.isText {
          // TODO(spec 04 §16.2 G7): re-fetch the message on the holder iPhone.
          Button {
            app.say("The bank email opens in a later build", icon: .envelope)
          } label: {
            HStack(spacing: 2) {
              Text("View the email").hType(.subheadline.weight(.semibold))
              HIconView(.chevronRight, size: 14, color: HColor.textLink, strokeWidth: 2.6)
            }
            .foregroundStyle(HColor.textLink)
            .frame(minHeight: HSpacing.targetMinimum)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          // A 44 pt target on a 20 pt header (Paper 4AV-0, 8 pt above the card): the
          // height is taken back outside the button, so the card does not move down.
          .padding(.vertical, -12)
          .accessibilityIdentifier("txn.viewEmail")
        }
      }
      .padding(.horizontal, 4)

      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top, spacing: 14) {
          HIconView(p.isText ? .chat : .envelope, size: 22, color: HColor.iconPrimary)
          VStack(alignment: .leading, spacing: 2) {
            Text(p.title).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
              .accessibilityIdentifier("txn.source")
            Text(p.readAt).hType(.footnote).foregroundStyle(HColor.textSecondary)
            if let check = p.senderCheck {
              Text("Sender check: \(check)").hType(.footnote).foregroundStyle(HColor.textSecondary)
                .accessibilityIdentifier("txn.senderCheck")
            }
            if !p.rawMerchant.isEmpty {
              Text(verbatim: p.rawMerchant)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(HColor.textPrimary)
                .padding(.horizontal, 12).padding(.vertical, 8)
                // Paper 4I0-0 spans the text column, not the text.
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.top, 8)
                .accessibilityLabel("Bank text: \(p.rawMerchant)")
                .accessibilityIdentifier("txn.rawMerchant")
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 16)
        if let sortedBy = d.sortedBy, Self.showsSource(sortedBy) {
          HColor.borderSubtle.frame(height: 1).padding(.leading, 36).accessibilityHidden(true)
          sortedRow(sortedBy, opensRules: d.sortedByRule)
        }
      }
      .padding(.horizontal, 16)
      .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
    }
  }

  /// The source row is for what Hasala did on its own (a rule, its merchant list, this
  /// iPhone's suggestion); a category the person picked says nothing new.
  static func showsSource(_ s: SortedBy) -> Bool {
    s.title != "Sorted by you" && s.title != "Added by you"
  }

  @ViewBuilder private func sortedRow(_ s: SortedBy, opensRules: Bool) -> some View {
    let row = HStack(spacing: 14) {
      HIconView(.rule, size: 22, color: HColor.iconPrimary)
      VStack(alignment: .leading, spacing: 0) {
        Text(s.title).hType(.subheadline.weight(.medium)).foregroundStyle(HColor.textPrimary)
        Text(s.detail).hType(.footnote).foregroundStyle(HColor.textSecondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if opensRules {
        HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
      }
    }
    .padding(.vertical, 12)
    .frame(minHeight: 48)
    .contentShape(Rectangle())

    if opensRules {
      // Tapping the rule opens it: the profile's rules, after this sheet closes (one sheet
      // at a time, `AppRouter.open`).
      Button { app.router.open(.profile, profile: [.rules]) } label: { row }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens your rules")
        .accessibilityIdentifier("txn.rule")
    } else {
      row.accessibilityElement(children: .combine)
    }
  }

  /// A row of the App Review sample (its message id is `sample-<n>`): there is no bank
  /// email to point to, and the sheet says so instead of showing where it was read.
  private var sampleNote: some View {
    HStack(alignment: .top, spacing: 14) {
      HIconView(.info, size: 22, color: HColor.iconPrimary)
      Text("This is sample data. There's no email behind it.")
        .hType(.rowTitle).foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("txn.sample")
    }
    .padding(16)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }

  private var combined: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 14) {
        HIconView(.envelope, size: 22, color: HColor.iconPrimary)
        VStack(alignment: .leading, spacing: 2) {
          Text("Combined with a second bank email").hType(.rowTitle).foregroundStyle(HColor.textPrimary)
          Text("Your bank sent a transfer notice and an account alert for this payment. It counts once.")
            .hType(.footnote).foregroundStyle(HColor.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(16)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("txn.combined")
      HDivider(inset: .icon52)
      ActionRow(icon: .linkOff, title: "Keep as two transactions") { confirmApart = true }
        .accessibilityIdentifier("txn.keepApart")
    }
    .background(HColor.surfacePrimary)
    .clipShape(RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }

  // MARK: Actions

  private func actions(_ d: TransactionDetail) -> some View {
    VStack(spacing: 0) {
      ActionRow(icon: .split, title: "Split across categories", pushes: true) { push(.split) }
        .accessibilityIdentifier("txn.split")
      HDivider(inset: .icon52)
      ActionRow(icon: .pencil, title: "Rename merchant", pushes: true) { push(.rename) }
        .accessibilityIdentifier("txn.rename")
      HDivider(inset: .icon52)
      // A refund or a transfer happens at once, with Undo in the toast: no chevron.
      ActionRow(icon: .refund, title: d.isRefund ? "Not a refund" : "This is a refund") { model.toggleRefund() }
        .accessibilityIdentifier("txn.refund")
      if !d.isTransfer {
        HDivider(inset: .icon52)
        ActionRow(icon: .swap, title: "Mark as a transfer") { model.markTransfer() }
          .accessibilityIdentifier("txn.transfer")
      }
    }
    .background(HColor.surfacePrimary)
    // The card clips a pressed end row to its corners.
    .clipShape(RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }

  /// Archive on its own, last, in red; Restore in the link colour once archived.
  private func archive(_ d: TransactionDetail) -> some View {
    ActionRow(icon: .archive, title: d.archived ? "Restore" : "Archive",
              tint: d.archived ? HColor.textLink : HColor.listRowDestructive) {
      if d.archived { model.setArchived(false) } else { confirmArchive = true }
    }
    .accessibilityIdentifier("txn.archive")
    .background(HColor.surfacePrimary)
    .clipShape(RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }
}

/// "Groceries this month ……… 1,387.60 left of 2,200", the slim bar (6, the verdict's fill,
/// no tick), "● Over pace ……… on course for 2,518". The bar fills once per sheet.
private struct BudgetContext: View {
  let pace: EmbeddedPace
  let hidden: Bool
  @State private var phase = PaceFillPhase()
  @Environment(\.hMotion) private var policy

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ReflowingRow(spacing: 12, alignment: .firstTextBaseline) {
        Text(pace.title).hType(.subheadline).foregroundStyle(HColor.textSecondary)
      } trailing: {
        PhraseText(MoneyPhrase([.amount(pace.left.isNegative ? .aed(pace.left.minor.negated) : pace.left),
                                .text(pace.left.isNegative ? " over " : " left of "),
                                .amount(pace.budget, .compact)]), hidden: hidden)
          .hFigure(HFigure.compact.weight(.semibold))
          .foregroundStyle(HColor.textPrimary)
      }
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule().fill(HColor.paceTrack)
          Capsule().fill(pace.verdict.fill)
            .frame(width: max(phase.fill > 0 ? 6 : 0, geo.size.width * phase.fill))
        }
      }
      .frame(height: 6)
      .accessibilityHidden(true)
      .paceFillSequence($phase, target: min(1, pace.progress.fraction), policy: policy)
      ReflowingRow(spacing: 12) {
        StatusDotLine(words: pace.verdict.label, verdict: pace.verdict)
      } trailing: {
        if let projection = pace.projection {
          PhraseText(projection, hidden: hidden).hType(.footnote).foregroundStyle(HColor.textSecondary)
        }
      }
    }
    .padding(.vertical, 14)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("txn.pace")
  }
}

/// A row in the actions card (Paper "ActionRow"): a 22 line icon, the label 16/22 600, and a
/// chevron when it opens a page. Min 52, 14 from icon to label; highlight on press, never
/// scale.
struct ActionRow: View {
  let icon: HIcon
  let title: String
  var pushes = false
  var tint: Color = HColor.listRowTitle
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 14) {
        HIconView(icon, size: 22, color: tint == HColor.listRowTitle ? HColor.iconPrimary : tint)
        Text(title).hType(.rowTitle).foregroundStyle(tint)
          .frame(maxWidth: .infinity, alignment: .leading)
        if pushes {
          HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
        }
      }
      .padding(.horizontal, 16)
      .frame(minHeight: 52)
      .contentShape(Rectangle())
    }
    .buttonStyle(HRowPressStyle())
    .accessibilityLabel(title)
  }
}

#if HASALA_MOCKS
  #Preview("Transaction · Carrefour") {
    let app = AppModel(store: InMemoryLedger())
    TransactionSheet(app: app, model: TransactionViewModel(app: app, id: "carrefour"))
  }
#endif
