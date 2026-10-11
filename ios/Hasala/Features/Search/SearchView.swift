import HasalaDesign
import SwiftUI

/// Search · Ready (Paper board). The search tab expands into the bottom search
/// field (spec 04 §13.1); answers arrive with the search engine.
struct SearchView: View {
  let app: AppModel
  @State private var query = ""

  private let suggestions = [
    "How much did I spend on dining?",
    "When is DEWA due?",
    "What's left for groceries?",
  ]

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text("Try asking").hType(.overline).foregroundStyle(HColor.textSecondary)
          VStack(spacing: 0) {
            ForEach(suggestions, id: \.self) { s in
              Button { query = s } label: {
                HStack(spacing: 12) {
                  Image(systemName: "sparkle.magnifyingglass").foregroundStyle(HColor.iconAccent)
                  Text(s).hType(.callout).foregroundStyle(HColor.textPrimary)
                  Spacer()
                }
                .padding(.horizontal, HSpacing.listRowInsetInline)
                .frame(minHeight: HSpacing.listRowMinHeight)
              }
              .buttonStyle(.plain)
            }
          }
          .listCard()
          PlaceholderCard(systemImage: "magnifyingglass", title: "Coming soon",
                          message: "Search and direct answers arrive with the search engine.")
            .accessibilityIdentifier("search.placeholder")
        }
        .padding(HSpacing.insetPage)
      }
      .background(HColor.surfaceSecondary)
      .navigationTitle("Search")
      .searchable(text: $query, prompt: "Ask or search")
    }
  }
}
