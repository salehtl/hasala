#if HASALA_MOCKS
  import CoreCategorize
  import HasalaModel

  struct ScriptedSearchModel: SearchQueryModel {
    static let replies: [String: SearchModelReply] = [
      "how much did i spend at carrefour in september": SearchModelReply(
        merchants: ["Carrefour"], period: .month, month: 9, flow: .spent, asksTotal: true),
      "how much did i spend at carrefour in september?": SearchModelReply(
        merchants: ["Carrefour"], period: .month, month: 9, flow: .spent, asksTotal: true),
      "coffee last month": SearchModelReply(merchants: ["Starbucks", "Common Grounds"], period: .lastMonth),
      "coffee this month": SearchModelReply(merchants: ["Starbucks", "Common Grounds"], period: .thisMonth),
      "how much on dining this month?": SearchModelReply(
        category: "dining", period: .thisMonth, flow: .spent, asksTotal: true),
      "when is rent due?": SearchModelReply(category: "rent"),
      "what did i spend at carrefour?": SearchModelReply(merchants: ["Carrefour"], flow: .spent, asksTotal: true),
      "groceries over 250 this month": SearchModelReply(
        category: "groceries", minimumAmount: "250", period: .thisMonth),
    ]

    func availability() -> ModelAvailability { .available }

    func interpret(_ query: String, vocabulary: SearchVocabulary) async -> SearchModelAnswer {
      try? await Task.sleep(for: .milliseconds(250))
      return Self.replies[query.lowercased()].map { .reply($0) } ?? .reply(SearchModelReply())
    }
  }
#endif
