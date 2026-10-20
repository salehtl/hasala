import Foundation
import OutlookTrustCheckKit

func fail(_ message: String, code: Int32) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(code)
}

guard let args = TrustCheck.parse(Array(CommandLine.arguments.dropFirst())) else {
  fail(TrustCheck.usage, code: 64)
}

let dir = URL(fileURLWithPath: args.directory).standardizedFileURL.resolvingSymlinksInPath()
if TrustCheck.insideRepository(dir) {
  fail("outlook-trust-check: \(args.directory) is inside a Hasala checkout; real mail must stay outside it", code: 64)
}

let inputs: [MessageInput]
do {
  inputs = try TrustCheck.collect(directory: dir)
} catch {
  fail("outlook-trust-check: cannot read the folder", code: 66)
}

let report = TrustCheck.run(inputs, expect: args.expect, domains: args.domains)
FileHandle.standardOutput.write(Data("outlook-trust-check expect=\(args.expect.rawValue) files=\(inputs.count)\n".utf8))
FileHandle.standardOutput.write(Data(report.text.utf8))
exit(report.exitCode)
