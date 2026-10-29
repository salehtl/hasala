import HasalaDesign
import HasalaModels
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// The welcome stories (Paper row 10: Welcome · Story 1–4 of 4, the "Who can see what"
// sheet, and Welcome · Motion and haptics; spec 04). Privacy-first: every claim is one the
// design makes and the privacy policy backs.

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
          body: "Your money data is end-to-end encrypted before it leaves your iPhone. Our server keeps a sealed copy it can't open.",
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
  var onPasteInvite: (String) -> Void
  var onSignIn: () -> Void

  init(
    page: Binding<Int>, whoSeesOpen: Binding<Bool>, outlook: Bool, onGetStarted: @escaping () -> Void,
    onPasteInvite: @escaping (String) -> Void, onSignIn: @escaping () -> Void
  ) {
    _page = page
    _whoSeesOpen = whoSeesOpen
    self.outlook = outlook
    self.onGetStarted = onGetStarted
    self.onPasteInvite = onPasteInvite
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
  @State private var linkCopied = false
  @State private var pasteboardChecks = 0

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
    .onAppear { appeared() }
    .task(id: pasteboardChecks) { await lookForCopiedLink() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { pasteboardChecks += 1 }
    }
    .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
      pasteboardChecks += 1
    }
    .onDisappear {
      onScreen = false
      clock.pause(at: .now)
    }
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
      if !typeSize.isAccessibilitySize {
        Text("Welcome")
          .hType(.subheadline)
          .foregroundStyle(HColor.textOnWashSecondary)
      }
      Spacer(minLength: 0)
    }
    .frame(minHeight: 36)
    .padding(.top, 12)
    .padding(.horizontal, 16)
    .accessibilityElement(children: .combine)
  }

  /// The two buttons and the terms line, fixed under the pager (Paper "Start panel").
  private func startPanel(bottom: CGFloat) -> some View {
    VStack(spacing: 12) {
      if linkCopied {
        CopiedInviteCard(stacked: typeSize.isAccessibilitySize, onPaste: onPasteInvite)
          .hTransition(.fade)
      }
      Button("Get started", action: onGetStarted)
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("stories.getStarted")
      Button(action: onSignIn) {
        // Paper sets this label in text-primary, not the link blue of "On grouped".
        Text("I already have an account").foregroundStyle(HColor.textPrimary)
      }
      .buttonStyle(.pill(.onGrouped, fill: true))
      .accessibilityIdentifier("stories.signIn")
      Menu {
        Link("Terms", destination: URL(string: "https://hasala.app/terms")!)
        Link("Privacy Policy", destination: URL(string: "https://hasala.app/privacy")!)
      } label: {
        HStack(spacing: 6) {
          HIconView(.lock, size: 14, color: HColor.textOnWashSecondary, strokeWidth: 2)
          Text("You agree to the Terms and Privacy Policy.")
            .hType(.footnote.weight(.medium))
            .foregroundStyle(HColor.textOnWashSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
      }
      .padding(.vertical, -10)
      .accessibilityHint("Opens the Terms or the Privacy Policy.")
      .accessibilityIdentifier("stories.legal")
    }
    .hAnimation(.fade, value: linkCopied)
    .padding(.horizontal, HSpacing.insetPage)
    .padding(.bottom, bottom)
  }

  private func lookForCopiedLink() async {
    let pasteboard = UIPasteboard.general
    guard pasteboard.hasStrings || pasteboard.hasURLs else {
      linkCopied = false
      return
    }
    let found = await Self.webURLCopied(pasteboard)
    guard !Task.isCancelled else { return }
    linkCopied = found
  }

  private nonisolated static func webURLCopied(_ pasteboard: UIPasteboard) async -> Bool {
    let found = try? await pasteboard.detectedPatterns(for: [\.probableWebURL])
    return found?.contains(\.probableWebURL) == true
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
          instantly { position.scrollTo(id: page) }
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
    guard runs.allSatisfy({ $0 == nil }) else {
      if shouldRun { clock.resume(at: .now) }
      return
    }
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
    guard !Task.isCancelled, clock.isRunning, shouldRun else { return }
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

private struct WidePasteButton: UIViewRepresentable {
  var identifier: String
  var fill: Bool
  var onPaste: (String) -> Void

  func makeUIView(context: Context) -> PasteTarget {
    let target = PasteTarget()
    target.onPaste = onPaste
    let config = UIPasteControl.Configuration()
    config.displayMode = .iconAndLabel
    config.cornerStyle = .capsule
    config.baseBackgroundColor = UIColor(HColor.actionAccentSubtle)
    config.baseForegroundColor = UIColor(HColor.textLink)
    let control = UIPasteControl(configuration: config)
    control.target = target
    control.accessibilityIdentifier = identifier
    control.accessibilityHint = "Uses the invite link you copied."
    control.translatesAutoresizingMaskIntoConstraints = false
    target.addSubview(control)
    NSLayoutConstraint.activate([
      control.leadingAnchor.constraint(equalTo: target.leadingAnchor),
      control.trailingAnchor.constraint(equalTo: target.trailingAnchor),
      control.topAnchor.constraint(equalTo: target.topAnchor),
      control.bottomAnchor.constraint(equalTo: target.bottomAnchor),
    ])
    return target
  }

  func updateUIView(_ target: PasteTarget, context: Context) {
    target.onPaste = onPaste
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView target: PasteTarget, context: Context) -> CGSize? {
    guard let control = target.subviews.first else { return nil }
    let limit = CGSize(width: proposal.width ?? UIView.layoutFittingExpandedSize.width, height: UIView.layoutFittingExpandedSize.height)
    let fitted = control.sizeThatFits(limit)
    let laid = control.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    let intrinsic = control.intrinsicContentSize
    let natural = CGSize(
      width: max(fitted.width, laid.width, intrinsic.width), height: max(fitted.height, laid.height, intrinsic.height))
    let width = fill ? (proposal.width ?? natural.width) : min(natural.width, proposal.width ?? natural.width)
    return CGSize(width: max(width, 88), height: max(natural.height, 44))
  }

  final class PasteTarget: UIView {
    var onPaste: (String) -> Void = { _ in }

    override init(frame: CGRect) {
      super.init(frame: frame)
      pasteConfiguration = UIPasteConfiguration(
        acceptableTypeIdentifiers: [UTType.utf8PlainText.identifier, UTType.plainText.identifier, UTType.url.identifier])
    }

    required init?(coder: NSCoder) { nil }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool { true }

    override func paste(itemProviders: [NSItemProvider]) {
      guard let provider = itemProviders.first else { return }
      let deliver: @Sendable (String) -> Void = { [weak self] text in
        Task { @MainActor in self?.onPaste(text) }
      }
      if provider.canLoadObject(ofClass: NSString.self) {
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in deliver((value as? NSString as String?) ?? "") }
      } else {
        _ = provider.loadObject(ofClass: NSURL.self) { value, _ in deliver((value as? NSURL)?.absoluteString ?? "") }
      }
    }
  }
}

private struct CopiedInviteCard: View {
  var stacked: Bool
  var onPaste: (String) -> Void

  var body: some View {
    Group {
      if stacked {
        VStack(alignment: .leading, spacing: 10) {
          message
          paste(fill: true)
        }
      } else {
        HStack(spacing: 10) {
          message
          Spacer(minLength: 0)
          paste(fill: false)
        }
      }
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 14)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(HColor.blue200, lineWidth: 1)
    }
  }

  private var message: some View {
    HStack(alignment: .top, spacing: 10) {
      ZStack {
        Circle().fill(HColor.actionAccent)
        HIconView(.check, size: 12, color: .white, strokeWidth: 2.6)
      }
      .frame(width: 20, height: 20)
      VStack(alignment: .leading, spacing: 1) {
        Text("Copied your invite link?")
          .hType(.subheadline.weight(.semibold))
          .foregroundStyle(HColor.textPrimary)
        Text("Paste it here. There's no code to type.")
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("stories.inviteFound")
  }

  private func paste(fill: Bool) -> some View {
    WidePasteButton(identifier: "stories.useInvite", fill: fill, onPaste: onPaste)
      .frame(maxWidth: fill ? .infinity : nil, minHeight: 44)
      .fixedSize(horizontal: !fill, vertical: true)
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
