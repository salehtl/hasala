import CoreMailbox
import CoreTestSupport
import CoreTime
import Foundation
import Synchronization
import Testing

@Suite struct GrantEndTokenTests {
  final class UnreadableTokenStore: MailRefreshTokenStore {
    let deletes = Mutex(0)

    func read() throws(SecretUnavailable) -> String? { throw SecretUnavailable() }
    func write(_ token: String) throws(SecretUnavailable) {}
    func delete() throws(SecretUnavailable) { deletes.withLock { $0 += 1 } }
  }

  func provider(_ g: FakeGmail, _ store: any MailRefreshTokenStore) -> RefreshingGmailTokenProvider {
    RefreshingGmailTokenProvider(
      oauth: GoogleOAuthClient(config: GmailOAuthConfig(clientID: "c", redirectScheme: "s"), http: g), store: store, clock: ManualClock(0))
  }

  @Test func aGrantThisIPhoneStopsUsingIsDeletedEvenWhenItCannotBeRead() async {
    let g = FakeGmail()
    let store = UnreadableTokenStore()

    let revoked = await provider(g, store).revokeAndForget(keepOnFailure: false)

    #expect(!revoked)
    #expect(store.deletes.withLock { $0 } == 1)
    #expect(g.requests.isEmpty)
  }

  @Test func aDisconnectKeepsATokenItCouldNotRead() async {
    let store = UnreadableTokenStore()

    let revoked = await provider(FakeGmail(), store).revokeAndForget()

    #expect(!revoked)
    #expect(store.deletes.withLock { $0 } == 0)
  }

  @Test func aGrantThisIPhoneStopsUsingIsDeletedWhenTheRevokeFails() async throws {
    let g = FakeGmail()
    g.fail("/revoke", with: [503])
    let store = MemoryGmailRefreshTokenStore(token: "fake-refresh-token")

    let revoked = await provider(g, store).revokeAndForget(keepOnFailure: false)

    #expect(revoked)
    #expect(try store.read() == nil)
  }
}
