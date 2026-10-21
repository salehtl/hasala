import HasalaWidgetData
import Observation

@MainActor
@Observable
final class WidgetLinkInbox {
  static let shared = WidgetLinkInbox()
  var pending: WidgetLink?
}

extension AppModel {
  func open(_ link: WidgetLink) {
    router.clearPresentation()
    switch link {
    case .home:
      router.tab = .home
      router.home = []
    case .plan:
      openPlan()
    case .category(let id):
      openPlan(category: store.state.category(id) == nil ? nil : id)
    case .bills:
      router.tab = .home
      router.home = [.bills]
    case .accounts:
      router.tab = .home
      router.home = BuildSurface.showsUnfinished ? [.accounts] : []
    case .review:
      router.tab = .review
      if reviewCount > 0 { startReview() }
    case .activity:
      router.tab = .activity
      router.activity = []
    }
  }
}
