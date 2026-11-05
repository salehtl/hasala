import Foundation
import HasalaWidgetData
import Testing

@Suite("Widgets · project and goal links")
struct WidgetDeepLinkTests {
  @Test(arguments: [WidgetLink.project("p-1"), .goal("g-1")])
  func roundTrips(link: WidgetLink) {
    #expect(WidgetLink(url: link.url) == link)
  }

  @Test func aLinkWithNoIdIsNotALink() throws {
    #expect(WidgetLink(url: try #require(URL(string: "hasala://widget/project"))) == nil)
    #expect(WidgetLink(url: try #require(URL(string: "hasala://widget/goal?id="))) == nil)
    #expect(WidgetLink(url: try #require(URL(string: "hasala://widget/projects?id=p-1"))) == nil)
  }
}
