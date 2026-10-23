import Foundation

func arg(_ name: String) -> String? {
  let a = CommandLine.arguments
  guard let i = a.firstIndex(of: "--" + name), i + 1 < a.count else { return nil }
  return a[i + 1]
}

func flag(_ name: String) -> Bool { CommandLine.arguments.contains("--" + name) }

func die(_ s: String) -> Never {
  FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
  exit(2)
}

func allReaders() -> [Reader] {
  [
    TemplateReader(), RulesReader(), LearnedOnlyReader(), CombinedOnlyReader(), ChainReader(),
  ]
}

let command = CommandLine.arguments.dropFirst().first ?? ""
switch command {
case "dump":
  guard let mail = arg("mail"), let out = arg("out") else { die("dump --mail DIR --out FILE.jsonl") }
  let mails = try Corpus.loadMaildir(mail)
  try Corpus.writeJSONL(mails, to: out)
  print("wrote \(mails.count) mails to \(out)")

case "run":
  guard let out = arg("out") else { die("run --out DIR [--mail DIR --labels FILE] [--synthetic DIR] [--readers a,b] [--no-mutate]") }
  var items: [(Mail, Truth)] = []
  var notes: [String] = []
  if let syn = arg("synthetic") {
    let s = try Corpus.loadSynthetic(syn)
    items += s
    notes.append("synthetic: \(s.count) cases from \(syn)")
  }
  if let mail = arg("mail") {
    guard let lp = arg("labels") else { die("--mail needs --labels") }
    let labels = try Corpus.loadLabels(lp)
    let mails = try Corpus.loadMaildir(mail)
    let labeled = mails.compactMap { m in labels[m.id].map { (m, $0) } }
    items += labeled
    notes.append("real: \(labeled.count) of \(mails.count) mails labeled")
  }
  let only = arg("readers").map { Set($0.split(separator: ",").map(String.init)) }
  let readers = allReaders().filter { only?.contains($0.name) ?? true }
  let mutations = flag("no-mutate") ? [] : allMutations()
  notes.append("changes: original, " + mutations.map(\.kind).joined(separator: ", ") + " (each applied to the later half of each sender's mail, scored on that half)")
  let (rows, misses) = Bench.run(readers: readers, items: items, mutations: mutations)
  let summary = Report.merge(rows)
  print(Report.text(summary))
  try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
  try Report.html(summary: summary, detail: rows, notes: notes).write(toFile: out + "/report.html", atomically: true, encoding: .utf8)
  try Report.text(rows).write(toFile: out + "/by-sender.txt", atomically: true, encoding: .utf8)
  let enc = JSONEncoder()
  enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  try misses.map { String(decoding: try enc.encode($0), as: UTF8.self) }.joined(separator: "\n").write(
    toFile: out + "/misses.jsonl", atomically: true, encoding: .utf8)
  print("\nreport: \(out)/report.html  misses: \(misses.count)")

default:
  die("usage: ExtractBench dump|run …")
}
