import CryptoKit
import Foundation
import HasalaDesign

nonisolated enum Gravatar {
  static let headers = ["User-Agent": "Mozilla/5.0", "Accept": "image/*", "Accept-Language": "*"]

  static func hash(email: String) -> String {
    let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  static func url(email: String, pixels: Int) -> URL? {
    var parts = URLComponents()
    parts.scheme = "https"
    parts.host = "gravatar.com"
    parts.path = "/avatar/\(hash(email: email))"
    parts.queryItems = [
      URLQueryItem(name: "s", value: String(min(max(pixels, 1), 2048))),
      URLQueryItem(name: "d", value: "404"),
    ]
    return parts.url
  }

  static func request(email: String, pixels: Int) -> URLRequest? {
    guard let url = url(email: email, pixels: pixels) else { return nil }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
    request.httpShouldHandleCookies = false
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    return request
  }

  static func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.waitsForConnectivity = false
    configuration.httpAdditionalHeaders = headers
    return URLSession(configuration: configuration)
  }
}

actor GravatarLoader {
  static let maxAge: TimeInterval = 24 * 60 * 60

  static let shared = GravatarLoader(
    directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
      .appendingPathComponent("gravatar", isDirectory: true),
    session: Gravatar.session())

  private struct Entry {
    let storedAt: Date
    let data: Data?
  }

  private enum Outcome: Sendable {
    case found(Data)
    case missing
    case failed
  }

  private let directory: URL?
  private let session: URLSession
  private let now: @Sendable () -> Date
  private var memory: [String: Entry] = [:]
  private var inFlight: [String: Task<Outcome, Never>] = [:]

  init(directory: URL?, session: URLSession, now: @escaping @Sendable () -> Date = { Date() }) {
    self.directory = directory
    self.session = session
    self.now = now
  }

  nonisolated var provider: AvatarPictureProvider {
    AvatarPictureProvider { email, pixels in await self.picture(email: email, pixels: pixels) }
  }

  func picture(email: String, pixels: Int) async -> Data? {
    let key = "\(Gravatar.hash(email: email))-\(pixels)"
    if let entry = fresh(key) { return entry.data }
    guard let request = Gravatar.request(email: email, pixels: pixels) else { return nil }
    let task: Task<Outcome, Never>
    if let running = inFlight[key] {
      task = running
    } else {
      task = Task { [session] in
        guard let (data, response) = try? await session.data(for: request),
          let http = response as? HTTPURLResponse
        else { return .failed }
        switch http.statusCode {
        case 200 where !data.isEmpty: return .found(data)
        case 404: return .missing
        default: return .failed
        }
      }
      inFlight[key] = task
    }
    let outcome = await task.value
    inFlight[key] = nil
    switch outcome {
    case .found(let data):
      store(key, data)
      return data
    case .missing:
      store(key, nil)
      return nil
    case .failed:
      return (memory[key] ?? readFile(key))?.data
    }
  }

  private func fresh(_ key: String) -> Entry? {
    if let entry = memory[key], now().timeIntervalSince(entry.storedAt) < Self.maxAge { return entry }
    if let entry = readFile(key), now().timeIntervalSince(entry.storedAt) < Self.maxAge {
      memory[key] = entry
      return entry
    }
    return nil
  }

  private func store(_ key: String, _ data: Data?) {
    let entry = Entry(storedAt: now(), data: data)
    memory[key] = entry
    guard let directory else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var bytes = Data()
    withUnsafeBytes(of: entry.storedAt.timeIntervalSince1970.bitPattern.bigEndian) { bytes.append(contentsOf: $0) }
    bytes.append(data == nil ? 0 : 1)
    bytes.append(data ?? Data())
    try? bytes.write(to: directory.appendingPathComponent(key), options: .atomic)
  }

  private func readFile(_ key: String) -> Entry? {
    guard let directory, let bytes = try? Data(contentsOf: directory.appendingPathComponent(key)),
      bytes.count >= 9
    else { return nil }
    let bits = bytes.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    let storedAt = Date(timeIntervalSince1970: Double(bitPattern: bits))
    let found = bytes[bytes.startIndex + 8] == 1
    return Entry(storedAt: storedAt, data: found ? Data(bytes.dropFirst(9)) : nil)
  }
}
