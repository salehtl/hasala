import HasalaDesign
import HasalaModels
import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

/// Review · Deck (Paper board): a focused full-screen mode, one card at a time. Drag
/// right for Need, left for Want, down for Save, up for Transfer (the horizontal pair
/// follows the Swipe directions setting); a far drag or a flick commits (spec 04 §14.7,
/// `SwipePhysics`), then the pick sheet asks which category. Every sort has Undo.
struct ReviewDeckView: View {
  @Bindable var app: AppModel
  let model: any ReviewDeckModel

  @State private var drag: CGSize = .zero
  @State private var picking: Pick?
  @State private var sortedCount = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var typeSize

  struct Pick: Identifiable {
    let card: ReviewCardModel
    let choice: ReviewChoice
    var id: String { card.id + "." + choice.rawValue }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      ProgressLine(Permille.ratio(Int64(done), of: Int64(max(1, model.total))), fill: HColor.actionAccent)
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 10)
        .accessibilityHidden(true)
      if let top = model.cards.first {
        deck(top)
      } else {
        ReviewDoneView(model: model)
      }
    }
    .background(alignment: .top) { AmbientWash(.sky).ignoresSafeArea() }
    .background(HColor.surfaceSecondary)
    // Above "Skip for now", so the toast never covers it.
    .overlay(alignment: .bottom) { ToastHost(app: app, placement: .bottom).padding(.bottom, model.cards.isEmpty ? 0 : 56) }
    .sensoryFeedback(.impact(weight: .light), trigger: sortedCount)
    .sheet(item: $picking, onDismiss: settle) { pick in
      BucketPickSheet(model: model, pick: pick) { category, alwaysUse, project in
        model.sort(pick.card.id, into: category, alwaysUse: alwaysUse, project: project)
        sortedCount += 1
        picking = nil
      }
      .presentationDetents([.medium, .large])
      .presentationCornerRadius(HRadius.sheet)
    }
    .onChange(of: model.cards.first?.id) { drag = .zero }
  }

  private var done: Int { model.total - model.cards.count }

  // MARK: Header

  private var header: some View {
    HStack {
      Button { model.close(goToActivity: false) } label: {
        Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(MainHeader.iconColor)
          .frame(width: HSpacing.glassButton, height: HSpacing.glassButton)
      }
      .glassEffect(.regular.interactive(), in: Circle())
      .accessibilityLabel("Close")
      .accessibilityIdentifier("review.close")
      Spacer()
      VStack(spacing: 0) {
        Text("Review").hType(.headline).foregroundStyle(HColor.textPrimary)
        if !model.cards.isEmpty {
          Text("\(model.position) of \(model.total)").hType(.footnote).foregroundStyle(HColor.textSecondary)
            .accessibilityIdentifier("review.position")
        }
      }
      Spacer()
      Menu {
        if let top = model.cards.first {
          Button("Skip for now", systemImage: "forward") { model.skip(top.id) }
        }
        // TODO(spec 04 §16.2 T3): the rest of the review "…" menu (swipe directions, view the email).
      } label: {
        Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold)).foregroundStyle(MainHeader.iconColor)
          .frame(width: HSpacing.glassButton, height: HSpacing.glassButton)
      }
      .glassEffect(.regular.interactive(), in: Circle())
      .accessibilityLabel("More")
      .opacity(model.cards.isEmpty ? 0 : 1)
    }
    .padding(.horizontal, HSpacing.insetPage)
    .padding(.top, 6)
  }

  // MARK: Deck

  private var lean: SwipeEdge? { SwipePhysics.preview(dx: drag.width, dy: drag.height) }
  private var strength: Double { SwipePhysics.progress(dx: drag.width, dy: drag.height) }
  private var leanChoice: ReviewChoice? { lean.map { SwipePhysics.choice(for: $0, needOnRight: model.needOnRight) } }

  /// At the accessibility text sizes the deck scrolls, the card does not drag (the pills,
  /// "Use" and the VoiceOver actions sort it), and Want/Need sit under the card instead of
  /// over its text (spec 04 §17).
  @ViewBuilder
  private func deck(_ top: ReviewCardModel) -> some View {
    if typeSize.isAccessibilitySize {
      ScrollView { deckContent(top) }
    } else {
      deckContent(top).frame(maxHeight: .infinity)
    }
  }

  private func deckContent(_ top: ReviewCardModel) -> some View {
    VStack(spacing: 10) {
      pill(.up)
      ZStack {
        // Two peeks behind the top card (Paper: 324 and 308 wide).
        if model.cards.count > 2 { peek(width: 308, y: 16) }
        if model.cards.count > 1 { peek(width: 324, y: 8) }
        ReviewCardView(card: top, hidden: model.hidden, lean: leanChoice, strength: strength) {
          model.useSuggestion(top.id)
          sortedCount += 1
        }
        .offset(drag)
        .rotationEffect(.degrees(reduceMotion ? 0 : max(-3, min(3, drag.width / 30))))
        .gesture(
          DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { end($0, top) },
          including: typeSize.isAccessibilitySize ? .subviews : .all
        )
        .accessibilityElement(children: .contain)
        .accessibilityActions {
          ForEach(ReviewChoice.allCases, id: \.self) { choice in
            Button(choice.label) { pick(top, choice, animated: false) }
          }
          Button("Skip for now") { model.skip(top.id) }
        }
        .accessibilityIdentifier("review.card")
        if !typeSize.isAccessibilitySize {
          HStack {
            pill(.left)
            Spacer()
            pill(.right)
          }
          .padding(.horizontal, -8)
        }
      }
      .frame(maxWidth: 340)
      .padding(.horizontal, HSpacing.insetPage)
      if typeSize.isAccessibilitySize {
        pill(.left)
        pill(.right)
      }
      pill(.down)
      Spacer(minLength: 8)
      Button("Skip for now") { model.skip(top.id) }
        .buttonStyle(.plain)
        .hType(.body.weight(.medium))
        .foregroundStyle(HColor.textLink)
        .frame(minHeight: 44)
        .accessibilityIdentifier("review.skip")
      // TODO(spec 04 §16.2 G7): "View bank email" beside Skip, once the holder re-fetch exists.
    }
    .padding(.top, 12)
  }

  private func peek(width: CGFloat, y: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: 28, style: .continuous)
      .fill(HColor.surfacePrimary.opacity(0.85))
      .frame(width: width, height: 400)
      .offset(y: y)
      .shadow(color: HColor.elevationFar, radius: 10, y: 6)
      .accessibilityHidden(true)
  }

  /// A direction pill: glass, the bucket's dot, an arrow. The one the card leans to grows
  /// and takes its hue.
  private func pill(_ edge: SwipeEdge) -> some View {
    let choice = SwipePhysics.choice(for: edge, needOnRight: model.needOnRight)
    let active = leanChoice == choice && strength > 0
    let arrow: String = switch edge {
    case .left: "arrow.left"
    case .right: "arrow.right"
    case .up: "arrow.up"
    case .down: "arrow.down"
    }
    return Button {
      if let top = model.cards.first { pick(top, choice, animated: true) }
    } label: {
      HStack(spacing: 6) {
        if edge != .right { Image(systemName: arrow).font(.system(size: 13, weight: .semibold)) }
        Circle().fill(choice.hue.end).frame(width: 8, height: 8)
        Text(choice.label).hType(.subheadline.weight(.semibold))
        if edge == .right { Image(systemName: arrow).font(.system(size: 13, weight: .semibold)) }
      }
      .foregroundStyle(HColor.textPrimary)
      .padding(.horizontal, 14)
      .frame(minHeight: active ? 48 : 44)
      .background(active ? choice.hue.start.opacity(0.9) : .clear, in: Capsule())
      .glassEffect(.regular.interactive(), in: Capsule())
      .scaleEffect(active ? 1 + 0.08 * strength : 1)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Sort as \(choice.label)")
    .accessibilityIdentifier("review.pill.\(choice.rawValue)")
    .animation(.snappy, value: active)
  }

  private func end(_ value: DragGesture.Value, _ top: ReviewCardModel) {
    let edge = SwipePhysics.commit(
      dx: value.translation.width, dy: value.translation.height,
      vx: value.velocity.width, vy: value.velocity.height
    )
    guard let edge else {
      withAnimation(.snappy) { drag = .zero }
      return
    }
    pick(top, SwipePhysics.choice(for: edge, needOnRight: model.needOnRight), animated: true)
  }

  /// Sends the card toward its edge and asks which category.
  private func pick(_ card: ReviewCardModel, _ choice: ReviewChoice, animated: Bool) {
    let edge = SwipePhysics.edge(for: choice, needOnRight: model.needOnRight)
    let distance: CGFloat = 120
    let target: CGSize = switch edge {
    case .left: CGSize(width: -distance, height: drag.height)
    case .right: CGSize(width: distance, height: drag.height)
    case .up: CGSize(width: drag.width, height: -distance)
    case .down: CGSize(width: drag.width, height: distance)
    }
    if animated && !reduceMotion {
      withAnimation(.snappy) { drag = target }
    }
    picking = Pick(card: card, choice: choice)
  }

  /// After the pick sheet: a sorted card has left the deck; otherwise it springs back.
  private func settle() {
    withAnimation(.snappy) { drag = .zero }
  }
}

/// The top card (340 × 430, r28): merchant, the raw bank text, the amount, and the
/// suggestion strip with "Use".
struct ReviewCardView: View {
  let card: ReviewCardModel
  let hidden: Bool
  let lean: ReviewChoice?
  let strength: Double
  let use: () -> Void
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top) {
          MonogramDisc(card.monogram, size: 56)
          Spacer()
          if card.isNewMerchant {
            StatusPillView(StatusPill("New merchant", tone: .accent), surface: .tinted)
          }
        }
        Text(card.merchant).hType(.title2).foregroundStyle(HColor.textPrimary)
        if let raw = card.rawMerchant {
          Text(verbatim: raw)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(HColor.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(HColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityLabel("As your bank wrote it: \(raw)")
        }
        Spacer(minLength: 24)
        MoneyText(card.amount, figure: .hero, unit: .displayUnit, hidden: hidden, hiddenGlyphs: 5,
                  color: card.isIncome ? HColor.moneyIn : HColor.textPrimary, sign: card.isIncome ? .income : .none)
        Text(card.meta).hType(.footnote).foregroundStyle(HColor.textSecondary)
      }
      .padding(20)
      // The card drags, so its texts read as one element rather than many small targets.
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(spoken)
      .accessibilityIdentifier("review.merchant")
      if let s = card.suggestion {
        let strip = typeSize.isAccessibilitySize
          ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
          : AnyLayout(HStackLayout(spacing: 12))
        strip {
          HStack(spacing: 12) {
            HueDisc(hue: s.hue, glyph: s.glyph, size: 32, iconSize: 16)
            Text("Looks like \(s.name)").hType(.rowTitle).foregroundStyle(HColor.textPrimary)
          }
          .frame(minHeight: 44)
          .accessibilityElement(children: .combine)
          if !typeSize.isAccessibilitySize { Spacer() }
          Button("Use", action: use)
            .buttonStyle(.pill(.primary, size: .small))
            .accessibilityLabel("Use \(s.name)")
            .accessibilityIdentifier("review.use")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, typeSize.isAccessibilitySize ? 12 : 0)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(HColor.surfaceCanvas.opacity(0.72))
        .overlay(alignment: .top) { Rectangle().fill(HColor.listRowSeparator).frame(height: 0.5) }
      }
    }
    .frame(maxWidth: .infinity, minHeight: 430, alignment: .top)
    .background(HColor.surfacePrimary)
    .overlay {
      // The lean glow: the bucket's hue from the edge the card leans toward.
      if let lean, strength > 0 {
        LinearGradient(colors: [lean.hue.end.opacity(0.58 * strength), .clear],
                       startPoint: glowStart(lean), endPoint: .center)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    .shadow(color: .black.opacity(0.04), radius: 2, y: 2)
    .shadow(color: .black.opacity(0.11), radius: 22, y: 18)
  }

  /// "Lulu Hypermarket, new merchant, AED 214.30, Spent · Fri 9 Oct, 18:42 · DIB card ···8891".
  private var spoken: String {
    let amount = hidden
      ? "Amount hidden"
      : (card.isIncome ? "plus " : "") + "\(card.amount.currency) \(MoneyFormat.string(card.amount.minor))"
    return [card.merchant, card.isNewMerchant ? "new merchant" : nil,
            card.rawMerchant.map { "as your bank wrote it: \($0)" }, amount, card.meta]
      .compactMap { $0 }.joined(separator: ", ")
  }

  private func glowStart(_ c: ReviewChoice) -> UnitPoint {
    switch c {
    case .need: .trailing
    case .want: .leading
    case .save: .bottom
    case .transfer: .top
    }
  }
}

/// Pick a need (Paper board), and its Want, Save and Transfer equivalents: which
/// category, an optional project, and "Always use X for M".
struct BucketPickSheet: View {
  let model: any ReviewDeckModel
  let pick: ReviewDeckView.Pick
  let sort: (CategoryID, Bool, ProjectID?) -> Void

  @State private var selected: CategoryID?
  @State private var project: ProjectID?
  @State private var alwaysUse = true
  @Environment(\.dismiss) private var dismiss

  private var options: [CategoryOption] { model.options(for: pick.choice, card: pick.card.id) }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          ListCard {
            ForEach(options) { o in
              Button { selected = o.id } label: {
                HStack(spacing: HSpacing.listRowGap) {
                  HueDisc(hue: o.hue, glyph: o.glyph)
                  Text(o.name).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
                  if pick.card.suggestion?.id == o.id { InfoTag("Suggested", tone: .accent) }
                  Spacer()
                  if selected == o.id {
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .bold))
                      .foregroundStyle(HColor.listRowCheck)
                  }
                }
                .padding(.horizontal, HSpacing.listRowInsetInline)
                .frame(minHeight: HSpacing.listRowMinHeight)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityAddTraits(selected == o.id ? .isSelected : [])
              .accessibilityIdentifier("pick.\(o.id)")
            }
          }
          if !model.projects.isEmpty, pick.choice != .transfer {
            Text("Project").hType(.overline).foregroundStyle(HColor.textSecondary)
            HStack(spacing: 8) {
              FilterChip("None", selected: project == nil) { project = nil }
              ForEach(model.projects, id: \.id) { p in
                FilterChip(p.name, selected: project == p.id) { project = p.id }
              }
            }
          }
          Toggle(isOn: $alwaysUse) {
            Text("Always use \(selectedName ?? "it") for \(pick.card.merchant)").hType(.callout)
              .foregroundStyle(HColor.textPrimary)
          }
          .toggleStyle(CheckboxToggleStyle())
          .accessibilityIdentifier("pick.alwaysUse")
        }
        .padding(HSpacing.insetPage)
      }
      .background(HColor.surfaceSecondary)
      .safeAreaInset(edge: .bottom) {
        Button(selectedName.map { "Sort into \($0)" } ?? "Choose a category") {
          if let selected { sort(selected, alwaysUse, project) }
        }
        .buttonStyle(.pill(.primary, fill: true))
        .disabled(selected == nil)
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.bottom, 8)
        .accessibilityIdentifier("pick.sort")
      }
      .navigationTitle("\(pick.choice.label) · which one?")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { SheetCloseButton(identifier: "pick.close") { dismiss() } }
      .onAppear {
        selected = options.first { $0.id == pick.card.suggestion?.id }?.id ?? options.first?.id
        alwaysUse = pick.choice != .transfer
      }
    }
  }

  private var selectedName: String? { options.first { $0.id == selected }?.name }
}

/// A blue r6 checkbox (spec 04 §14.6 `CheckboxSquare`).
struct CheckboxToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button { configuration.isOn.toggle() } label: {
      HStack(alignment: .top, spacing: 12) {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(configuration.isOn ? HColor.actionAccent : HColor.surfacePrimary)
          .overlay {
            if configuration.isOn {
              Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(HColor.white)
            } else {
              RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(HColor.iconTertiary, lineWidth: 1.5)
            }
          }
          .frame(width: 24, height: 24)
        configuration.label
        Spacer(minLength: 0)
      }
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
  }
}

/// All caught up (Paper board): what this session sorted and what the plan now counts.
struct ReviewDoneView: View {
  let model: any ReviewDeckModel
  @State private var celebrated = 0

  var body: some View {
    let sorted = model.sorted
    let rules = sorted.filter(\.learnedRule).count
    let counted = sorted.reduce(Int64(0)) { $0 + $1.counted }
    ScrollView {
      VStack(spacing: 18) {
        Circle().fill(Hue.mint.gradient).frame(width: 72, height: 72)
          .overlay { Image(systemName: "checkmark").font(.system(size: 30, weight: .bold)).foregroundStyle(Hue.mint.ink) }
          .accessibilityHidden(true)
          .padding(.top, 24)
        VStack(spacing: 4) {
          Text("All caught up").hType(.title1).foregroundStyle(HColor.textPrimary)
            .accessibilityIdentifier("review.done")
          Text(sorted.isEmpty ? "Nothing waiting to sort."
            : "\(sorted.count) sorted" + (rules > 0 ? " · \(rules) new rule\(rules == 1 ? "" : "s")" : ""))
            .hType(.body).foregroundStyle(HColor.textSecondary)
        }
        if !sorted.isEmpty {
          VStack(alignment: .leading, spacing: 0) {
            PhraseText(MoneyPhrase([.text("Your plan now counts AED "), .amount(.aed(counted)), .text(" more")]),
                       hidden: model.hidden)
              .hType(.headline).foregroundStyle(HColor.textPrimary)
              .padding(16)
            ForEach(sorted) { line in
              Divider().padding(.leading, 68)
              TxnRow(MiniTxnRow(id: line.id, merchant: line.merchant, glyph: line.glyph, hue: line.hue,
                                detail: line.detail, amount: line.amount, isIncome: line.isIncome),
                     hidden: model.hidden)
                .padding(.horizontal, 16)
            }
          }
          .listCard()
        }
        Button("Back to Activity") { model.close(goToActivity: true) }
          .buttonStyle(.pill(.primary, fill: true))
          .accessibilityIdentifier("review.backToActivity")
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.bottom, 40)
    }
    .sensoryFeedback(.success, trigger: celebrated)
    .onAppear { celebrated += 1 }
  }
}

#if HASALA_MOCKS
  #Preview("Review · Deck") {
    let app = AppModel(store: InMemoryLedger())
    ReviewDeckView(app: app, model: ReviewViewModel(app: app))
  }
#endif
