// The auth, account, key and writer routes of `02` §7 (spec 04 §20.1), one
// method each. Paths and bodies are `02`'s; the bytes inside are built by the
// caller (CoreSync's ceremonies, over CoreCrypto). Every method throws
// `APIError`, so each ceremony maps `refused(...)` with its own table (spec 04
// §6.1.5).
import Foundation

public struct AuthClient: Sendable {
  public let api: APIClient

  public init(transport: any Transport) { api = APIClient(transport: transport) }
  public init(api: APIClient) { self.api = api }

  // MARK: Meta (#2)

  public func meta() async throws(APIError) -> MetaResponse {
    try await api.call(.get, "/api/v1/meta")
  }

  // MARK: Signup (#43, #44) and creation (#3, #4, #45)

  public func signupBegin(_ r: SignupBeginRequest) async throws(APIError) -> SignupBeginResponse {
    try await api.call(.post, "/api/v1/auth/signup/begin", json: r)
  }

  public func signupVerify(signupID: String, code: String) async throws(APIError) {
    let _: Empty = try await api.call(
      .post, "/api/v1/auth/signup/verify", json: SignupVerifyRequest(signupID: signupID, code: code))
  }

  public func registerBegin(_ r: RegisterBeginRequest) async throws(APIError) -> RegisterBeginResponse {
    try await api.call(.post, "/api/v1/auth/passkey/register/begin", json: r)
  }

  public func registerFinish(_ r: RegisterFinishRequest) async throws(APIError) -> SessionGrant {
    try await api.call(.post, "/api/v1/auth/passkey/register/finish", json: r)
  }

  public func passwordRegister(_ r: PasswordRegisterRequest) async throws(APIError) -> SessionGrant {
    try await api.call(.post, "/api/v1/auth/password/register", json: r)
  }

  // MARK: Sign-in (#5, #6, #46, #47)

  public func loginBegin() async throws(APIError) -> LoginBeginResponse {
    try await api.call(.post, "/api/v1/auth/passkey/login/begin", json: Empty())
  }

  public func loginFinish(_ r: LoginFinishRequest) async throws(APIError) -> SessionGrant {
    try await api.call(.post, "/api/v1/auth/passkey/login/finish", json: r)
  }

  public func passwordLoginBegin(email: String) async throws(APIError) -> PasswordLoginBeginResponse {
    try await api.call(.post, "/api/v1/auth/password/login/begin", json: EmailRequest(email: email))
  }

  public func passwordLoginFinish(_ r: PasswordLoginFinishRequest) async throws(APIError) -> SessionGrant {
    try await api.call(.post, "/api/v1/auth/password/login/finish", json: r)
  }

  // MARK: Passkey add (#10, #11)

  public func passkeyAddBegin(_ r: PasskeyAddBeginRequest, bearer: String) async throws(APIError)
    -> PasskeyAddBeginResponse
  {
    try await api.call(.post, "/api/v1/auth/passkey/add/begin", json: r, bearer: bearer)
  }

  public func passkeyAddFinish(_ r: PasskeyAddFinishRequest, bearer: String) async throws(APIError)
    -> PasskeyAddResponse
  {
    try await api.call(.post, "/api/v1/auth/passkey/add/finish", json: r, bearer: bearer)
  }

  // MARK: Session (#9, #14, #15)

  public func stepUpBegin(_ r: StepUpBeginRequest, bearer: String) async throws(APIError) -> StepUpBeginResponse {
    try await api.call(.post, "/api/v1/auth/step-up/begin", json: r, bearer: bearer)
  }

  public func session(bearer: String) async throws(APIError) -> SessionInfo {
    try await api.call(.get, "/api/v1/auth/session", bearer: bearer)
  }

  /// `POST /auth/logout` (#15). Spec 04 §4.7 row 1: called BEFORE the session
  /// item is deleted; `204` and `401` both mean "signed out".
  public func logout(bearer: String) async throws(APIError) {
    let _: Empty = try await api.call(.post, "/api/v1/auth/logout", json: Empty(), bearer: bearer)
  }

  // MARK: Account (#40)

  public func account(bearer: String) async throws(APIError) -> AccountInfo {
    try await api.call(.get, "/api/v1/account", bearer: bearer)
  }

  public func phraseSeen(bearer: String) async throws(APIError) {
    let _: Empty = try await api.call(.post, "/api/v1/keys/phrase/seen", json: Empty(), bearer: bearer)
  }

  // MARK: Keys (#17, #18, #19)

  public func keys(bearer: String) async throws(APIError) -> KeysResponse {
    try await api.call(.get, "/api/v1/keys", bearer: bearer)
  }

  public func bootstrap(_ body: BootstrapBody, bearer: String) async throws(APIError) -> BootstrapResponse {
    try await api.call(.post, "/api/v1/account/bootstrap", json: body, bearer: bearer)
  }

  public func keyWraps(bearer: String) async throws(APIError) -> KeyWrapsResponse {
    try await api.call(.get, "/api/v1/keys/wraps", bearer: bearer)
  }

  // MARK: Writers (#23, #24, #26, #27)

  public func writerChallenge(bearer: String) async throws(APIError) -> WriterChallengeResponse {
    try await api.call(.post, "/api/v1/writers/challenge", json: Empty(), bearer: bearer)
  }

  public func writerRegister(_ r: WriterRegisterRequest, bearer: String) async throws(APIError) -> WriterIDResponse {
    try await api.call(.post, "/api/v1/writers/register", json: r, bearer: bearer)
  }

  public func writers(bearer: String) async throws(APIError) -> WritersResponse {
    try await api.call(.get, "/api/v1/writers", bearer: bearer)
  }

  public func keyHistory(bearer: String) async throws(APIError) -> KeyHistoryResponse {
    try await api.call(.get, "/api/v1/key-history", bearer: bearer)
  }

  // MARK: Device removal (#25) and deletion (#41)

  public func writerRevoke(_ r: WriterRevokeRequest, bearer: String) async throws(APIError) {
    let _: Empty = try await api.call(.post, "/api/v1/writers/revoke", json: r, bearer: bearer)
  }

  public func deleteAccount(_ r: DeleteAccountRequest, bearer: String) async throws(APIError) {
    let _: Empty = try await api.call(.delete, "/api/v1/account", json: r, bearer: bearer)
  }
}
