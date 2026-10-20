#if DEBUG
  import CoreMail
  import CoreMailbox
  import CoreTime
  import HasalaDesign
  import SwiftUI

  struct OutlookHeaderOrderPage: View {
    let mailbox: LiveMailboxConnecting
    @State private var count = 5
    @State private var running = false
    @State private var report = ""

    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text(
            "Debug only. Reads $value and internetMessageHeaders for the alerts from the trusted senders and compares the order of the newest Received, the Authentication-Results, AuthAs and AuthSource. The report is redacted and holds no message content."
          )
          .hType(.footnote).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          Stepper("Messages: \(count)", value: $count, in: 1...20)
            .accessibilityIdentifier("headerOrder.count")
          Button(running ? "Reading…" : "Run") { Task { await run() } }
            .buttonStyle(.borderedProminent)
            .disabled(running)
            .accessibilityIdentifier("headerOrder.run")
          if !report.isEmpty {
            ShareLink(item: report) { Label("Share report", systemImage: "square.and.arrow.up") }
              .accessibilityIdentifier("headerOrder.share")
            Text(report)
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(HColor.textPrimary)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.vertical, 16)
      }
      .background(HColor.surfaceSecondary)
      .navigationTitle("Header order check")
      .navigationBarTitleDisplayMode(.inline)
    }

    private func run() async {
      running = true
      report = await OutlookHeaderOrderCheck.report(source: await mailbox.outlookTrustSource(), count: count)
      running = false
    }
  }

  nonisolated enum OutlookHeaderOrderCheck {
    static let windowDays: Int64 = 90

    static func report(source: LiveMailboxConnecting.OutlookTrustSource?, count: Int) async -> String {
      guard let source else {
        return "outlook-header-order-check\nC4 NEEDS-DATA no connected Outlook mailbox with trusted senders"
      }
      var ids: [String] = []
      var token: String? = nil
      let since = SystemClock().nowMs() / 1000 - windowDays * 86_400
      do {
        repeat {
          let page = try await source.graph.listMessages(senders: source.senders, sinceSec: since, pageToken: token)
          ids.append(contentsOf: page.ids)
          token = page.nextPageToken
        } while token != nil && ids.count < count
      } catch {
        return "outlook-header-order-check\nC4 NEEDS-DATA listing failed: \(error)"
      }
      var lines = ["outlook-header-order-check messages=\(min(ids.count, count)) senders=\(source.senders.count)"]
      var matched = 0
      var read = 0
      let picked = Array(ids.prefix(count))
      let width = max(2, String(picked.count).count)
      for (i, id) in picked.enumerated() {
        let n = String(i + 1)
        let index = "#" + String(repeating: "0", count: width - n.count) + n
        do {
          let value = try await source.graph.messageValue(id: id)
          let listed = try await source.graph.messageHeaderList(id: id)
          let c = AuthResults.outlookOrderComparison(
            rawHeaders: MailHeaders.headerBlock(rawMessage: [UInt8](value)), listed: listed)
          read += 1
          if c.orderMatch && c.receivedSame { matched += 1 }
          lines.append("\(index) \(c.line)")
        } catch {
          lines.append("\(index) unreadable: \(error)")
        }
      }
      lines.append("")
      let status = read == 0 ? "NEEDS-DATA" : (matched == read && read == picked.count ? "PASS" : "FAIL")
      lines.append(
        "C4 \(status) \(matched)/\(picked.count) same order and newest Received in $value and internetMessageHeaders | expect: the same order, with the newest Received on top"
      )
      return lines.joined(separator: "\n")
    }
  }
#endif
