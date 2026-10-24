import HasalaDesign
import HasalaModels
import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

/// Review · Deck (Paper 26H-0): a focused full-screen flow, one card at a time. Drag right
/// for Need, left for Want, down for Save, up for Transfer (the horizontal pair follows the
/// Swipe directions setting), or tap the pill on that side: both do the same thing.
///
/// The card follows the finger and tilts, 3° at the commit point; the glow and the pill on
/// that side wake as it goes, and the pill turns active with a light tap as the card crosses
/// the commit point. Let go before it and the card springs back (`.cardReturn`); let go past
/// it (or flick) and the pick sheet asks which category. Filing flies the card out (200 ms,
/// `.cardCommit`, 140% of its width and 16°, fading) while the next one rises into place on
/// spring-drop (`.cardNext`, 0.96 → 1, lifting 8). "Use" files the suggestion the same way.
/// With Reduce Motion nothing tilts or travels: the card fades and the next fades in.
struct ReviewDeckView: View {
  @Bindable var app: AppModel
  let model: any ReviewDeckModel

  /// Where the finger has the top card.
  @State private var drag: CGSize = .zero
  @GestureState private var touched: TxnID?
  /// The edge the card is dragged past the commit point toward.
  @State private var crossed: SwipeEdge?
  /// The edge the card is held toward while its pick sheet is up.
  @State private var held: SwipeEdge?
  /// Cards on their way out, drawn over the deck until their flight ends.
  @State private var flights: [Flight] = []
  /// The edge each filed card left by, so Undo brings it back from that side.
  @State private var departures: [String: SwipeEdge] = [:]
  /// One light tap per commit (`HHaptic.impactLight`, plan B1.4).
  @State private var tap = 0
  /// The pick sheet's choice, filed once the sheet has gone.
  @State private var pendingSort: PendingSort?
  @State private var reasonInfo: ReviewCardModel?
  @State private var pendingArchive: ReviewCardModel?
  @State private var pendingCopy: (card: ReviewCardModel, merge: Bool)?
  @State private var choosingRange = false

  private struct PendingSort {
    let pick: ReviewPick
    let category: CategoryID
    let alwaysUse: Bool
    let project: ProjectID?
  }

  @Environment(\.hMotion) private var policy
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.dynamicTypeSize) private var typeSize

  /// The deck's motion: the app's policy, honouring the system setting even without it.
  private var motion: MotionPolicy {
    MotionPolicy(reduceMotion: policy.reduceMotion || systemReduceMotion, settled: policy.settled)
  }

  /// Cards remain, or the last one is still flying out.
  private var showsDeck: Bool { !model.cards.isEmpty || !flights.isEmpty }

  var body: some View {
    let top = model.cards.first
    VStack(spacing: 0) {
      header(done: !showsDeck)
      rangeRow
      progress
      Group {
        if showsDeck {
          deck(top)
            .transition(.opacity)
        } else {
          ReviewDoneView(model: model)
            .transition(.opacity)
        }
      }
      .frame(maxHeight: .infinity)
      .animation(motion.animation(.stateSwap), value: showsDeck)
      .sheet(item: $reasonInfo, onDismiss: reasonInfoClosed) { card in
        if let reason = card.reviewReason {
          ReviewReasonSheet(
            reason: reason, sort: { reasonInfo = nil },
            archive: {
              pendingArchive = card
              reasonInfo = nil
            },
            merge: {
              pendingCopy = (card, true)
              reasonInfo = nil
            },
            keepBoth: {
              pendingCopy = (card, false)
              reasonInfo = nil
            })
        }
      }
    }
    .background(alignment: .top) { AmbientWash(.onTrack).ignoresSafeArea() }
    .background(HColor.surfaceSecondary)
    // On the bottom safe area for All caught up and the scrolling deck at the largest
    // text sizes; otherwise the deck carries it just above its footer (`deck`).
    .overlay(alignment: .bottom) {
      if !showsDeck || typeSize.isAccessibilitySize { ToastHost(app: app, placement: .bottom) }
    }
    .hHaptic(.impactLight, trigger: tap)
    .sheet(item: pickBinding, onDismiss: pickClosed) { pick in
      ReviewPickSheet(model: model, pick: pick) { category, alwaysUse, project in
        sortPicked(pick, into: category, alwaysUse: alwaysUse, project: project)
      }
    }
    .onAppear {
      SortSound.shared.prepare()
      // A pick sheet already up (a Debug screen launch): hold the card toward it.
      if let p = model.picking { holdToward(edge(for: p.choice), animated: false) }
    }
    .onDisappear { SortSound.shared.rest() }
    .onChange(of: touched) { _, now in
      if now == nil { released() }
    }
  }

  private var pickBinding: Binding<ReviewPick?> {
    Binding(get: { model.picking }, set: { model.picking = $0 })
  }

  // MARK: Header and progress

  /// Close, "Review" over "2 of 6", More (Paper "Header · Review").
  private func header(done: Bool) -> some View {
    HStack {
      GlassIconButton(.close, label: "Close") { model.close(goToActivity: false) }
        .accessibilityIdentifier("review.close")
      Spacer()
      VStack(spacing: 0) {
        Text("Review")
          .hType(.headline.weight(.semibold))
          .foregroundStyle(HColor.textPrimary)
          .accessibilityAddTraits(.isHeader)
        if model.total > 0 {
          Text("\(model.position) of \(model.total)")
            .hFigure(HFigure(size: 13, leading: 18, weight: .medium, textStyle: .footnote, tabular: true))
            .foregroundStyle(HColor.textSecondary)
            .numberRoll(Double(model.position))
            .accessibilityIdentifier("review.position")
        }
      }
      Spacer()
      moreMenu
        .opacity(done ? 0 : 1)
        .disabled(done)
    }
    .padding(.horizontal, HSpacing.insetPage)
    .padding(.top, 6)
    .frame(minHeight: 54)
  }

  private var rangeRow: some View {
    PeriodPill(model.periodTitle, tinted: !model.isThisMonth) { choosingRange = true }
      .accessibilityIdentifier("review.period")
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
      .sheet(isPresented: $choosingRange) {
        PeriodSheet(app: app) { model.periodChanged() }
      }
  }

  private var moreMenu: some View {
    Menu {
      if let top = model.cards.first {
        Button("Skip for now") { skip(top) }
        if BuildSurface.showsUnfinished {
          // TODO(spec 04 §16.2 G7): the bank email, once the holder re-fetch exists.
          Button("View bank email") { app.say("The bank email opens in a later build", icon: .envelope) }
        }
      }
    } label: {
      HIconView(.more, size: HSpacing.iconGlass, color: HColor.iconGlass)
        .frame(width: HSpacing.glassButton, height: HSpacing.glassButton)
        .hGlass(in: Circle())
        .contentShape(Circle())
    }
    .accessibilityLabel("More")
    .accessibilityIdentifier("review.more")
  }

  /// "2 of 6" as a bar: 6 tall, radius 3, accent on the pace track, filled to the card in
  /// front (Paper: 121 of 362 at 2 of 6, full at All caught up).
  private var progress: some View {
    let step = showsDeck ? model.position : model.total
    let share = model.total > 0 ? Double(step) / Double(model.total) : 1
    return GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(HColor.paceTrack)
        Capsule().fill(HColor.actionAccent)
          .frame(width: geo.size.width * share)
          .hAnimation(.fillUpdate, value: step)
      }
    }
    .frame(height: HSpacing.progressHeight)
    .padding(.horizontal, HSpacing.insetPage)
    .padding(.top, 16)
    .accessibilityHidden(true)
  }

  // MARK: Deck

  /// At the accessibility text sizes the deck scrolls, the card does not drag (the pills,
  /// "Use" and the VoiceOver actions sort it), and Want and Need sit under the card instead
  /// of over its text (spec 04 §17).
  @ViewBuilder
  private func deck(_ top: ReviewCardModel?) -> some View {
    if typeSize.isAccessibilitySize {
      ScrollView {
        VStack(spacing: 12) {
          pill(.up)
          stack(top)
          HStack(spacing: 12) {
            pill(.left)
            pill(.right)
          }
          pill(.down)
          footer(top)
        }
        .padding(.top, 20)
        .padding(.bottom, 24)
      }
    } else {
      VStack(spacing: 0) {
        // Transfer and Save keep Paper's 44 slot: active, a pill grows to 48 about its
        // middle instead of pushing the card 4 down (a jump with Reduce Motion).
        pill(.up).frame(height: Self.pillSlot).padding(.top, 20)
        stack(top)
          .overlay {
            // Want and Need ride the card's middle, 10 from the screen's edges.
            HStack {
              pill(.left)
              Spacer(minLength: 0)
              pill(.right)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, Self.peekDepth)
          }
          .padding(.top, 20)
          .layoutPriority(1)
        pill(.down).frame(height: Self.pillSlot).padding(.top, 22)
        Spacer(minLength: 12)
        footer(top)
          .padding(.bottom, 2)
          // The toast after a sort sits just above Skip, in the room under the Save pill,
          // so neither Skip nor the pills are covered while its Undo waits.
          .overlay(alignment: .top) {
            ToastHost(app: app, placement: .bottom)
              .padding(.horizontal, -HSpacing.insetPage)
              .alignmentGuide(.top) { $0[.bottom] + 4 }
          }
      }
    }
  }

  /// The two peeks a further 10 down each.
  private static let peekDepth: CGFloat = 20
  /// The idle direction pill's height (Paper "Direction pill · Transfer (top)", 402 × 44).
  private static let pillSlot: CGFloat = 44

  /// The top card over two peeks (Paper: 340 × 430, peeks 324 and 308 wide, 10 steps down),
  /// and any card still flying out.
  private func stack(_ top: ReviewCardModel?) -> some View {
    let count = model.cards.count
    return ZStack(alignment: .top) {
      if count > 2 { peek(inset: 16, depth: 20, far: true) }
      if count > 1 { peek(inset: 8, depth: 10, far: false) }
      if let top {
        live(top)
          .id(top.id)
          .transition(arrival(for: top.id))
      }
      ForEach(flights) { flight in
        FlyingCard(flight: flight, hidden: model.hidden, motion: motion) {
          flights.removeAll { $0.id == flight.id }
        }
      }
    }
    // At the accessibility sizes the card grows with its words and the deck scrolls.
    .frame(maxWidth: Self.cardWidth, minHeight: typeSize.isAccessibilitySize ? Self.cardHeight : 300,
           maxHeight: typeSize.isAccessibilitySize ? .infinity : Self.cardHeight)
    .padding(.bottom, Self.peekDepth)
    .padding(.horizontal, 31)
    // Undo, a skip or a sort from elsewhere: the card that arrives rises on spring-drop.
    .animation(motion.animation(.cardNext), value: top?.id)
    .animation(motion.animation(.fade), value: count)
  }

  static let cardWidth: CGFloat = 340
  static let cardHeight: CGFloat = 430

  private func peek(inset: CGFloat, depth: CGFloat, far: Bool) -> some View {
    RoundedRectangle(cornerRadius: HRadius.reviewCard, style: .continuous)
      .fill(HColor.surfacePrimary)
      .shadow(color: .black.opacity(0.03), radius: 1, y: 1)
      .shadow(color: .black.opacity(far ? 0.04 : 0.05), radius: far ? 8 : 10, y: far ? 6 : 8)
      .padding(.horizontal, inset)
      .offset(y: depth)
      .accessibilityHidden(true)
      .transition(.opacity)
  }

  /// The top card: it follows the finger, tilts with the horizontal drag, and carries the
  /// VoiceOver actions that do what the swipes do.
  private func live(_ card: ReviewCardModel) -> some View {
    let lean = leanEdge
    return ReviewCardView(
      card: card, hidden: model.hidden, lean: lean.map(choice(for:)), leanEdge: lean, strength: leanStrength,
      use: { use(card) },
      merge: { resolveCopy(card, merge: true) },
      keepBoth: { resolveCopy(card, merge: false) },
      reason: { reasonInfo = card },
      actions: {
        if card.copyLine != nil {
          Button(card.samePurchase ? "Same purchase" : "Merge") { resolveCopy(card, merge: true) }
          Button("Keep both") { resolveCopy(card, merge: false) }
        }
        ForEach(ReviewChoice.allCases, id: \.self) { c in
          Button(c.label) { send(card, c) }
        }
        if card.reviewReason == nil, card.copyLine == nil, let s = card.suggestion {
          Button("Use \(s.name)") { use(card) }
        }
        Button("Skip for now") { skip(card) }
        if card.reviewReason != nil {
          Button("About this alert") { reasonInfo = card }
        }
      }
    )
    .modifier(LiveCard(drag: drag, tilt: tilt, gesture: dragGesture(card), passive: typeSize.isAccessibilitySize || held != nil))
    .accessibilityIdentifier("review.card")
  }

  /// The live card's angle: with the horizontal drag, 3° at the commit point and no more;
  /// held toward Need or Want while its pick sheet is up, the full 3° (Paper "Pick a need").
  private var tilt: Double {
    if motion.isStill { return 0 }
    switch held {
    case .right: return HMotion.commitTilt
    case .left: return -HMotion.commitTilt
    case .up, .down: return 0
    case nil: return SwipePhysics.tilt(dx: drag.width, atCommit: HMotion.commitTilt)
    }
  }

  /// Where the card leans: the finger's direction, or the side it is held toward.
  private var leanEdge: SwipeEdge? {
    if let held { return held }
    guard drag != .zero else { return nil }
    return SwipePhysics.preview(dx: drag.width, dy: drag.height)
  }

  private var leanStrength: Double {
    held != nil ? 1 : SwipePhysics.strength(dx: drag.width, dy: drag.height)
  }

  /// The arriving card: back from the side it left by (Undo), or up from the peek.
  private func arrival(for id: String) -> AnyTransition {
    if motion.settled { return .identity }
    if motion.reduceMotion { return .asymmetric(insertion: .opacity, removal: .identity) }
    if let edge = departures[id] {
      let far = Flight.target(edge, width: Self.cardWidth, height: Self.cardHeight)
      return .asymmetric(insertion: .offset(far).combined(with: .opacity), removal: .identity)
    }
    return .asymmetric(insertion: motion.transition(.cardNext), removal: .identity)
  }

  // MARK: Pills

  private func choice(for edge: SwipeEdge) -> ReviewChoice {
    SwipePhysics.choice(for: edge, needOnRight: model.needOnRight)
  }

  private func edge(for choice: ReviewChoice) -> SwipeEdge {
    SwipePhysics.edge(for: choice, needOnRight: model.needOnRight)
  }

  /// A direction pill: idle glass, waking toward 1.06 as the card leans its way, active
  /// (48, the bucket's tint and ring) past the commit point. A real button, 44 at least.
  private func pill(_ edge: SwipeEdge) -> some View {
    let choice = choice(for: edge)
    let active = crossed == edge || held == edge
    let waking = !active && leanEdge == edge ? leanStrength : 0
    return Button {
      if let top = model.cards.first { send(top, choice) }
    } label: {
      DirectionPillLabel(choice: choice, edge: edge, active: active)
    }
    .buttonStyle(HPressStyle(in: Capsule()))
    .scaleEffect(motion.isStill ? 1 : 1 + 0.06 * waking)
    .hAnimation(.thumbSlide, value: active)
    // Paper's Pick a need draws the deck without its pills or footer behind the sheet.
    .opacity(model.picking == nil ? 1 : 0)
    .hAnimation(.fade, value: model.picking == nil)
    .disabled(model.cards.isEmpty)
    .accessibilityLabel("Sort as \(choice.label)")
    .accessibilityIdentifier("review.pill.\(choice.rawValue)")
  }

  // MARK: Footer

  private func footer(_ top: ReviewCardModel?) -> some View {
    HStack(spacing: 0) {
      footerLink("Skip for now", id: "review.skip") {
        if let top { skip(top) }
      }
      if BuildSurface.showsUnfinished {
        HColor.borderSubtle.frame(width: 1, height: 20)
        Button {
          // TODO(spec 04 §16.2 G7): the bank email, once the holder re-fetch exists.
          app.say("The bank email opens in a later build", icon: .envelope)
        } label: {
          HStack(spacing: 6) {
            PathGlyph(PathGlyph.envelope, size: 18, color: HColor.textLink, stroke: 1.9)
            Text("View bank email").hType(.callout.weight(.semibold)).foregroundStyle(HColor.textLink)
          }
          .frame(maxWidth: .infinity, minHeight: HSpacing.targetMinimum)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("review.viewEmail")
      }
    }
    .disabled(top == nil)
    .padding(.horizontal, HSpacing.insetPage)
    .opacity(model.picking == nil ? 1 : 0)
    .hAnimation(.fade, value: model.picking == nil)
  }

  private func footerLink(_ title: String, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .hType(.callout.weight(.semibold))
        .foregroundStyle(HColor.textLink)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: HSpacing.targetMinimum)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(id)
  }

  // MARK: Gesture

  private func dragGesture(_ card: ReviewCardModel) -> some Gesture {
    DragGesture(minimumDistance: 6)
      .updating($touched) { _, state, _ in state = card.id }
      .onChanged { value in
        if model.holding != card.id { model.holding = card.id }
        drag = value.translation
        let past = SwipePhysics.pastCommit(dx: drag.width, dy: drag.height)
        if past != crossed {
          // The light tap plays as the card crosses into a commit, not as it comes back.
          if past != nil { tap += 1 }
          crossed = past
        }
      }
      .onEnded { value in
        let edge = SwipePhysics.commit(
          dx: value.translation.width, dy: value.translation.height,
          vx: value.velocity.width, vy: value.velocity.height)
        guard let edge else {
          withAnimation(motion.animation(.cardReturn)) {
            drag = .zero
            crossed = nil
          }
          model.holding = nil
          return
        }
        // A flick commits without crossing: it still gets its tap.
        if crossed != edge { tap += 1 }
        crossed = nil
        // The card settles on its side, leaning, while the sheet asks which category.
        holdToward(edge, animated: true)
        model.pick(card.id, choice(for: edge))
      }
  }

  private func released() {
    guard model.picking == nil, held == nil else { return }
    model.holding = nil
    guard drag != .zero || crossed != nil else { return }
    withAnimation(motion.animation(.cardReturn)) {
      drag = .zero
      crossed = nil
    }
  }

  // MARK: Filing

  /// A pill (or a VoiceOver action) sends the card one way: it leans there and the pick
  /// sheet asks which category.
  private func send(_ card: ReviewCardModel, _ choice: ReviewChoice) {
    tap += 1
    model.holding = card.id
    holdToward(edge(for: choice), animated: true)
    model.pick(card.id, choice)
  }

  /// Holds the card toward its pill while the pick sheet is up. With Reduce Motion the card
  /// stays at rest (spec 12: a static card): only the pill and the glow show the choice, and
  /// a card the finger let go of elsewhere goes back to rest at once.
  private func holdToward(_ edge: SwipeEdge, animated: Bool) {
    let lean: CGFloat = motion.reduceMotion ? 0 : 40
    let pose: CGSize = switch edge {
    case .left: CGSize(width: -lean, height: 0)
    case .right: CGSize(width: lean, height: 0)
    case .up: CGSize(width: 0, height: -lean)
    case .down: CGSize(width: 0, height: lean)
    }
    withAnimation(animated ? motion.animation(.cardReturn) : nil) {
      held = edge
      drag = pose
    }
  }

  /// The pick sheet's "Sort into Groceries": the sheet goes, then the card flies to its side
  /// and the toast comes up (Paper: "files the card, closes the sheet, and advances the
  /// deck"; "a toast may appear after a sheet closes, never on top of one"). Filing once the
  /// sheet is down also keeps the fly-out from sharing frames with the sheet's own motion.
  private func sortPicked(_ pick: ReviewPick, into category: CategoryID, alwaysUse: Bool, project: ProjectID?) {
    pendingSort = PendingSort(pick: pick, category: category, alwaysUse: alwaysUse, project: project)
    model.picking = nil
  }

  /// The sheet has gone: file what it chose, or, closed without a sort (close, swipe down,
  /// the scrim), spring the card back.
  private func pickClosed() {
    if let p = pendingSort {
      pendingSort = nil
      let edge = held ?? edge(for: p.pick.choice)
      file(p.pick.card, toward: edge, as: p.pick.choice.label, chime: true) {
        model.sort(p.pick.card.id, into: p.category, alwaysUse: p.alwaysUse, project: p.project)
      }
      return
    }
    model.holding = nil
    guard held != nil else { return }
    withAnimation(motion.animation(.cardReturn)) {
      drag = .zero
      held = nil
    }
  }

  /// "Use": files the suggestion, flying the card toward its bucket's side.
  private func use(_ card: ReviewCardModel) {
    guard card.reviewReason == nil, let s = card.suggestion else { return }
    tap += 1
    file(card, toward: edge(for: ReviewChoice(filing: s.bucket)), as: s.name, chime: true) {
      model.useSuggestion(card.id)
    }
  }

  private func resolveCopy(_ card: ReviewCardModel, merge: Bool) {
    tap += 1
    if card.samePurchase {
      file(card, toward: nil, as: merge ? "Same purchase" : "Kept both") {
        model.resolveSamePurchase(card.id, same: merge)
      }
      return
    }
    file(card, toward: nil, as: merge ? "Merged" : "Kept both") {
      model.resolveCopy(card.id, merge: merge)
    }
  }

  private func reasonInfoClosed() {
    if let copy = pendingCopy {
      pendingCopy = nil
      resolveCopy(copy.card, merge: copy.merge)
      return
    }
    guard let card = pendingArchive else { return }
    pendingArchive = nil
    file(card, toward: nil, as: nil) { model.archive(card.id) }
  }

  private func skip(_ card: ReviewCardModel) {
    file(card, toward: nil, as: nil) {
      model.skip(card.id)
      return true
    }
  }

  /// Takes the card off the deck: it flies from where it is now (or fades, for a skip and
  /// with Reduce Motion) while the edit lands and the next card rises.
  private func file(
    _ card: ReviewCardModel, toward edge: SwipeEdge?, as filedAs: String?, chime: Bool = false, _ edit: () -> Bool
  ) {
    let from = drag
    let tilt = tilt
    var done = false
    withAnimation(motion.animation(.cardNext)) {
      done = edit()
      model.holding = nil
      if done {
        drag = .zero
        held = nil
        crossed = nil
      }
    }
    guard done else {
      withAnimation(motion.animation(.cardReturn)) {
        drag = .zero
        held = nil
      }
      return
    }
    if chime { SortSound.shared.play() }
    if let edge { departures[card.id] = edge }
    if !motion.settled {
      flights.append(Flight(card: card, from: from, tilt: tilt, edge: edge))
    }
    if let filedAs { announce(model.filedAnnouncement(filedAs)) }
  }

  /// After the toast's own announcement ("Sorted into Groceries. Undo available."), queued.
  private func announce(_ text: String) {
    var line = AttributedString(text)
    line.accessibilitySpeechAnnouncementPriority = .low
    AccessibilityNotification.Announcement(line).post()
  }
}

private struct LiveCard<G: Gesture>: ViewModifier {
  let drag: CGSize
  let tilt: Double
  let gesture: G
  let passive: Bool

  func body(content: Content) -> some View {
    content
      .offset(drag)
      .rotationEffect(.degrees(tilt))
      .gesture(gesture, including: passive ? .subviews : .all)
      // A container, so the identifier names the card without replacing its elements' own
      // (`review.merchant`, `review.use`).
      .accessibilityElement(children: .contain)
  }
}

/// A card on its way out: it starts where the finger left it and flies 140% of its size
/// toward its edge, turning to 16° and fading, over 200 ms; a skip only fades and settles
/// back a little. With Reduce Motion it fades in place.
struct Flight: Identifiable {
  let id = UUID()
  let card: ReviewCardModel
  let from: CGSize
  let tilt: Double
  let edge: SwipeEdge?

  static func target(_ edge: SwipeEdge, width: CGFloat, height: CGFloat) -> CGSize {
    switch edge {
    case .left: CGSize(width: -width * HMotion.cardFlyOut, height: 0)
    case .right: CGSize(width: width * HMotion.cardFlyOut, height: 0)
    case .up: CGSize(width: 0, height: -height * HMotion.cardFlyOut)
    case .down: CGSize(width: 0, height: height * HMotion.cardFlyOut)
    }
  }
}

private struct FlyingCard: View {
  let flight: Flight
  let hidden: Bool
  let motion: MotionPolicy
  let landed: () -> Void
  /// Travelled and turned.
  @State private var gone = false
  /// Faded out.
  @State private var faded = false

  var body: some View {
    ReviewCardView(card: flight.card, hidden: hidden, lean: nil, leanEdge: nil, strength: 0, use: {})
      .scaleEffect(gone && flight.edge == nil && travels ? HMotion.nextCardScale : 1)
      .offset(gone && travels ? offset : flight.from)
      .rotationEffect(.degrees(gone && travels ? angle : flight.tilt))
      .opacity(faded ? 0 : 1)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .onAppear(perform: fly)
  }

  /// The card always leaves from rest (held toward its pill, or still for "Use"), so the
  /// fly-out cannot ride ease-out-soft: that curve covers 60% of the way in the first two
  /// frames and the card was gone before it was seen. It travels and turns at an even pace
  /// over the 200 ms instead, readable for about eight frames before it clears the screen,
  /// and fades on ease-in-out, so it stays solid while it starts and thins as it goes. A
  /// skip, and every card with Reduce Motion, only fades, in place.
  private func fly() {
    guard flight.edge != nil, travels, let curve = motion.curve(.cardCommit) else {
      withAnimation(motion.animation(flight.edge == nil ? .fade : .cardCommit)) {
        gone = true
        faded = true
      } completion: {
        landed()
      }
      return
    }
    let length = curve.nominalDuration
    withAnimation(HMotion.Curve.linear(duration: length).animation) { gone = true }
    withAnimation(HMotion.easeInOut(length)) {
      faded = true
    } completion: {
      landed()
    }
  }

  /// With Reduce Motion nothing travels, turns or shrinks.
  private var travels: Bool { !motion.reduceMotion }

  private var offset: CGSize {
    guard let edge = flight.edge else { return flight.from }
    let t = Flight.target(edge, width: ReviewDeckView.cardWidth, height: ReviewDeckView.cardHeight)
    return CGSize(width: flight.from.width + t.width, height: flight.from.height + t.height)
  }

  private var angle: Double {
    switch flight.edge {
    case .left: -HMotion.cardFlyTilt
    case .right: HMotion.cardFlyTilt
    case .up, .down, nil: flight.tilt
    }
  }
}

/// The inside of a direction pill (Paper "Direction pill · …"): arrow, bucket dot and label
/// on glass; active, the bucket's start tint with a 1 pt end ring, the label 16/22 bold in
/// the bucket's ink. The arrow sits on the side the card goes.
private struct DirectionPillLabel: View {
  let choice: ReviewChoice
  let edge: SwipeEdge
  let active: Bool
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    let hue = choice.pillHue
    let arrowTrails = edge == .right
    HStack(spacing: 8) {
      if !arrowTrails { arrow(hue) }
      HStack(spacing: 6) {
        Circle().fill(hue.dotGradient).frame(width: 10, height: 10)
          .overlay { if active { Circle().strokeBorder(hue.ink.opacity(0.12), lineWidth: 1) } }
        Text(choice.label)
          .hType(active ? .callout.weight(.bold) : .subheadline.weight(.semibold))
          .foregroundStyle(active ? hue.ink : HColor.textPrimary)
          .fixedSize()
      }
      if arrowTrails { arrow(hue) }
    }
    .padding(.leading, arrowTrails ? (active ? 18 : 16) : (active ? 18 : 12))
    .padding(.trailing, arrowTrails ? (active ? 14 : 12) : (active ? 14 : 16))
    .frame(minHeight: active ? 48 : 44)
    .background {
      if active {
        Capsule().fill(hue.start.opacity(reduceTransparency ? 1 : 0.9))
          .overlay { Capsule().strokeBorder(hue.end, lineWidth: 1) }
          .shadow(color: hue.ink.opacity(0.16), radius: 11, y: 8)
          .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
      }
    }
    .hGlass(in: Capsule(), interactive: false)
    .contentShape(Capsule())
  }

  private func arrow(_ hue: Hue) -> some View {
    PathGlyph(PathGlyph.arrow(edge), size: 18, color: active ? hue.ink : HColor.iconGlass, stroke: active ? 2.4 : 2.2)
  }
}

/// The top card (Paper "Card · Lulu Hypermarket", 340 × 430, radius 28): who and what, the
/// bank's own words, the amount at hero size, and the suggestion strip with "Use". The glow of
/// the bucket it leans toward fades in from that edge.
struct ReviewCardView<Actions: View>: View {
  let card: ReviewCardModel
  let hidden: Bool
  let lean: ReviewChoice?
  let leanEdge: SwipeEdge?
  let strength: Double
  let use: () -> Void
  var merge: () -> Void = {}
  var keepBoth: () -> Void = {}
  var reason: () -> Void = {}
  @ViewBuilder let actions: () -> Actions
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        identity
        Spacer(minLength: 24)
        amount
      }
      .padding(.top, 24)
      .padding(.horizontal, 24)
      .padding(.bottom, 22)
      // The card drags, so its words read as one element; the sorts are its actions.
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(spoken)
      .accessibilityActions { actions() }
      .accessibilityIdentifier("review.merchant")
      if let line = card.copyLine {
        copyStrip(line)
      } else if let r = card.reviewReason {
        reasonStrip(r)
      } else if let s = card.suggestion {
        strip(s)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(HColor.surfacePrimary)
    .overlay { glow }
    .clipShape(RoundedRectangle(cornerRadius: HRadius.reviewCard, style: .continuous))
    .background {
      RoundedRectangle(cornerRadius: HRadius.reviewCard, style: .continuous)
        .fill(HColor.surfacePrimary)
        .shadow(color: .black.opacity(0.04), radius: 2, y: 2)
        .shadow(color: .black.opacity(0.11), radius: 22, y: 18)
        .shadow(color: (lean?.pillHue.end ?? .clear).opacity(0.9 * strength), radius: 20,
                x: glowShift.width, y: glowShift.height)
    }
  }

  private var identity: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top) {
        if card.copyLine == nil, !card.isNewMerchant, let s = card.suggestion {
          CategoryDisc(hue: s.hue, icon: s.glyph.icon, size: .s56)
        } else {
          MerchantMonogram(letter: card.monogram, size: 56)
        }
        Spacer(minLength: 8)
        if let r = card.reviewReason {
          Button(action: reason) {
            InfoChip(r.label, style: ReviewReasonStyle.chip(r))
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("review.reason.\(r.rawValue)")
        } else if card.isNewMerchant {
          InfoChip("New merchant", style: .reason)
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        Text(card.merchant)
          .hType(.section)
          .foregroundStyle(HColor.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
        if let raw = card.rawMerchant {
          InfoChip(raw, style: .rawText)
        }
      }
      .padding(.top, 16)
    }
  }

  private var amount: some View {
    VStack(alignment: .leading, spacing: 4) {
      MoneyText(card.amount, figure: .hero, unit: .unit, hidden: hidden,
                color: card.isIncome ? HColor.moneyIn : HColor.moneyOut,
                unitColor: card.isIncome ? HColor.moneyIn : HColor.textPrimary, unitGap: 6,
                sign: card.isIncome ? .income : .none)
      Text(card.meta).hType(.footnote).foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func copyStrip(_ line: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(line)
        .hType(.subheadline.weight(.semibold))
        .foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("review.copy")
      HStack(spacing: 8) {
        Button("Keep both", action: keepBoth)
          .buttonStyle(.pill(.secondary, size: .small))
          .accessibilityIdentifier("review.keepBoth")
        Button(card.samePurchase ? "Same purchase" : "Merge", action: merge)
          .buttonStyle(.pill(.primary, size: .small))
          .accessibilityIdentifier(card.samePurchase ? "review.same" : "review.merge")
      }
    }
    .padding(.top, 14)
    .padding(.bottom, 14)
    .padding(.leading, 24)
    .padding(.trailing, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.reviewSuggestionSurface)
    .overlay(alignment: .top) { HColor.borderSubtle.frame(height: 1) }
  }

  private func reasonStrip(_ r: TxnReviewReason) -> some View {
    let ink = ReviewReasonStyle.ink(r)
    return Button(action: reason) {
      HStack(spacing: 12) {
        Circle().fill(HColor.surfacePrimary).frame(width: 32, height: 32)
          .overlay { HIconView(ReviewReasonStyle.icon(r), size: 16, color: ink, strokeWidth: 2) }
        Text(r.detail)
          .hType(.footnote.weight(.medium))
          .foregroundStyle(ink)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        HIconView(.chevronRight, size: 16, color: ink)
      }
      .padding(.vertical, 14)
      .padding(.leading, 24)
      .padding(.trailing, 16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(ReviewReasonStyle.surface(r))
      .overlay(alignment: .top) { HColor.borderSubtle.frame(height: 1) }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(r.title). \(r.detail)")
    .accessibilityHint("Shows what this means and what to do")
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("review.reasonStrip.\(r.rawValue)")
  }

  /// "Looks like Groceries" with "Use" (Paper "Suggestion strip": 14 / 16 / 14 / 24, gap 12).
  private func strip(_ s: CategoryOption) -> some View {
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
      : AnyLayout(HStackLayout(spacing: 12))
    return layout {
      HStack(spacing: 12) {
        CategoryDisc(hue: s.hue, icon: s.glyph.icon, size: .s32)
        VStack(alignment: .leading, spacing: 2) {
          Text("Looks like \(s.name)")
            .hType(.subheadline.weight(.semibold))
            .foregroundStyle(HColor.textPrimary)
          if let by = card.suggestedBy {
            Text(by)
              .hType(.footnote)
              .foregroundStyle(HColor.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("review.suggestedBy")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityElement(children: .combine)
      Button("Use", action: use)
        .buttonStyle(.pill(.primary, size: .small))
        .accessibilityLabel("Use \(s.name)")
        .accessibilityIdentifier("review.use")
    }
    .padding(.top, 14)
    .padding(.bottom, 14)
    .padding(.leading, 24)
    .padding(.trailing, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.reviewSuggestionSurface)
    .overlay(alignment: .top) { HColor.borderSubtle.frame(height: 1) }
  }

  /// The bucket's hue from the edge the card leans toward: 170 deep, end 58% at the edge,
  /// start 26% halfway, then clear.
  @ViewBuilder private var glow: some View {
    if let lean, let leanEdge, strength > 0 {
      let hue = lean.pillHue
      let stops = Gradient(stops: [
        .init(color: hue.end.opacity(0.58), location: 0),
        .init(color: hue.start.opacity(0.26), location: 0.5),
        .init(color: hue.start.opacity(0), location: 1),
      ])
      let (from, to, alignment): (UnitPoint, UnitPoint, Alignment) = switch leanEdge {
      case .right: (.trailing, .leading, .trailing)
      case .left: (.leading, .trailing, .leading)
      case .up: (.top, .bottom, .top)
      case .down: (.bottom, .top, .bottom)
      }
      let horizontal = leanEdge == .left || leanEdge == .right
      Rectangle().fill(.linearGradient(stops.colorSpace(.perceptual), startPoint: from, endPoint: to))
        .frame(width: horizontal ? 170 : nil, height: horizontal ? nil : 170)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .opacity(strength)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }

  /// The glow's shadow sits toward the lean (Paper: 18 right, 4 down for Need).
  private var glowShift: CGSize {
    switch leanEdge {
    case .right: CGSize(width: 18, height: 4)
    case .left: CGSize(width: -18, height: 4)
    case .up: CGSize(width: 0, height: -14)
    case .down: CGSize(width: 0, height: 22)
    case nil: .zero
    }
  }

  /// "Lulu Hypermarket, AED 214.30, spent Friday 9 October. New merchant. Looks like
  /// Groceries." (Paper 16 · 06).
  private var spoken: String {
    let amount = hidden
      ? "Amount hidden"
      : (card.isIncome ? "plus " : "") + "\(card.amount.currency) \(MoneyFormat.string(card.amount.minor))"
    var line = "\(card.merchant), \(amount), \(card.spokenWhen)."
    if let copy = card.copyLine {
      line += " \(copy)."
    } else if let r = card.reviewReason {
      line += " \(r.title)."
    }
    if card.isNewMerchant { line += " New merchant." }
    if let raw = card.rawMerchant { line += " Bank text: \(raw)." }
    if card.copyLine == nil, let s = card.suggestion {
      line += " Looks like \(s.name)."
      if card.reviewReason == nil, let by = card.suggestedBy { line += " \(by)." }
    }
    return line
  }
}

extension ReviewCardView where Actions == EmptyView {
  init(card: ReviewCardModel, hidden: Bool, lean: ReviewChoice?, leanEdge: SwipeEdge?, strength: Double,
       use: @escaping () -> Void)
  {
    self.init(card: card, hidden: hidden, lean: lean, leanEdge: leanEdge, strength: strength, use: use,
              actions: { EmptyView() })
  }
}

#if HASALA_MOCKS
  #Preview("Review · Deck") {
    let app = AppModel(store: InMemoryLedger())
    ReviewDeckView(app: app, model: ReviewViewModel(app: app))
  }
#endif
