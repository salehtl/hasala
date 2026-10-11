import HasalaDesign
import HasalaModels
import Observation
import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

/// Bills · Coming up and found (spec 04 §16.1 "Bills · Coming up and found").
@MainActor
protocol BillsModel: AnyObject, Observable {
  var snapshot: BillsSnapshot { get }
  var hidden: Bool { get }
  func setRange(_ range: BillsSnapshot.Range)
  func markPaid(_ bill: BillID)
  func remind(_ bill: BillID)
  func acceptAmount(_ bill: BillID)
  func track(_ candidate: String)
  func dismiss(_ candidate: String)
}

@MainActor
@Observable
final class BillsViewModel: BillsModel {
  private let app: AppModel
  private var range: BillsSnapshot.Range = .month
  @ObservationIgnored private var memo = Memo<[AnyHashable], BillsSnapshot>()

  init(app: AppModel) { self.app = app }

  var snapshot: BillsSnapshot {
    memo.value(for: [app.store.revision, range]) {
      BillsEngine.snapshot(app.store.state, now: app.store.now, range: range)
    }
  }
  var hidden: Bool { app.amountsHidden }

  func setRange(_ range: BillsSnapshot.Range) { self.range = range }

  // TODO(spec 04 §16.2 B1): "I paid it" opens FindPaymentSheet to link the payment; for now
  // it marks this occurrence paid (`bill_occurrence_set{paid}`), with Undo.
  func markPaid(_ bill: BillID) { app.perform(.markBillPaid(bill)) }

  // TODO(03b §3.3): "Remind me tomorrow" snoozes the occurrence (`bill_occurrence_set` snooze)
  // and plans a local notification (spec 04 §9).
  func remind(_ bill: BillID) { app.say("Reminders arrive in a later build", systemImage: "bell") }

  func acceptAmount(_ bill: BillID) { app.perform(.acceptBillAmount(bill)) }
  func track(_ candidate: String) { app.perform(.trackCandidate(candidate)) }
  func dismiss(_ candidate: String) { app.perform(.dismissCandidate(candidate)) }
}

/// Pushed from Home (the Next bill widget, a late-bill card) and Profile › Bills.
struct BillsView: View {
  @Bindable var app: AppModel
  let model: any BillsModel
  /// Off inside the profile sheet, which hosts the toast itself.
  var showsToast = true
  @State private var topInset: CGFloat = 0

  private var snap: BillsSnapshot { model.snapshot }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: HSpacing.gapScreenSection) {
        hero
        if !snap.needsALook.isEmpty {
          VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Needs a look", count: snap.needsALook.count)
            ForEach(snap.needsALook) { AttentionCard(item: $0, model: model) }
          }
        }
        if !snap.found.isEmpty {
          VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Found in your history")
            ForEach(snap.found) { CandidateCard(candidate: $0, model: model) }
          }
        }
        upcoming
        if !snap.recentlyPaid.isEmpty {
          VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
              SectionTitle(title: "Recently paid")
              PhraseText(MoneyPhrase([.amount(snap.paidThisMonth), .text(" in \(app.store.now.date.yearMonth.name)")]),
                         hidden: model.hidden)
                .hType(.subheadline).foregroundStyle(HColor.textSecondary).fixedSize()
            }
            ListCard { ForEach(snap.recentlyPaid) { BillRow(row: $0, hidden: model.hidden) } }
          }
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.vertical, 16)
      .background(alignment: .top) {
        AmbientWash(.peach).padding(.horizontal, -HSpacing.insetPage).padding(.top, -topInset)
      }
    }
    .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
    .background(HColor.surfaceSecondary)
    .navigationTitle("Bills")
    .navigationBarTitleDisplayMode(.inline)
    .overlay(alignment: .bottom) { if showsToast { ToastHost(app: app) } }
    // TODO(spec 04 §16.2 B1): "+" Add a bill (AddBillSheet).
  }

  private var hero: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Next 14 days").hType(.overline).foregroundStyle(HColor.textOnWashSecondary)
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        MoneyText(snap.next14, figure: .display, unit: .displayUnit, hidden: model.hidden, hiddenGlyphs: 6,
                  color: HColor.textPrimary)
          .accessibilityIdentifier("bills.next14")
        Text("to pay").hType(.body).foregroundStyle(HColor.textOnWashSecondary)
      }
      if let income = snap.incomeLine {
        HStack(spacing: 4) {
          Text("Salary").hType(.subheadline.weight(.semibold))
          PhraseText(income, hidden: model.hidden).hType(.subheadline)
        }
        .foregroundStyle(HColor.moneyIn)
      }
    }
  }

  private var upcoming: some View {
    VStack(alignment: .leading, spacing: 12) {
      // TODO(spec 04 §16.2 B1): "All schedules · N ›" opens AllSchedulesView.
      SectionTitle(title: "Upcoming", note: "\(snap.tracked) tracked")
      HStack(spacing: 8) {
        ForEach(BillsSnapshot.Range.allCases) { r in
          FilterChip(r.title, selected: snap.range == r) { model.setRange(r) }
            .accessibilityIdentifier("bills.range.\(r.rawValue)")
        }
      }
      if snap.upcoming.isEmpty {
        EmptyNote(systemImage: "calendar", message: "Nothing due in the next \(snap.range.rawValue) days.")
      } else {
        ListCard { ForEach(snap.upcoming) { BillRow(row: $0, hidden: model.hidden) } }
      }
    }
  }
}

/// A late bill or a price change: a hue poster over the explanation and two actions.
private struct AttentionCard: View {
  let item: BillAttention
  let model: any BillsModel

  var body: some View {
    let (hue, pill): (Hue, StatusPill) = switch item.kind {
    case .late(let n): (.rose, StatusPill("\(n) day\(n == 1 ? "" : "s") late", tone: .error))
    case .priceChange: (.sand, StatusPill("Price change", tone: .warning))
    }
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Circle().fill(HColor.posterGlyph).frame(width: 28, height: 28)
            .overlay { Image(systemName: item.glyph.symbolName).font(.system(size: 13, weight: .semibold)).foregroundStyle(hue.ink) }
            .accessibilityHidden(true)
          Text(item.name).hType(.footnote.weight(.semibold)).foregroundStyle(HColor.textPrimary)
          Spacer()
          StatusPillView(pill)
        }
        MoneyText(item.amount, figure: .large, unit: .unit, hidden: model.hidden, hiddenGlyphs: 3,
                  color: HColor.textPrimary, unitGap: 5)
      }
      .padding(16)
      .background(hue.gradient)
      VStack(alignment: .leading, spacing: 12) {
        PhraseText(item.body, hidden: model.hidden).hType(.subheadline).foregroundStyle(HColor.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          switch item.kind {
          case .late:
            Button("I paid it") { model.markPaid(item.id) }
              .buttonStyle(.pill(.primary, size: .medium, fill: true))
              .accessibilityIdentifier("bills.paid.\(item.id)")
            Button("Remind me") { model.remind(item.id) }
              .buttonStyle(.pill(.secondary, size: .medium, fill: true))
          case .priceChange:
            Button("Accept new amount") { model.acceptAmount(item.id) }
              .buttonStyle(.pill(.primary, size: .medium, fill: true))
              .accessibilityIdentifier("bills.accept.\(item.id)")
          }
        }
      }
      .padding(16)
    }
    .background(HColor.surfacePrimary)
    .clipShape(RoundedRectangle(cornerRadius: HRadius.brief, style: .continuous))
    .elevation()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("bills.attention.\(item.id)")
  }
}

/// "Found in your history": the detector's proposal with its evidence.
private struct CandidateCard: View {
  let candidate: BillCandidateModel
  let model: any BillsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Circle().fill(HColor.posterGlyph).frame(width: 28, height: 28)
            .overlay { Image(systemName: Glyph.subscriptions.symbolName).font(.system(size: 13, weight: .semibold)).foregroundStyle(Hue.sky.ink) }
            .accessibilityHidden(true)
          Text(candidate.name).hType(.footnote.weight(.semibold)).foregroundStyle(HColor.textPrimary)
          Spacer()
          StatusPillView(StatusPill("New bill found", tone: .accent))
        }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          MoneyText(candidate.amount, figure: .large, unit: .unit, hidden: model.hidden, hiddenGlyphs: 3,
                    color: HColor.textPrimary, unitGap: 5)
          Text("every month").hType(.body).foregroundStyle(HColor.textOnHueSecondary)
        }
      }
      .padding(16)
      .background(Hue.sky.gradient)
      VStack(alignment: .leading, spacing: 12) {
        FlowLayout(spacing: 6) {
          ForEach(candidate.evidence, id: \.self) { e in
            Text(e).hType(.footnote).foregroundStyle(HColor.chipInfoText)
              .padding(.horizontal, 10).padding(.vertical, 4)
              .background(HColor.chipInfoSurface, in: Capsule())
          }
        }
        // TODO(spec 04 §16.2 B1): "See the N payments ›".
        HStack(spacing: 8) {
          Button("Track this bill") { model.track(candidate.id) }
            .buttonStyle(.pill(.primary, size: .medium, fill: true))
            .accessibilityIdentifier("bills.track.\(candidate.id)")
          Button("Dismiss") { model.dismiss(candidate.id) }
            .buttonStyle(.pill(.secondary, size: .medium, fill: true))
            .accessibilityIdentifier("bills.dismiss.\(candidate.id)")
        }
      }
      .padding(16)
    }
    .background(HColor.surfacePrimary)
    .clipShape(RoundedRectangle(cornerRadius: HRadius.brief, style: .continuous))
    .elevation()
    .accessibilityElement(children: .contain)
  }
}

#if HASALA_MOCKS
  #Preview("Bills") {
    let app = AppModel(store: InMemoryLedger())
    NavigationStack { BillsView(app: app, model: BillsViewModel(app: app)) }
  }
#endif
