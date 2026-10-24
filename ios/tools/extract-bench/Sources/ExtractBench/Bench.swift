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
    for mu in mutations {
      var s: [(Mail, Truth, Bool)] = []
      var bySender: [String: [(Mail, Truth)]] = [:]
      for it in items { bySender[it.0.sender + "|" + it.0.origin, default: []].append(it) }
      for (_, list) in bySender.sorted(by: { $0.key < $1.key }) {
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
          let g = m.origin + " " + m.sender
          var a = byGroup[g, default: Tally()]
          Score.add(got, t, into: &a, misses: &misses, reader: r.name, kind: kind, id: m.id)
          byGroup[g] = a
        }
        for (g, a) in byGroup.sorted(by: { $0.key < $1.key }) { rows.append(Row(reader: r.name, kind: kind, group: g, tally: a)) }
      }
    }
    return (rows, misses)
  }
}
