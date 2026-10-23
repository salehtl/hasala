import CoreCategorize
import CoreJSON
import CoreReplay
import CoreWire
import HasalaText
import Testing

@testable import CoreDomain

@Suite("category management")
struct CategoryManagementTests {
  static func custom(_ n: Int, name: String? = nil, active: Bool = true, parent: String? = "dining") -> CategoryInfo {
    CategoryInfo(
      id: "c_\(n)", name: name ?? "Custom \(n)", kind: .spending, bucket: .want, icon: "tag", active: active, builtin: false, sortKey: 100 + n,
      parent: parent)
  }

  static func view(_ customs: [CategoryInfo]) -> TaxonomyView { TaxonomyView(TaxonomyV1.builtins + customs) }

  static func refusal(_ body: () throws(AuthorError) -> Void) -> String? {
    do throws(AuthorError) {
      try body()
      return nil
    } catch {
      if case .refused(let m) = error { return m }
      return "\(error)"
    }
  }

  static func apply(_ a: OpAuthor, _ s: inout State, seq: Int64) throws {
    try Replay.foldOps(try a.build().ops, seq: seq, writerID: w, into: &s)
    #expect(s.anomalies.isEmpty, "\(s.anomalies)")
  }

  static func v4Category(_ payload: String, seq: Int64, _ s: inout State, v: Int = 4) throws {
    let op =
      #"{"v":\#(v),"type":"category_defined","op_id":"op-\#(seq)","authored_at":"2026-10-01T08:00:00.000Z","parent_version":null,"payload":\#(payload)}"#
    let body = Array(#"{"v":\#(v),"kind":"ops","ops":[\#(op)]}"#.utf8)
    try Replay.foldOps(try OpCodec.decodeBlobOps(body), seq: seq, writerID: "dev-a", into: &s)
  }

  @Test("the taxonomy constants: system ids, parents, limits")
  func constants() {
    #expect(TaxonomyV1.maxActiveCustom == 20 && TaxonomyV1.maxNameScalars == 24)
    #expect(TaxonomyV1.systemIDs == ["transfer", "refunds", "salary"])
    #expect(TaxonomyV1.parentCandidates.count == 16)
    #expect(!TaxonomyV1.isParentCandidate("transfer") && !TaxonomyV1.isParentCandidate("refunds"))
    #expect(TaxonomyV1.parentCandidates == Grammar.categoryParentIDs)
    #expect(TaxonomyV1.parentClass("dining")! == (CategoryKind.spending, Bucket.want))
    #expect(TaxonomyV1.parentClass("salary")! == (CategoryKind.income, nil))
    #expect(TaxonomyV1.parentClass("savings")! == (CategoryKind.spending, Bucket.saving))
    #expect(TaxonomyV1.parentClass("transfer") == nil && TaxonomyV1.parentClass("c_1") == nil)
  }

  @Test("create: name rules, duplicates among active categories, parent and cap")
  func createRules() {
    let r = CategoryRules(Self.view([Self.custom(1, name: "Coffee"), Self.custom(2, name: "Pets", active: false)]))
    #expect(r.checkCreate(name: "Kids", parent: "shopping") == nil)
    #expect(r.checkCreate(name: "  \n ", parent: "dining") == .nameEmpty)
    #expect(r.checkCreate(name: String(repeating: "a", count: 25), parent: "dining") == .nameTooLong(max: 24))
    #expect(r.checkCreate(name: String(repeating: "a", count: 24), parent: "dining") == nil)
    #expect(r.checkCreate(name: "Bad\u{0007}name", parent: "dining") == .nameInvalid)
    #expect(r.checkCreate(name: " coffee ", parent: "dining") == .nameTaken("Coffee"))
    #expect(r.checkCreate(name: "DINING", parent: "dining") == .nameTaken("Dining"))
    #expect(r.checkCreate(name: "Caf\u{65}\u{301}", parent: "dining") == nil)
    #expect(r.checkCreate(name: "pets", parent: "shopping") == nil)
    #expect(r.checkCreate(name: "Kids", parent: "transfer") == .parentNotAllowed)
    #expect(r.checkCreate(name: "Kids", parent: "c_1") == .parentNotAllowed)
    #expect(r.checkCreate(name: "Kids", parent: "dining", icon: "bad icon") == .iconInvalid)
  }

  @Test("an NFC and an NFD spelling of one name are the same name")
  func nfcDuplicate() {
    let r = CategoryRules(Self.view([Self.custom(1, name: "Caf\u{E9}")]))
    #expect(r.checkCreate(name: "CAFE\u{301}", parent: "dining") == .nameTaken("Caf\u{E9}"))
  }

  @Test("the cap counts active custom categories only, and over the cap nothing is hidden")
  func cap() {
    let twenty = (1...20).map { Self.custom($0) }
    let at = CategoryRules(Self.view(twenty + [Self.custom(30, active: false)]))
    #expect(at.activeCustomCount == 20 && !at.canAddActive)
    #expect(at.checkCreate(name: "Kids", parent: "dining") == .atCap(max: 20))
    #expect(at.checkSetActive(id: "c_30", active: true) == .atCap(max: 20))
    #expect(at.checkSetActive(id: "c_1", active: false) == nil)
    #expect(at.checkEdit(id: "c_1", name: "Renamed") == nil)
    #expect(at.checkSetActive(id: "dining", active: true) == nil)

    let over = Self.view((1...21).map { Self.custom($0) })
    #expect(over.ordered.filter { !$0.builtin && $0.active }.count == 21)
    #expect(CategoryRules(over).activeCustomCount == 21)
    #expect(CategoryRules(over).checkCreate(name: "Kids", parent: "dining") == .atCap(max: 20))

    let under = CategoryRules(Self.view((1...19).map { Self.custom($0) } + [Self.custom(30, active: false)]))
    #expect(under.checkSetActive(id: "c_30", active: true) == nil)
    #expect(under.checkCreate(name: "Kids", parent: "dining") == nil)
  }

  @Test("edit: a custom category may change name, icon and parent; a built-in only its name and icon")
  func editRules() {
    let r = CategoryRules(Self.view([Self.custom(1, name: "Coffee"), Self.custom(2, name: "Tea")]))
    #expect(r.checkEdit(id: "c_1", name: "coffee") == nil)
    #expect(r.checkEdit(id: "c_1", name: "Tea") == .nameTaken("Tea"))
    #expect(r.checkEdit(id: "c_1", parent: "groceries") == nil)
    #expect(r.checkEdit(id: "c_1", parent: "refunds") == .parentNotAllowed)
    #expect(r.checkEdit(id: "dining", name: "Eating out", icon: "fork_knife") == nil)
    #expect(r.checkEdit(id: "dining", name: "Coffee") == .nameTaken("Coffee"))
    #expect(r.checkEdit(id: "dining", parent: "rent") == .builtinLocked)
    #expect(r.checkEdit(id: "c_99", name: "X") == .unknownCategory)
  }

  @Test("hide: system categories stay; others may be hidden")
  func hideRules() {
    let r = CategoryRules(Self.view([Self.custom(1)]))
    for id in ["transfer", "refunds", "salary"] { #expect(r.checkSetActive(id: id, active: false) == .systemCannotHide) }
    #expect(r.checkSetActive(id: "dining", active: false) == nil)
    #expect(r.checkSetActive(id: "freelance", active: false) == nil)
    #expect(r.checkSetActive(id: "c_1", active: false) == nil)
    #expect(r.checkSetActive(id: "c_404", active: false) == .unknownCategory)
  }

  @Test("refusal messages are short plain sentences")
  func messages() {
    let all: [CategoryRefusal] = [
      .nameEmpty, .nameTooLong(max: 24), .nameInvalid, .nameTaken("Coffee"), .iconInvalid, .parentNotAllowed, .atCap(max: 20), .unknownCategory,
      .builtinLocked, .systemCannotHide,
    ]
    for r in all { #expect(!r.message.isEmpty && r.message.hasSuffix(".") && r.message.count <= 60, "\(r)") }
    #expect(CategoryRefusal.atCap(max: 20).message == "You have 20 categories. Archive one to add another.")
  }

  @Test("author round trip: create, re-parent, rename, archive, unarchive")
  func authorRoundTrip() throws {
    var s = State()
    var a = OpAuthor(ctx())
    let id = try a.createCategory(name: " Coffee ", parent: "dining", icon: "cup", in: TaxonomyView(state: s))
    #expect(id.hasPrefix("c_") && id.utf8.count == 28)
    try Self.apply(a, &s, seq: 1)
    let op = s.categories[ExactKey(id)]!
    #expect(op.shape == 4 && op.parent == "dining" && op.kind == "spending" && op.bucket == "want" && op.name == "Coffee")
    var t = TaxonomyView(state: s)
    var c = try #require(t.info(id))
    #expect(c.parent == "dining" && c.kind == .spending && c.bucket == .want && c.icon == "cup" && c.active && !c.builtin && c.sortKey == 100)

    var b = OpAuthor(ctx(own: now + 10))
    try b.editCategory(id: id, parent: "groceries", in: t)
    try Self.apply(b, &s, seq: 2)
    t = TaxonomyView(state: s)
    c = try #require(t.info(id))
    #expect(c.parent == "groceries" && c.bucket == .need && c.name == "Coffee" && c.icon == "cup")

    var e = OpAuthor(ctx(own: now + 20))
    try e.editCategory(id: id, name: "Coffee shops", in: t)
    try Self.apply(e, &s, seq: 3)
    t = TaxonomyView(state: s)
    c = try #require(t.info(id))
    #expect(c.name == "Coffee shops" && c.parent == "groceries" && c.bucket == .need)

    var f = OpAuthor(ctx(own: now + 30))
    try f.editCategory(id: id, parent: "salary", in: t)
    try Self.apply(f, &s, seq: 4)
    t = TaxonomyView(state: s)
    c = try #require(t.info(id))
    #expect(c.kind == .income && c.bucket == nil && c.parent == "salary")

    var g = OpAuthor(ctx(own: now + 40))
    try g.setCategoryActive(id: id, active: false, in: t)
    try Self.apply(g, &s, seq: 5)
    t = TaxonomyView(state: s)
    #expect(t.info(id)?.active == false && t.info(id)?.parent == "salary")

    var h = OpAuthor(ctx(own: now + 50))
    try h.setCategoryActive(id: id, active: true, in: t)
    try Self.apply(h, &s, seq: 6)
    #expect(TaxonomyView(state: s).info(id)?.active == true)
  }

  @Test("editing a built-in keeps its kind and bucket and writes no parent")
  func editBuiltin() throws {
    var s = State()
    var a = OpAuthor(ctx())
    try a.editCategory(id: "dining", name: "Eating out", in: TaxonomyView(state: s))
    let op = try #require(try a.build().ops.first)
    #expect(op.payload["parent"] == nil && op.payload["icon"]?.stringValue == "fork_knife")
    try Replay.foldOps([op], seq: 1, writerID: w, into: &s)
    let c = try #require(TaxonomyView(state: s).info("dining"))
    #expect(c.name == "Eating out" && c.kind == .spending && c.bucket == .want && c.builtin && c.parent == nil && c.sortKey == 7)

    var b = OpAuthor(ctx())
    #expect(Self.refusal { () throws(AuthorError) in try b.editCategory(id: "dining", parent: "rent", in: TaxonomyView(state: s)) } == CategoryRefusal.builtinLocked.message)
    #expect(b.count == 0)
  }

  @Test("the author refuses with the rule's message and drafts nothing")
  func authorRefusals() {
    let t = Self.view((1...20).map { Self.custom($0) })
    var a = OpAuthor(ctx())
    #expect(Self.refusal { () throws(AuthorError) in _ = try a.createCategory(name: "Kids", parent: "dining", in: t) } == CategoryRefusal.atCap(max: 20).message)
    #expect(Self.refusal { () throws(AuthorError) in try a.setCategoryActive(id: "transfer", active: false, in: t) } == CategoryRefusal.systemCannotHide.message)
    #expect(Self.refusal { () throws(AuthorError) in try a.editCategory(id: "c_1", name: "Custom 2", in: t) } == CategoryRefusal.nameTaken("Custom 2").message)
    #expect(a.count == 0)
  }

  @Test("defineCategory without a parent writes the same keys as before")
  func defineWithoutParent() throws {
    var a = OpAuthor(ctx())
    a.defineCategory(id: "c_01jc0000000000000000000002", name: "Pets", kind: .spending, bucket: .want, icon: "paw", active: true)
    let op = try #require(try a.build().ops.first)
    #expect(op.payload.objectValue?.keys.map { $0 } == ["id", "name", "kind", "bucket", "icon", "active"])
  }

  @Test("the fold ignores a parent that is not a parent built-in, and keeps the record")
  func foldIgnoresParent() throws {
    var s = State()
    try Self.v4Category(#"{"id":"c_1x","name":"Coffee","kind":"spending","bucket":"want","icon":null,"parent":"dining","active":true}"#, seq: 1, &s)
    #expect(s.anomalies.isEmpty && s.categories[ExactKey("c_1x")]?.parent == "dining")
    for (i, bad) in [#""c_2x""#, #""transfer""#, #""refunds""#, "7", #""""#, #""Dining""#, #""no_such""#, "{}"].enumerated() {
      try Self.v4Category(
        #"{"id":"c_1x","name":"Tea \#(i)","kind":"spending","bucket":"want","icon":null,"parent":\#(bad),"active":true}"#, seq: Int64(2 + i), &s)
      #expect(s.categories[ExactKey("c_1x")]?.name == "Tea \(i)" && s.categories[ExactKey("c_1x")]?.parent == nil, "\(bad)")
    }
    #expect(s.anomalies.isEmpty)
    try Self.v4Category(#"{"id":"c_1x","name":"Tea","kind":"spending","bucket":"want","icon":null,"parent":null,"active":true}"#, seq: 20, &s)
    #expect(s.categories[ExactKey("c_1x")]?.name == "Tea" && s.categories[ExactKey("c_1x")]?.parent == nil)
  }

  @Test("the fold drops a parent of another kind or bucket than the record")
  func foldDropsMismatchedParent() throws {
    var s = State()
    let cases: [(String, String, String, String?)] = [
      ("c_1x", "income", "null", nil), ("c_2x", "spending", #""need""#, nil), ("c_3x", "spending", #""want""#, "dining"),
      ("c_4x", "excluded", "null", nil),
    ]
    for (i, (id, kind, bucket, _)) in cases.enumerated() {
      try Self.v4Category(
        #"{"id":"\#(id)","name":"N\#(i)","kind":"\#(kind)","bucket":\#(bucket),"icon":null,"parent":"dining","active":true}"#, seq: Int64(1 + i), &s)
    }
    #expect(s.anomalies.isEmpty)
    for (id, kind, _, parent) in cases {
      #expect(s.categories[ExactKey(id)]?.kind == kind && s.categories[ExactKey(id)]?.parent == parent, "\(id)")
    }
    let t = TaxonomyView(state: s)
    #expect(t.info("c_1x")?.kind == .income && t.info("c_1x")?.parent == nil)
    try Self.v4Category(#"{"id":"c_5x","name":"Tips","kind":"income","bucket":null,"icon":null,"parent":"salary","active":true}"#, seq: 10, &s)
    #expect(s.categories[ExactKey("c_5x")]?.parent == "salary")
  }

  @Test("the fold's parent classes are the taxonomy's")
  func grammarParentClasses() {
    for id in TaxonomyV1.parentCandidates {
      let t = TaxonomyV1.parentClass(id)!
      let g = Grammar.categoryParentClass(id)!
      #expect(t.kind.rawValue == g.kind && t.bucket?.rawValue == g.bucket, "\(id)")
    }
    #expect(Grammar.categoryParentClass("transfer") == nil)
  }

  @Test("restore refuses a name that an active category already has")
  func restoreDuplicateName() {
    let hiddenDining = CategoryInfo(
      id: "dining", name: "Dining", kind: .spending, bucket: .want, icon: "fork_knife", active: false, builtin: true, sortKey: 7)
    let infos = TaxonomyV1.builtins.filter { $0.id != "dining" } + [
      hiddenDining, Self.custom(1, name: "Coffee", active: false), Self.custom(2, name: " coffee"), Self.custom(3, name: "dining"),
      Self.custom(4, name: "Pets", active: false),
    ]
    let r = CategoryRules(TaxonomyView(infos))
    #expect(r.checkSetActive(id: "c_1", active: true) == .nameTaken(" coffee"))
    #expect(r.checkSetActive(id: "dining", active: true) == .nameTaken("dining"))
    #expect(r.checkSetActive(id: "c_4", active: true) == nil)
    var a = OpAuthor(ctx())
    #expect(Self.refusal { () throws(AuthorError) in try a.setCategoryActive(id: "c_1", active: true, in: TaxonomyView(infos)) } == CategoryRefusal.nameTaken(" coffee").message)
    #expect(a.count == 0)
  }

  @Test("a hidden built-in is not offered as a parent, and its children keep working")
  func hiddenParent() {
    let debt = CategoryInfo(id: "debt", name: "Debt", kind: .spending, bucket: .saving, icon: "card", active: false, builtin: true, sortKey: 14)
    let child = CategoryInfo(
      id: "c_1", name: "Loan", kind: .spending, bucket: .saving, icon: "tag", active: true, builtin: false, sortKey: 101, parent: "debt")
    let r = CategoryRules(TaxonomyView(TaxonomyV1.builtins.filter { $0.id != "debt" } + [debt, child, Self.custom(2)]))
    #expect(!r.isOfferedParent("debt") && r.isOfferedParent("savings"))
    #expect(r.checkCreate(name: "Car loan", parent: "debt") == .parentNotAllowed)
    #expect(r.checkEdit(id: "c_1", name: "Car loan") == nil)
    #expect(r.checkEdit(id: "c_1", name: "Car loan", parent: "debt") == nil)
    #expect(r.checkEdit(id: "c_2", parent: "debt") == .parentNotAllowed)
    #expect(r.checkEdit(id: "c_1", parent: "savings") == nil)
  }

  @Test("editing a parentless custom category keeps its kind and bucket and writes no parent")
  func editParentless() throws {
    var s = State()
    try Self.v4Category(#"{"id":"c_01jc0000000000000000000009","name":"House fund","kind":"spending","bucket":"saving","icon":"jar","active":true}"#, seq: 1, &s)
    let t = TaxonomyView(state: s)
    #expect(CategoryRules(t).checkEdit(id: "c_01jc0000000000000000000009", name: "Home fund") == nil)
    var a = OpAuthor(ctx())
    try a.editCategory(id: "c_01jc0000000000000000000009", name: "Home fund", icon: "house", in: t)
    let op = try #require(try a.build().ops.first)
    #expect(op.payload["parent"] == nil)
    try Self.apply(a, &s, seq: 2)
    let c = try #require(TaxonomyView(state: s).info("c_01jc0000000000000000000009"))
    #expect(c.name == "Home fund" && c.icon == "house" && c.kind == .spending && c.bucket == .saving && c.parent == nil && !c.builtin)

    var income = State()
    try Self.v4Category(#"{"id":"c_01jc0000000000000000000008","name":"Rent in","kind":"income","bucket":null,"icon":null,"active":true}"#, seq: 1, &income)
    var b = OpAuthor(ctx())
    try b.editCategory(id: "c_01jc0000000000000000000008", name: "Rental income", in: TaxonomyView(state: income))
    try Self.apply(b, &income, seq: 2)
    let d = try #require(TaxonomyView(state: income).info("c_01jc0000000000000000000008"))
    #expect(d.kind == .income && d.bucket == nil && d.parent == nil && d.name == "Rental income")
  }

  @Test("a v3 category_defined ignores parent")
  func v3IgnoresParent() throws {
    var s = State()
    try Self.v4Category(#"{"id":"k1","name":"Coffee","kind":"spending","bucket":"want","parent":"not a parent","active":true}"#, seq: 1, &s, v: 3)
    #expect(s.anomalies.isEmpty)
    #expect(s.categories[ExactKey("k1")]?.parent == nil && s.categories[ExactKey("k1")]?.shape == 3)
    #expect(TaxonomyView(state: s).info("k1")?.parent == nil)
  }

  @Test("a built-in override never carries a parent in the view")
  func builtinOverrideNoParent() throws {
    var s = State()
    try Self.v4Category(#"{"id":"dining","name":"Food","kind":"spending","bucket":"want","icon":null,"parent":"shopping","active":true}"#, seq: 1, &s)
    #expect(s.categories[ExactKey("dining")]?.parent == "shopping")
    #expect(TaxonomyView(state: s).info("dining")?.parent == nil)
  }

  @Test("the parent survives a snapshot")
  func snapshotKeepsParent() throws {
    var s = State()
    try Self.v4Category(#"{"id":"c_1x","name":"Coffee","kind":"spending","bucket":"want","icon":null,"parent":"dining","active":true}"#, seq: 1, &s)
    let back = try SnapshotCodec.decode(try SnapshotCodec.encode(StateSnapshot(state: s))).state
    #expect(back == s && back.categories[ExactKey("c_1x")]?.parent == "dining")
  }

  @Test("a client-made id is kept, and the new category and the filed row share one blob")
  func clientMadeID() throws {
    var s = State()
    var e = OpAuthor(ctx())
    let txn = try e.manualEntry(amountMinor: 1_200, currency: "AED", direction: "debit", localWallMs: now, merchant: "CAFE", category: nil)
    try Self.apply(e, &s, seq: 1)
    let id = try OpAuthor.newCategoryID(ms: now, random: Counter())
    #expect(id.hasPrefix("c_") && id.utf8.count == 28 && OpAuthor.isNewCategoryID(id))
    #expect(!OpAuthor.isNewCategoryID("dining") && !OpAuthor.isNewCategoryID("c_X"))

    var a = OpAuthor(ctx(own: now + 10))
    let version = try #require(s.txns[txn]).version
    try a.createCategoryAndFile(
      id: id, name: " Coffee ", parent: "dining", icon: "cup", in: TaxonomyView(state: s), txnID: txn, parentVersion: version,
      project: "01JC0000000000000000000005")
    let blob = try a.build()
    #expect(blob.ops.map(\.type) == [.categoryDefined, .txnCategorized, .txnAnnotated])
    try Replay.foldOps(blob.ops, seq: 2, writerID: w, into: &s)
    let c = try #require(TaxonomyView(state: s).info(id))
    #expect(c.name == "Coffee" && c.parent == "dining" && c.active && !c.builtin)
    let t = try #require(s.txns[txn])
    #expect(t.category == id && !t.needsReview && t.categorySource?.kind == .user && t.annotation("project_id") == "01JC0000000000000000000005")
  }

  @Test("a refused or reused id drafts nothing")
  func clientMadeIDRefusals() throws {
    let t = Self.view([Self.custom(1, name: "Coffee")])
    var a = OpAuthor(ctx())
    func file(_ id: String, _ name: String, in view: TaxonomyView = t) -> String? {
      Self.refusal { () throws(AuthorError) in
        try a.createCategoryAndFile(id: id, name: name, parent: "dining", in: view, txnID: "t_1", parentVersion: 1)
      }
    }
    #expect(file("c_01jc0000000000000000000009", "coffee") == CategoryRefusal.nameTaken("Coffee").message)
    #expect(file("c_01jc0000000000000000000009", "Tea\u{202E}") == CategoryRefusal.nameInvalid.message)
    #expect(file("c_01jc0000000000000000000009", "Tea", in: Self.view((1...20).map { Self.custom($0) })) == CategoryRefusal.atCap(max: 20).message)
    #expect(file("c_1", "Tea") == "invalidOp(\"category_defined: id\")")
    #expect(file("dining", "Tea") == "invalidOp(\"category_defined: id\")")
    #expect(a.count == 0)
  }
}
