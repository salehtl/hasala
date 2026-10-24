import Foundation

struct Row {
  var reader: String
  var kind: String
  var group: String
  var tally: Tally
}

enum Bench {
  static func streams(_ items: [(Mail, Truth)], mutations: [Mutation]) -> [(String, [(Mail, Truth, Bool)])] {
    var out: [(String, [(Mail, Truth, Bool)])] = [("original", items.map { ($0.0, $0.1, true) })]
    let senders = Dictionary(grouping: items) { $0.0.sender + "|" + $0.0.origin }.sorted { $0.key < $1.key }
    for mu in mutations {
      var s: [(Mail, Truth, Bool)] = []
      for (_, list) in senders {
        let cut = list.count / 2
        for (i, it) in list.enumerated() {
          if i < cut {
            s.append((it.0, it.1, false))
          } else if let v = mu.apply(it.0, it.1) {
            s.append((v.mail, v.truth, true))
          }
        }
      }
      s.sort { ($0.0.receivedAtMs, $0.0.id) < ($1.0.receivedAtMs, $1.0.id) }
      out.append((mu.kind, s))
    }
    return out
  }

  static func run(readers: [Reader], items: [(Mail, Truth)], mutations: [Mutation]) -> ([Row], [Miss]) {
    var rows: [Row] = []
    var misses: [Miss] = []
    for (kind, stream) in streams(items, mutations: mutations) {
      for r in readers {
        r.reset()
        var byGroup: [String: Tally] = [:]
        for (m, t, scored) in stream {
          let got = r.read(m)
          guard scored else { continue }
          Score.add(got, t, into: &byGroup[m.origin + " " + m.sender, default: Tally()], misses: &misses, reader: r.name, kind: kind, id: m.id)
        }
        for (g, a) in byGroup.sorted(by: { $0.key < $1.key }) { rows.append(Row(reader: r.name, kind: kind, group: g, tally: a)) }
      }
    }
    return (rows, misses)
  }
}
