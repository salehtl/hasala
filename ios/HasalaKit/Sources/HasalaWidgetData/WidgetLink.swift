import Foundation
import HasalaModels

public enum WidgetLink: Sendable, Hashable {
  case home
  case plan
  case category(CategoryID)
  case bills
  case accounts
  case review
  case activity

  public static let scheme = "hasala"
  static let host = "widget"

  public var url: URL {
    var c = URLComponents()
    c.scheme = Self.scheme
    c.host = Self.host
    switch self {
    case .home: c.path = "/home"
    case .plan: c.path = "/plan"
    case .category(let id):
      c.path = "/category"
      c.queryItems = [URLQueryItem(name: "id", value: id)]
    case .bills: c.path = "/bills"
    case .accounts: c.path = "/accounts"
    case .review: c.path = "/review"
    case .activity: c.path = "/activity"
    }
    return c.url ?? URL(fileURLWithPath: "/")
  }

  public init?(url: URL) {
    guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == Self.scheme,
      c.host == Self.host
    else { return nil }
    switch c.path {
    case "/home": self = .home
    case "/plan": self = .plan
    case "/category":
      guard let id = c.queryItems?.first(where: { $0.name == "id" })?.value, !id.isEmpty else { return nil }
      self = .category(id)
    case "/bills": self = .bills
    case "/accounts": self = .accounts
    case "/review": self = .review
    case "/activity": self = .activity
    default: return nil
    }
  }
}
