import HasalaDesign
import HasalaModels
import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

struct ReviewDeckView: View {
  @Bindable var app: AppModel
  let model: any ReviewDeckModel

  @State private var drag: CGSize = .zero
  @State private var crossed: SwipeEdge?
  @State private var held: SwipeEdge?
  @State private var flights: [Flight] = []
  @State private var departures: [String: SwipeEdge] = [:]
  @State private var tap = 0
  @State private var pendingSort: PendingSort?
  @State private var pendingEach: ReviewGroupCardModel?
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

  private var motion: MotionPolicy {
    MotionPolicy(reduceMotion: policy.reduceMotion || systemReduceMotion, settled: policy.settled)
  }

  private var showsDeck: Bool { !model.items.isEmpty || !flights.isEmpty }

  var body: some View {
    let top = model.items.first
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
    .overlay(alignment: .bottom) {
      if !showsDeck || typeSize.isAccessibilitySize { ToastHost(app: app, placement: .bottom) }
    }
    .hHaptic(.impactLight, trigger: tap)
    .sheet(item: pickBinding, onDismiss: pickClosed) { pick in
      ReviewPickSheet(
        model: model, pick: pick,
        sort: { category, alwaysUse, project in sortPicked(pick, into: category, alwaysUse: alwaysUse, project: project) },
        sortEach: {
          pendingEach = pick.group
          model.picking = nil
        })
    }
    .sheet(item: sortEachBinding, onDismiss: sortEachClosed) { group in
      SortEachSheet(app: app, model: model, group: group)
    }
    .onAppear {
      SortSound.shared.prepare()
      if let p = model.picking { holdToward(edge(for: p.choice), animated: false) }
    }
    .onDisappear { SortSound.shared.rest() }
  }

  private var pickBinding: Binding<ReviewPick?> {
    Binding(get: { model.picking }, set: { model.picking = $0 })
  }

  private var sortEachBinding: Binding<ReviewGroupCardModel?> {
    Binding(get: { model.sortingEach }, set: { model.sortingEach = $0 })
  }

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
        if model.waitingForCloud > 0 {
          Text("Waiting for Cloudflare AI (\(model.waitingForCloud))")
            .hType(.caption1)
            .foregroundStyle(HColor.textSecondary)
            .accessibilityIdentifier("review.waitingForCloud")
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
      if let top = model.items.first {
        Button("Skip for now") { skip(top) }
        if case .group(let g) = top {
          Button(ReviewEngine.sortEachLabel) { model.sortingEach = g }
        }
        if BuildSurface.showsUnfinished {
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

  @ViewBuilder
  private func deck(_ top: ReviewItem?) -> some View {
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
          if let row = model.result { resultRow(row).padding(.horizontal, HSpacing.insetPage) }
          footer(top)
        }
        .padding(.top, 20)
        .padding(.bottom, 24)
      }
    } else {
      VStack(spacing: 0) {
        pill(.up).frame(height: Self.pillSlot).padding(.top, 20)
        stack(top)
          .overlay {
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
        if let row = model.result {
          resultRow(row)
            .padding(.horizontal, HSpacing.insetPage)
            .padding(.bottom, 8)
            .opacity(model.picking == nil ? 1 : 0)
        }
        footer(top)
          .padding(.bottom, 2)
          .overlay(alignment: .top) {
            ToastHost(app: app, placement: .bottom)
              .padding(.horizontal, -HSpacing.insetPage)
              .alignmentGuide(.top) { $0[.bottom] + 4 }
          }
      }
    }
  }

  private func resultRow(_ row: SortResultRow) -> some View {
    SortResultRowView(
      row: row, undo: { model.undoResult() }, stopRule: { model.stopResultRule() }, dismiss: { model.dismissResult() })
      .accessibilityAction(named: "Dismiss") { model.dismissResult() }
  }

  private static let peekDepth: CGFloat = 20
  private static let pillSlot: CGFloat = 44

  private func stack(_ top: ReviewItem?) -> some View {
    let count = model.items.count
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
    .frame(maxWidth: Self.cardWidth, minHeight: typeSize.isAccessibilitySize ? Self.cardHeight : 300,
           maxHeight: typeSize.isAccessibilitySize ? .infinity : Self.cardHeight)
    .padding(.bottom, Self.peekDepth)
    .padding(.horizontal, 31)
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

  @ViewBuilder
  private func live(_ item: ReviewItem) -> some View {
    let lean = leanEdge
    switch item {
    case .single(let card):
      ReviewCardView(
        card: card, hidden: model.hidden, lean: lean.map(choice(for:)), leanEdge: lean, strength: leanStrength,
        use: { use(card) },
        merge: { resolveCopy(card, merge: true) },
        keepBoth: { resolveCopy(card, merge: false) },
        reason: { reasonInfo = card },
        notThis: { notThis(item) },
        note: model.notes[item.id],
        undoNote: { model.undoNotThis(item.id) },
        actions: {
          if card.copyLine != nil {
            Button(card.samePurchase ? "Same purchase" : "Merge") { resolveCopy(card, merge: true) }
            Button("Keep both") { resolveCopy(card, merge: false) }
          }
          ForEach(ReviewChoice.allCases, id: \.self) { c in
            Button(c.label) { send(item, c) }
          }
          if card.reviewReason == nil, card.copyLine == nil, let s = card.suggestion, model.notes[item.id] == nil {
            Button("Use \(s.name)") { use(card) }
            Button("Not this") { notThis(item) }
          }
          Button("Skip for now") { skip(item) }
          if card.reviewReason != nil {
            Button("About this alert") { reasonInfo = card }
          }
        }
      )
      .modifier(LiveCard(drag: drag, tilt: tilt, gesture: dragGesture(item), passive: typeSize.isAccessibilitySize || held != nil))
      .accessibilityIdentifier("review.card")
    case .group(let group):
      ReviewGroupCardView(
        group: group, hidden: model.hidden, lean: lean.map(choice(for:)), leanEdge: lean, strength: leanStrength,
        note: model.notes[item.id], useAll: { useGroup(group) }, notThis: { notThis(item) },
        undoNote: { model.undoNotThis(item.id) },
        actions: {
          if let s = group.suggestion, model.notes[item.id] == nil {
            Button(group.useAllSpoken(s.name)) { useGroup(group) }
            Button("Not this") { notThis(item) }
          }
          Button(ReviewEngine.sortEachLabel) { model.sortingEach = group }
          ForEach(ReviewChoice.allCases, id: \.self) { c in
            Button(c.label) { send(item, c) }
          }
          Button("Skip for now") { skip(item) }
        }
      )
      .modifier(LiveCard(drag: drag, tilt: tilt, gesture: dragGesture(item), passive: typeSize.isAccessibilitySize || held != nil))
      .accessibilityIdentifier("review.card")
    }
  }

  private var tilt: Double {
    if motion.isStill { return 0 }
    switch held {
    case .right: return HMotion.commitTilt
    case .left: return -HMotion.commitTilt
    case .up, .down: return 0
    case nil: return SwipePhysics.tilt(dx: drag.width, atCommit: HMotion.commitTilt)
    }
  }

  private var leanEdge: SwipeEdge? {
    if let held { return held }
    guard drag != .zero else { return nil }
    return SwipePhysics.preview(dx: drag.width, dy: drag.height)
  }

  private var leanStrength: Double {
    held != nil ? 1 : SwipePhysics.strength(dx: drag.width, dy: drag.height)
  }

  private func arrival(for id: String) -> AnyTransition {
    if motion.settled { return .identity }
    if motion.reduceMotion { return .asymmetric(insertion: .opacity, removal: .identity) }
    if let edge = departures[id] {
      let far = Flight.target(edge, width: Self.cardWidth, height: Self.cardHeight)
      return .asymmetric(insertion: .offset(far).combined(with: .opacity), removal: .identity)
    }
    return .asymmetric(insertion: motion.transition(.cardNext), removal: .identity)
  }

  private func choice(for edge: SwipeEdge) -> ReviewChoice {
    SwipePhysics.choice(for: edge, needOnRight: model.needOnRight)
  }

  private func edge(for choice: ReviewChoice) -> SwipeEdge {
    SwipePhysics.edge(for: choice, needOnRight: model.needOnRight)
  }

  private func pill(_ edge: SwipeEdge) -> some View {
    let choice = choice(for: edge)
    let active = crossed == edge || held == edge
    let waking = !active && leanEdge == edge ? leanStrength : 0
    return Button {
      if let top = model.items.first { send(top, choice) }
    } label: {
      DirectionPillLabel(choice: choice, edge: edge, active: active)
    }
    .buttonStyle(HPressStyle(in: Capsule()))
    .scaleEffect(motion.isStill ? 1 : 1 + 0.06 * waking)
    .hAnimation(.thumbSlide, value: active)
    .opacity(model.picking == nil ? 1 : 0)
    .hAnimation(.fade, value: model.picking == nil)
    .disabled(model.items.isEmpty)
    .accessibilityLabel("Sort as \(choice.label)")
    .accessibilityIdentifier("review.pill.\(choice.rawValue)")
  }

  private func footer(_ top: ReviewItem?) -> some View {
    HStack(spacing: 0) {
      if case .group(let g)? = top {
        footerLink(ReviewEngine.sortEachLabel, id: "review.sortEach") { model.sortingEach = g }
        HColor.borderSubtle.frame(width: 1, height: 20)
      }
      footerLink("Skip for now", id: "review.skip") {
        if let top { skip(top) }
      }
      if BuildSurface.showsUnfinished, case .single? = top {
        HColor.borderSubtle.frame(width: 1, height: 20)
        Button {
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

  private func dragGesture(_ item: ReviewItem) -> some Gesture {
    DragGesture(minimumDistance: 6)
      .onChanged { value in
        drag = value.translation
        let past = SwipePhysics.pastCommit(dx: drag.width, dy: drag.height)
        if past != crossed {
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
          return
        }
        if crossed != edge { tap += 1 }
        crossed = nil
        holdToward(edge, animated: true)
        ask(item, choice(for: edge))
      }
  }

  private func ask(_ item: ReviewItem, _ choice: ReviewChoice) {
    switch item {
    case .single(let c): model.pick(c.id, choice)
    case .group(let g): model.pickGroup(g, choice)
    }
  }

  private func send(_ item: ReviewItem, _ choice: ReviewChoice) {
    tap += 1
    holdToward(edge(for: choice), animated: true)
    ask(item, choice)
  }

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

  private func sortPicked(_ pick: ReviewPick, into category: CategoryID, alwaysUse: Bool, project: ProjectID?) {
    pendingSort = PendingSort(pick: pick, category: category, alwaysUse: alwaysUse, project: project)
    model.picking = nil
  }

  private func pickClosed() {
    if let p = pendingSort {
      pendingSort = nil
      let edge = held ?? edge(for: p.pick.choice)
      if let group = p.pick.group {
        let name = app.store.state.category(p.category)?.name ?? p.pick.choice.label
        file(.group(group), toward: edge, announce: { model.groupFiledAnnouncement(group, as: name) }, chime: true) {
          model.sortGroup(group, into: p.category, alwaysUse: p.alwaysUse, project: p.project)
        }
      } else {
        file(.single(p.pick.card), toward: edge, as: p.pick.choice.label, chime: true) {
          model.sort(p.pick.card.id, into: p.category, alwaysUse: p.alwaysUse, project: p.project)
        }
      }
      return
    }
    if let group = pendingEach {
      pendingEach = nil
      settle()
      model.sortingEach = group
      return
    }
    settle()
  }

  private func settle() {
    guard held != nil else { return }
    withAnimation(motion.animation(.cardReturn)) {
      drag = .zero
      held = nil
    }
  }

  private func sortEachClosed() {
    settle()
  }

  private func use(_ card: ReviewCardModel) {
    guard card.reviewReason == nil, let s = card.suggestion else { return }
    tap += 1
    file(.single(card), toward: edge(for: ReviewChoice(filing: s.bucket)), as: s.name, chime: true) {
      model.useSuggestion(card.id)
    }
  }

  private func useGroup(_ group: ReviewGroupCardModel) {
    guard let s = group.suggestion else { return }
    tap += 1
    file(.group(group), toward: edge(for: ReviewChoice(filing: s.bucket)), announce: { model.groupFiledAnnouncement(group, as: s.name) },
         chime: true) {
      model.useGroup(group)
    }
  }

  private func notThis(_ item: ReviewItem) {
    tap += 1
    guard model.notThis(item), let line = model.notes[item.id]?.line else { return }
    announce(line)
  }

  private func resolveCopy(_ card: ReviewCardModel, merge: Bool) {
    tap += 1
    if card.samePurchase {
      file(.single(card), toward: nil, as: merge ? "Same purchase" : "Kept both") {
        model.resolveSamePurchase(card.id, same: merge)
      }
      return
    }
    file(.single(card), toward: nil, as: merge ? "Merged" : "Kept both") {
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
    file(.single(card), toward: nil, as: nil) { model.archive(card.id) }
  }

  private func skip(_ item: ReviewItem) {
    file(item, toward: nil, as: nil) {
      model.skipItem(item)
      return true
    }
  }

  private func file(
    _ item: ReviewItem, toward edge: SwipeEdge?, as filedAs: String?, chime: Bool = false, _ edit: () -> Bool
  ) {
    file(item, toward: edge, announce: filedAs.map { label in { model.filedAnnouncement(label) } }, chime: chime, edit)
  }

  private func file(
    _ item: ReviewItem, toward edge: SwipeEdge?, announce line: (() -> String)?, chime: Bool = false, _ edit: () -> Bool
  ) {
    let from = drag
    let tilt = tilt
    var done = false
    withAnimation(motion.animation(.cardNext)) {
      done = edit()
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
    if let edge { departures[item.id] = edge }
    if !motion.settled {
      flights.append(Flight(item: item, from: from, tilt: tilt, edge: edge))
    }
    if let line { announce(line()) }
  }

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
      .accessibilityElement(children: .contain)
  }
}

struct Flight: Identifiable {
  let id = UUID()
  let item: ReviewItem
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
    Group {
      switch flight.item {
      case .single(let card): ReviewCardView(card: card, hidden: hidden, lean: nil, leanEdge: nil, strength: 0, use: {})
      case .group(let group): ReviewGroupCardView(group: group, hidden: hidden)
      }
    }
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
  var notThis: (() -> Void)? = nil
  var note: RejectedNote? = nil
  var undoNote: () -> Void = {}
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
      } else if let note {
        ReviewNoteStrip(note: note, undo: undoNote)
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
      let buttons = typeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
        : AnyLayout(HStackLayout(spacing: 10))
      buttons {
        if let notThis {
          Button("Not this", action: notThis)
            .buttonStyle(.pill(.secondary, size: .small))
            .accessibilityIdentifier("review.strip.notThis")
        }
        Button("Use", action: use)
          .buttonStyle(.pill(.primary, size: .small))
          .accessibilityLabel("Use \(s.name)")
          .accessibilityIdentifier("review.use")
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
