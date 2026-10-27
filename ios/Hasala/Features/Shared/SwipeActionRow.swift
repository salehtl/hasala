import HasalaDesign
import SwiftUI
import UIKit

struct SwipeAction {
  let title: String
  let icon: HIcon
  let fill: Color
  let ink: Color
  let perform: () -> Void
}

struct SwipeActionRow<Content: View>: View {
  let id: String
  @Binding var open: String?
  let action: SwipeAction
  @ViewBuilder let content: Content

  @State private var offset: CGFloat = 0
  @State private var start: CGFloat?
  @State private var width: CGFloat = 0
  @State private var committing = false
  @Environment(\.hMotion) private var motion

  static var revealWidth: CGFloat { 88 }
  private var commitDistance: CGFloat { max(Self.revealWidth * 2, width * 0.5) }
  private var pastCommit: Bool { -offset >= commitDistance }

  var body: some View {
    content
      .accessibilityAction(named: action.title) { action.perform() }
      .background(HColor.listRowSurface)
      .overlay {
        if offset < 0, start == nil, !committing {
          Color.clear.contentShape(Rectangle()).onTapGesture { settle(0) }
            .accessibilityHidden(true)
        }
      }
      .offset(x: offset)
      .background(alignment: .trailing) { revealed }
      .clipped()
      .gesture(HorizontalPan(opensRightward: offset < 0, changed: drag, ended: release))
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
      .onChange(of: open) { _, now in
        if now != id, offset != 0, start == nil, !committing { settle(0) }
      }
      .hHaptic(.impactLight, trigger: pastCommit) { !$0 && $1 }
  }

  private var revealed: some View {
    Button(action: commit) {
      VStack(spacing: 4) {
        HIconView(action.icon, size: 20, color: action.ink)
        Text(action.title).hType(.footnote.weight(.semibold)).foregroundStyle(action.ink)
          .lineLimit(1).minimumScaleFactor(0.7)
      }
      .frame(width: Self.revealWidth)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: pastCommit ? .leading : .trailing)
      .background(action.fill)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .frame(width: max(0, -offset))
    .opacity(offset < 0 ? 1 : 0)
    .accessibilityHidden(true)
  }

  private func drag(_ x: CGFloat) {
    guard !committing else { return }
    if start == nil {
      start = offset
      if open != id { open = id }
    }
    let next = (start ?? 0) + x
    offset = next > 0 ? 0 : next < -width ? -width : next
  }

  private func release(_ x: CGFloat, _ velocity: CGFloat, _ cancelled: Bool) {
    guard !committing, let from = start else { return }
    start = nil
    let end = min(0, from + x)
    if cancelled {
      settle(0)
    } else if -end >= commitDistance || (velocity < -1000 && -end > Self.revealWidth) {
      commit()
    } else if -end > Self.revealWidth / 2 && velocity < 300 {
      settle(-Self.revealWidth)
    } else {
      settle(0)
    }
  }

  private func settle(_ to: CGFloat) {
    withHMotion(to == 0 ? .cardReturn : .thumbSlide, motion) { offset = to }
    if to == 0, open == id { open = nil }
  }

  private func commit() {
    guard !committing else { return }
    committing = true
    withAnimation(motion.animation(.cardCommit)) {
      offset = -max(width, Self.revealWidth)
    } completion: {
      action.perform()
      var still = Transaction()
      still.disablesAnimations = true
      withTransaction(still) { offset = 0 }
      committing = false
      if open == id { open = nil }
    }
  }
}

private struct HorizontalPan: UIGestureRecognizerRepresentable {
  let opensRightward: Bool
  let changed: (CGFloat) -> Void
  let ended: (CGFloat, CGFloat, Bool) -> Void

  func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

  func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
    let pan = UIPanGestureRecognizer()
    pan.maximumNumberOfTouches = 1
    pan.delegate = context.coordinator
    return pan
  }

  func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
    context.coordinator.opensRightward = opensRightward
  }

  func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
    let x = pan.translation(in: pan.view).x
    switch pan.state {
    case .began:
      context.coordinator.holdScroll()
      changed(x)
    case .changed:
      changed(x)
    case .ended:
      context.coordinator.releaseScroll()
      ended(x, pan.velocity(in: pan.view).x, false)
    case .cancelled, .failed:
      context.coordinator.releaseScroll()
      ended(x, 0, true)
    default:
      break
    }
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var opensRightward = false
    private weak var scrollPan: UIGestureRecognizer?

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
      guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
      let v = pan.velocity(in: pan.view)
      guard abs(v.x) > abs(v.y) * 1.5 else { return false }
      return v.x < 0 || opensRightward
    }

    func gestureRecognizer(
      _ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
      guard let scroll = other.view as? UIScrollView, other === scroll.panGestureRecognizer else { return false }
      scrollPan = other
      return true
    }

    func holdScroll() {
      guard let scrollPan else { return }
      scrollPan.isEnabled = false
    }

    func releaseScroll() {
      scrollPan?.isEnabled = true
      scrollPan = nil
    }
  }
}
