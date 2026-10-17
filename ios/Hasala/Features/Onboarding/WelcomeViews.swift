import HasalaDesign
import HasalaModels
import SwiftUI
import UIKit

// The welcome stories (Paper row 10: Welcome · Story 1–4 of 4, the "Who can see what"
// sheet, and Welcome · Motion and haptics; spec 04) and Welcome · Join with an invite, or
// sign in (Paper E2X-0; spec 07 S1). Privacy-first: every claim is one the design makes and
// the privacy policy backs.

// MARK: - The stories

struct Story: Identifiable {
  let id: Int
  let kicker: String
  /// The headline's lines; story 1's second line is in blue 700.
  let headline: [String]
  let accentSecondLine: Bool
  let body: String
  /// Story 3 links to "Who can see what".
  let whoSees: Bool
}

enum Stories {
  static let all: [Story] = [
    Story(id: 0, kicker: "Welcome to Hasala", headline: ["Know what's left.", "Keep it to yourself."],
          accentSecondLine: true,
          body: "A budget from your bank alert emails, worked out on your iPhone. Rent counts on the day it's due, so paying it doesn't put you behind.",
          whoSees: false),
    Story(id: 1, kicker: "On your iPhone", headline: ["Your bank emails do the typing."], accentSecondLine: false,
          body: "Hasala reads the alerts your bank already sends, right here on your iPhone, and turns them into a live budget. No bank logins.",
          whoSees: false),
    Story(id: 2, kicker: "Private by design", headline: ["Your phone", "holds the key."], accentSecondLine: false,
          body: "Anything that leaves your iPhone is end-to-end encrypted first. Our server keeps a sealed copy it can't open.",
          whoSees: true),
    Story(id: 3, kicker: "Review", headline: ["Sort a week in a minute."], accentSecondLine: false,
          body: "Swipe new transactions into Needs, Wants or Savings. Hasala learns each merchant on your iPhone and sorts it for you next time.",
          whoSees: false),
  ]
}

/// The pager's position as it moves, in pages (1.5 is halfway from story 2 to story 3).
/// Only the orbit reads it, so a drag redraws the orbit, not the screen.
@MainActor
@Observable
final class StoryPagerMotion {
  var position: Double

  init(position: Double) {
    self.position = position
  }
}

/// The four welcome stories as one pager under a fixed Start panel (spec 04 §2): the
/// story progress, the Hasala header, the stage and the copy page; "Get started" and "I
/// already have an account" never move.
///
/// Motion (spec 04 §3, the owner's "delight" allowance): the art moves at 1.25× the finger
/// and the copy at 1×; the orbit turns 20° per page; each story deals its cards in when it
/// becomes the current one, then plays its key moment. A swipe or tap that changes the story
/// plays a selection haptic as it settles; the timer never buzzes. Each story plays 6 s,
/// then the pager moves on, and stops after story 4. It pauses while the person drags, under
/// the "Who can see what" sheet, under a pushed screen, in the background, and while
/// VoiceOver runs (no auto-advance; the progress reads "Page n of 4"). At the accessibility
/// text sizes it doesn't auto-advance either: a story's copy then fills the screen and takes
/// longer than 6 s to read, so the words would change mid-read. Reduce Motion: pages
/// cross-fade, nothing turns or counts, the cards stop floating; the haptics stay.
///
/// The page is the onboarding store's, so it is where the person left it.
struct StoriesView: View {
  @Binding var page: Int
  @Binding var whoSeesOpen: Bool
  /// Outlook can be connected in this build (the sheet names Microsoft only then).
  var outlook: Bool
  var onGetStarted: () -> Void
  var onSignIn: () -> Void

  init(
    page: Binding<Int>, whoSeesOpen: Binding<Bool>, outlook: Bool, onGetStarted: @escaping () -> Void,
    onSignIn: @escaping () -> Void
  ) {
    _page = page
    _whoSeesOpen = whoSeesOpen
    self.outlook = outlook
    self.onGetStarted = onGetStarted
    self.onSignIn = onSignIn
    let start = min(max(page.wrappedValue, 0), Stories.all.count - 1)
    _position = State(initialValue: ScrollPosition(id: start))
    _pager = State(initialValue: StoryPagerMotion(position: Double(start)))
  }

  @State private var position: ScrollPosition
  @State private var pager: StoryPagerMotion
  @State private var clock = StoryClock()
  /// Each story's current run of its choreography; nil until it deals in again.
  @State private var runs: [StoryRun?] = Array(repeating: nil, count: Stories.all.count)
  @State private var runCount = 0
  @State private var copyHeights: [CGFloat] = Array(repeating: 0, count: Stories.all.count)
  /// The person's finger is on the pager, or it is still coasting from a swipe.
  @State private var dragging = false
  @State private var onScreen = false
  /// The pager has been put on the store's page.
  @State private var placed = false
  @State private var copyIn = false
  /// The Reduce Motion cross-fade between stories.
  @State private var fading = false
  /// Plays the selection haptic each time a change the person made settles.
  @State private var settles = 0

  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
  @Environment(\.dynamicTypeSize) private var typeSize
  @StageMotion private var motion: MotionPolicy

  private var count: Int { Stories.all.count }

  /// Someone can see the stories: not under a pushed screen or the sheet, not in the
  /// background.
  private var visible: Bool { onScreen && !whoSeesOpen && scenePhase == .active }

  /// Reading a story takes longer than it plays (VoiceOver, the accessibility text sizes):
  /// the person moves on, and the progress marks where they are.
  private var handPaced: Bool { voiceOver || typeSize.isAccessibilitySize }

  /// The clock runs only while someone can watch the story, and never when it is hand-paced.
  private var shouldRun: Bool { visible && !handPaced && !dragging }

  var body: some View {
    Group {
      if typeSize.isAccessibilitySize {
        largeTextLayout
      } else {
        GeometryReader { geo in
          VStack(spacing: 0) {
            progress
            header
            pagerArea
            startPanel(bottom: max(30, geo.safeAreaInsets.bottom - 4))
          }
        }
        .ignoresSafeArea(.container, edges: .bottom)
      }
    }
    .background { StoryBackground().ignoresSafeArea() }
    .toolbar(.hidden, for: .navigationBar)
    .sheet(isPresented: $whoSeesOpen) { WhoCanSeeSheet(outlook: outlook) }
    .hHaptic(.selection, trigger: settles)
    .onAppear(perform: appeared)
    .onDisappear { onScreen = false }
    .onChange(of: shouldRun) { _, run in
      if run { clock.resume(at: .now) } else { clock.pause(at: .now) }
    }
    .task(id: AdvanceKey(page: page, running: clock.isRunning)) { await advanceWhenDone() }
    // The other layout's pager opens on the first story: put it on this one.
    .onChange(of: typeSize.isAccessibilitySize) { placed = false }
  }

  /// At the accessibility text sizes the copy needs the screen (spec 04 §11, plan 0.1 rule
  /// 11): the drawings go, and the whole screen scrolls, the pager as tall as the longest
  /// story and the Start panel under it, so nothing is cut off at the bottom.
  private var largeTextLayout: some View {
    ScrollView(.vertical) {
      VStack(spacing: 0) {
        progress
        header
        paged(
          ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 0) {
              ForEach(Stories.all) { story in
                StoryCopy(story: story, shown: copyIn, still: motion.isStill) { whoSeesOpen = true }
                  .fixedSize(horizontal: false, vertical: true)
                  .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { copyHeights[story.id] = $0 }
                  .frame(maxHeight: .infinity, alignment: .top)
                  .containerRelativeFrame(.horizontal)
                  .id(story.id)
              }
            }
            .scrollTargetLayout()
          }
        )
        .frame(height: max(1, copyHeights.max() ?? 0))
        .padding(.top, 16)
        startPanel(bottom: 30)
      }
    }
    .scrollBounceBehavior(.basedOnSize)
    .scrollIndicators(.hidden)
  }

  // MARK: Chrome

  /// Four segments, the current one filling as it plays (spec 04 §2.3). VoiceOver reads
  /// "Page n of 4" and swipes up or down to change the story; the element is a 44 band
  /// around the 3 pt bars, so it is a size people can reach, without moving the header.
  private var progress: some View {
    TimelineView(.animation(minimumInterval: nil, paused: !clock.isRunning)) { context in
      StoryProgress(count: count, current: page, fill: handPaced ? 1 : clock.progress(at: context.date))
    }
    .frame(height: 3)
    .padding(.top, 4)
    .padding(.horizontal, 16)
    .frame(minHeight: 7)
    .accessibilityHidden(true)
    .overlay {
      Color.clear
        .frame(height: 44)
        .contentShape(Rectangle())
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Page \(page + 1) of \(count)")
        .accessibilityAdjustableAction { direction in
          switch direction {
          case .increment: go(to: page + 1, byUser: true)
          case .decrement: go(to: page - 1, byUser: true)
          @unknown default: break
          }
        }
        .accessibilityIdentifier("stories.progress")
    }
  }

  /// "Hasala · Welcome" with the app icon (spec 04 §2.4).
  private var header: some View {
    HStack(spacing: 10) {
      AppIconTile(size: 32, radius: 8)
        .shadow(color: HColor.blue950.opacity(0.14), radius: 5, y: 4)
        .shadow(color: HColor.blue950.opacity(0.18), radius: 1, y: 1)
      Text("Hasala")
        .hType(.subheadline.weight(.semibold))
        .foregroundStyle(HColor.textPrimary)
      Text("Welcome")
        .hType(.subheadline)
        .foregroundStyle(HColor.textOnWashSecondary)
      Spacer(minLength: 0)
    }
    .frame(minHeight: 36)
    .padding(.top, 12)
    .padding(.horizontal, 16)
    .accessibilityElement(children: .combine)
  }

  /// The two buttons and the trust line, fixed under the pager (Paper "Start panel").
  private func startPanel(bottom: CGFloat) -> some View {
    VStack(spacing: 12) {
      Button("Get started", action: onGetStarted)
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("stories.getStarted")
      Button(action: onSignIn) {
        // Paper sets this label in text-primary, not the link blue of "On grouped".
        Text("I already have an account").foregroundStyle(HColor.textPrimary)
      }
      .buttonStyle(.pill(.onGrouped, fill: true))
      .accessibilityIdentifier("stories.signIn")
      HStack(spacing: 6) {
        HIconView(.lock, size: 14, color: HColor.textOnWashSecondary, strokeWidth: 2)
        Text("Read-only email · End-to-end encrypted")
          .hType(.footnote.weight(.medium))
          .foregroundStyle(HColor.textOnWashSecondary)
      }
      .padding(.top, 4)
      .multilineTextAlignment(.center)
      .accessibilityElement(children: .combine)
    }
    .padding(.horizontal, HSpacing.insetPage)
    .padding(.bottom, bottom)
  }

  // MARK: Pager

  private var pagerArea: some View {
    GeometryReader { area in
      let metrics = (0..<count).map { stageMetrics($0, in: area.size) }
      ZStack(alignment: .top) {
        SharedOrbit(pager: pager, metrics: metrics, clock: clock, still: motion.isStill)
        paged(
          ScrollView(.horizontal) {
            HStack(spacing: 0) {
              ForEach(Stories.all) { story in
                storyPage(story, metrics: metrics[story.id], width: area.size.width)
                  .containerRelativeFrame(.horizontal)
                  .id(story.id)
              }
            }
            .scrollTargetLayout()
          }
        )
      }
    }
  }

  /// The pager's paging, its place, and what its scrolling tells the stories.
  private func paged(_ scroller: some View) -> some View {
    scroller
      .scrollTargetBehavior(.paging)
      .scrollPosition($position)
      // A scroll position's first id isn't applied while the pages have no width yet, so
      // the pager goes to the store's page once they are laid out.
      .onScrollGeometryChange(for: Bool.self) { g in
        g.containerSize.width > 0 && g.contentSize.width > g.containerSize.width
      } action: { _, laidOut in
        guard laidOut, !placed else { return }
        placed = true
        guard page != 0 else { return }
        Task { @MainActor in
          var t = Transaction()
          t.disablesAnimations = true
          withTransaction(t) { position.scrollTo(id: page) }
        }
      }
      .scrollIndicators(.hidden)
      .onScrollGeometryChange(for: Double.self) { g in
        Double(g.contentOffset.x / max(1, g.containerSize.width))
      } action: { _, x in
        pager.position = x
      }
      .onScrollPhaseChange { _, phase in scrollPhaseChanged(phase) }
      .opacity(fading ? 0 : 1)
      .accessibilityIdentifier("stories.pager")
  }

  private func storyPage(_ story: Story, metrics: StageMetrics, width: CGFloat) -> some View {
    ScrollView(.vertical) {
      VStack(spacing: 0) {
        if metrics.shown {
          stage(story, metrics: metrics, width: width)
        }
        StoryCopy(story: story, shown: copyIn, still: motion.isStill) { whoSeesOpen = true }
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { copyHeights[story.id] = $0 }
      }
    }
    .scrollBounceBehavior(.basedOnSize)
    .scrollIndicators(.hidden)
  }

  /// The story's drawing, scaled to the room the copy leaves, moving at 1.25× the drag.
  /// A tap on its leading third goes back a story, anywhere else goes on.
  private func stage(_ story: Story, metrics: StageMetrics, width: CGFloat) -> some View {
    let still = motion.isStill
    return StoryArt(
      index: story.id, run: runs[story.id],
      // Only while someone can see it: under a pushed screen or the sheet nothing moves.
      floating: !still && visible && story.id == page && runs[story.id] != nil)
      .scaleEffect(metrics.scale, anchor: .top)
      .frame(width: width, height: metrics.height, alignment: .top)
      .visualEffect { content, proxy in
        content.offset(x: still ? 0 : proxy.frame(in: .scrollView(axis: .horizontal)).minX * 0.25)
      }
      .contentShape(Rectangle())
      .onTapGesture { location in
        go(to: location.x < width / 3 ? page - 1 : page + 1, byUser: true)
      }
  }

  /// How much room a story's drawing has once its copy is laid out, and how far it scales
  /// to fit. At the largest text sizes the copy needs the screen: the drawing goes and the
  /// page scrolls.
  private func stageMetrics(_ index: Int, in size: CGSize) -> StageMetrics {
    let room = max(0, size.height - copyHeights[index])
    let scale = min(1, size.width / 402, room / StoryArt.heights[index])
    let shown = room >= 150 && scale >= 0.45
    return StageMetrics(height: shown ? room : 0, scale: shown ? scale : 0, shown: shown)
  }

  // MARK: Moving between stories

  private func appeared() {
    onScreen = true
    guard runs.allSatisfy({ $0 == nil }) else { return }
    // First appearance: the current story deals in and its copy rises 12 at +160 ms.
    start(page, byUser: false)
    resetOthers(except: page)
    if motion.isStill {
      withAnimation(motion.settled ? nil : HMotion.reduceMotionCurve.animation) { copyIn = true }
    } else {
      withAnimation(HMotion.easeOutSoft(HMotion.rise).delay(0.16)) { copyIn = true }
    }
  }

  /// The pager's scroll phase: a drag pauses the story; when the page comes to rest on
  /// another story, that story starts and the selection haptic plays.
  private func scrollPhaseChanged(_ phase: ScrollPhase) {
    switch phase {
    case .tracking, .interacting, .decelerating:
      dragging = true
    case .animating:
      break
    case .idle:
      dragging = false
      let landed = min(max(Int(pager.position.rounded()), 0), count - 1)
      if landed != page {
        start(landed, byUser: true)
        resetOthers(except: landed)
        settles += 1
      }
    @unknown default:
      dragging = false
    }
  }

  /// A tap, the adjustable action or the timer moves to `target`.
  private func go(to target: Int, byUser: Bool) {
    guard (0..<count).contains(target), target != page else { return }
    let m = motion
    if m.settled {
      position.scrollTo(id: target)
      start(target, byUser: byUser)
      resetOthers(except: target)
      if byUser { settles += 1 }
      return
    }
    if m.reduceMotion {
      // Reduce Motion: no slide; the stories cross-fade.
      withAnimation(HMotion.easeOutSoft(HMotion.reduceMotionFade / 2)) {
        fading = true
      } completion: {
        position.scrollTo(id: target)
        pager.position = Double(target)
        start(target, byUser: byUser)
        resetOthers(except: target)
        withAnimation(HMotion.easeOutSoft(HMotion.reduceMotionFade)) {
          fading = false
        } completion: {
          if byUser { settles += 1 }
        }
      }
      return
    }
    // The new story deals in as it slides in; the old one clears once it is off screen.
    start(target, byUser: byUser)
    withAnimation(HMotion.snappy) {
      position.scrollTo(id: target)
    } completion: {
      resetOthers(except: target)
      if byUser { settles += 1 }
    }
  }

  /// `index` becomes the current story: its clock starts from nothing and its cards deal in.
  private func start(_ index: Int, byUser: Bool) {
    page = index
    clock.restart(at: .now, running: shouldRun)
    runCount += 1
    runs[index] = StoryRun(id: runCount, byUser: byUser)
  }

  /// Stories off screen go back to their start, so they deal in again next time.
  private func resetOthers(except index: Int) {
    for i in 0..<count where i != index { runs[i] = nil }
  }

  /// When the playing story ends, the pager moves on (no haptic: the person didn't do it).
  /// After story 4 it stops, full.
  private func advanceWhenDone() async {
    guard clock.isRunning else { return }
    try? await Task.sleep(for: .seconds(clock.remaining(at: .now)))
    guard !Task.isCancelled, clock.isRunning else { return }
    if page < count - 1 {
      go(to: page + 1, byUser: false)
    } else {
      clock.finish()
    }
  }

  private struct AdvanceKey: Equatable {
    let page: Int
    let running: Bool
  }
}

/// How a story's drawing fits its page.
struct StageMetrics: Equatable {
  var height: CGFloat
  var scale: CGFloat
  var shown: Bool
}

/// The orbit behind the pager (spec 04 §2.5): it doesn't page. It turns 20° per page as the
/// pager moves, follows story 4's lower stage, and its dot travels the ring once per story,
/// with the progress bar. Still with Reduce Motion.
private struct SharedOrbit: View {
  let pager: StoryPagerMotion
  let metrics: [StageMetrics]
  let clock: StoryClock
  let still: Bool

  var body: some View {
    let x = min(max(pager.position, 0), Double(metrics.count - 1))
    let i0 = Int(x.rounded(.down))
    let i1 = min(i0 + 1, metrics.count - 1)
    let f = x - Double(i0)
    let scale = lerp(metrics[i0].scale, metrics[i1].scale, f)
    let top = lerp(StoryArt.orbitTop[i0], StoryArt.orbitTop[i1], f)
    let shown = lerp(metrics[i0].shown ? 1 : 0, metrics[i1].shown ? 1 : 0, f)
    ZStack(alignment: .topLeading) {
      OrbitGlow().offset(x: 41, y: top + 6)
      TimelineView(.animation(minimumInterval: nil, paused: still || !clock.isRunning)) { context in
        OrbitRings(turn: still ? 0 : x * 20, dot: still ? 0 : clock.progress(at: context.date) * 360)
      }
      .offset(y: top)
    }
    .frame(width: 402, height: 420, alignment: .topLeading)
    .scaleEffect(max(scale, 0.01), anchor: .top)
    .opacity(shown)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
}

/// A story's words (Paper "Story copy"): kicker, headline, body, and on story 3 the link
/// to "Who can see what". They rise 12 into place once, on the first appearance; after that
/// they arrive with their page.
private struct StoryCopy: View {
  let story: Story
  let shown: Bool
  let still: Bool
  let onWhoSees: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(story.kicker)
        .hType(.overline)
        .foregroundStyle(HColor.hueSkyInk)
      headline
        .hType(.largeTitle)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
      Text(story.body)
        .hType(.body)
        .foregroundStyle(HColor.textOnWashSecondary)
        .fixedSize(horizontal: false, vertical: true)
      if story.whoSees {
        Button(action: onWhoSees) {
          HStack(spacing: 4) {
            Text("Who can see what")
              .hType(.subheadline.weight(.semibold))
            HIconView(.chevronRight, size: 16, color: HColor.textOnWashLink, strokeWidth: 2.4)
          }
          .foregroundStyle(HColor.textOnWashLink)
          .frame(minHeight: 44)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Paper's link row is 28 tall; the target keeps 44 without moving what follows.
        .padding(.vertical, -8)
        .accessibilityIdentifier("stories.whoSees")
      }
    }
    .padding(.horizontal, 24)
    .padding(.bottom, 24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .offset(y: shown || still ? 0 : HMotion.travelRise)
    .opacity(shown ? 1 : 0)
  }

  private var headline: Text {
    let lines = story.headline
    let first = Text(lines[0]).foregroundStyle(HColor.textPrimary)
    guard lines.count > 1 else { return first }
    let second = Text(lines[1]).foregroundStyle(story.accentSecondLine ? HColor.blue700 : HColor.textPrimary)
    return Text("\(first)\n\(second)")
  }
}

// MARK: - Join with an invite, or sign in

/// Welcome · Join with an invite, or sign in (Paper E2X-0; spec 07 S1): the coin going into
/// the slot, the beta's promise, and the account panel. Invites are the only way in during
/// the beta, so there is one join button. "Get started" on the stories lands here.
struct JoinWelcomeView: View {
  var onJoin: () -> Void
  var onSignIn: () -> Void
  var onBack: (() -> Void)?

  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        hero
        VStack(alignment: .leading, spacing: 8) {
          Text("Private beta · by invite")
            .hType(.overline)
            .foregroundStyle(HColor.hueSkyInk)
          Text("Know what's left. Keep it to yourself.")
            .hType(.largeTitle)
            .foregroundStyle(HColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
          Text("Your budget is built and kept on this iPhone, and sealed before anything leaves it.")
            .hType(.body)
            .foregroundStyle(HColor.textOnWashSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        // At the accessibility sizes the buttons wrap: they scroll with the page rather
        // than fill a fixed dock.
        if typeSize.isAccessibilitySize { panel.padding(.bottom, 30) }
      }
      // The hero sits under the status bar, as Paper draws it; the back button floats over
      // its corner.
      .padding(.top, Self.statusBarHeight)
    }
    .ignoresSafeArea(.container, edges: .top)
    .scrollEdgeEffectHidden(true, for: .top)
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaBar(edge: .bottom) {
      if !typeSize.isAccessibilitySize { panel }
    }
    .background(alignment: .top) {
      AmbientWash(.welcome).ignoresSafeArea(edges: .top)
    }
    .background(HColor.surfaceSecondary)
    // Back is the system's, with its swipe (plan decision 7); `onBack` says whether there is one.
    .accountHeader(back: onBack == nil ? .none : .system)
  }

  /// The window's status bar (62 on the iPhone 17 class): the hero starts under it.
  static var statusBarHeight: CGFloat {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    return scene?.keyWindow?.safeAreaInsets.top ?? 62
  }

  /// Paper "Hero · Coin into the slot": 330 tall, the mark and the wordmark centred in a
  /// soft white glow.
  private var hero: some View {
    ZStack {
      Circle()
        .fill(.radialGradient(
          Gradient(stops: [
            .init(color: Color.white.opacity(0.9), location: 0),
            .init(color: Color.white.opacity(0.35), location: 0.45 / 0.7),
            .init(color: Color.white.opacity(0), location: 1),
          ]).colorSpace(.perceptual),
          center: .center, startRadius: 0, endRadius: 140 * 2.squareRoot() * 0.7))
        .frame(width: 280, height: 280)
        .offset(y: 25 + 140 - 165)
      VStack(spacing: 0) {
        SlotMark(plate: .onWash)
          .frame(width: 216, height: 129)
        Text("Hasala")
          .font(.custom(HWeight.bold.interFace, size: 28, relativeTo: .title))
          .tracking(-0.84)
          .foregroundStyle(HColor.textPrimary)
          .padding(.top, 18)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: 330)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Hasala")
  }

  private var panel: some View {
    VStack(spacing: 12) {
      Button("Join with an invite", action: onJoin)
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("welcome.join")
      Button(action: onSignIn) {
        Text("Sign in").foregroundStyle(HColor.textPrimary)
      }
      .buttonStyle(.pill(.onGrouped, fill: true))
      .accessibilityIdentifier("welcome.signIn")
      VStack(spacing: 2) {
        Link(destination: URL(string: "https://hasala.app")!) {
          Text("No invite yet? Join the waitlist")
            .hType(.subheadline.weight(.semibold))
            .foregroundStyle(HColor.textOnWashLink)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .padding(.vertical, -4)
        .accessibilityIdentifier("welcome.waitlist")
        // Plain text as Paper draws it. Two links inside a footnote are too small to tap,
        // so the whole line is one target that offers both pages.
        Menu {
          Link("Terms", destination: URL(string: "https://hasala.app/terms")!)
          Link("Privacy Policy", destination: URL(string: "https://hasala.app/privacy")!)
        } label: {
          Text("By continuing you agree to the Terms and Privacy Policy.")
            .hType(.footnote)
            .foregroundStyle(HColor.textOnWashSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .top)
            .contentShape(Rectangle())
        }
        // The 44 target reaches down into the panel's bottom margin, not up into the
        // waitlist link, so the line sits where Paper puts it.
        .padding(.bottom, -24)
        .accessibilityHint("Opens the Terms or the Privacy Policy.")
        .accessibilityIdentifier("welcome.legal")
      }
    }
    .padding(.horizontal, HSpacing.insetPage)
    .padding(.top, 8)
  }
}
