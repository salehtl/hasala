import Foundation
import Testing

@testable import Hasala

/// Connecting a mailbox, in setup and after it, on the in-memory mock.
@MainActor
@Suite("Mailbox flows")
struct MailboxFlowTests: AccountSuite {
  // MARK: Connect Gmail after setup (spec 04 §6.6 row 4, §7.4)

  func connectServices(_ offer: GmailOffer?, banks: [SupportedBank] = SupportedBank.allCases)
    -> (AccountServices, MockMailbox)
  {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    let mailbox = s.mailbox as! MockMailbox
    mailbox.gmailOffer = offer
    mailbox.banks = banks
    return (s, mailbox)
  }

  @Test func connectingGmailAfterSetupRunsGmailThenTheResult() async throws {
    let (s, mailbox) = connectServices(.connect, banks: [.dib])
    var finished = 0, closed = 0
    let m = SetupModel.connectingGmail(.connect, services: s, onClose: { closed += 1 }, onFinished: { finished += 1 })
    #expect(!m.startsAtBank)
    #expect(m.orderedBanks == [.dib])
    #expect(m.steps(2) == nil)
    #expect(m.gmailIsFirst)
    #expect(m.connectTitle == "Connect Gmail")
    await m.openConnect()
    #expect(m.path.isEmpty)
    await m.connectGmail()
    #expect(m.path == [.result])
    #expect(mailbox.gmailOffer == nil)
    #expect(finished == 0)
    // "Continue" doesn't wait for the import.
    m.afterResult()
    #expect(finished == 1 && closed == 0)
  }

  @Test func reconnectingGmailIsDoneOnceGoogleSaysYes() async {
    let (s, mailbox) = connectServices(.reconnect)
    var finished = 0
    let m = SetupModel.connectingGmail(.reconnect, services: s, onClose: {}, onFinished: { finished += 1 })
    #expect(m.connectTitle == "Reconnect Gmail")
    await m.connectGmail()
    #expect(finished == 1)
    #expect(m.path.isEmpty)
    #expect(mailbox.gmailOffer == nil)
  }

  @Test func connectingGmailWithNoBankStartsAtTheBank() async {
    let (s, _) = connectServices(.connect, banks: [])
    var closed = 0
    let m = SetupModel.connectingGmail(.connect, services: s, onClose: { closed += 1 }, onFinished: {})
    #expect(m.startsAtBank)
    await m.continueWithBanks()
    #expect((s.setup as? MockSetupAuthoring)?.banks == [.enbd, .dib])
    #expect(m.path == [.gmail])
    #expect(!m.gmailIsFirst)
    m.close()
    #expect(closed == 1)
  }

  /// Opened again during the scan (a reconnect cut short mid-scan): the result shows it.
  @Test func connectingGmailResumesAtTheResult() async throws {
    let (s, mailbox) = connectServices(.connect)
    try await mailbox.connectGmail(banks: [.enbd])
    let m = SetupModel.connectingGmail(.connect, services: s, onClose: {}, onFinished: {})
    await m.openConnect()
    #expect(m.path == [.result])
    for _ in 0..<400 where !m.scanDone { try await Task.sleep(for: .milliseconds(10)) }
    #expect(m.summary?.total == 268)
  }
}
