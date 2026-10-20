import Foundation

public struct CloudRequest: Sendable, Equatable {
  public var url: URL
  public var method: String
  public var headers: [String: String]
  public var body: Data

  public init(url: URL, method: String, headers: [String: String], body: Data) {
    self.url = url
    self.method = method
    self.headers = headers
    self.body = body
  }
}

public struct CloudResponse: Sendable, Equatable {
  public var status: Int
  public var body: Data

  public init(status: Int, body: Data = Data()) {
    self.status = status
    self.body = body
  }
}

public enum CloudExchangeError: Error, Sendable, Equatable {
  case timedOut
  case cancelled
  case transport
}

public protocol CloudHTTPExchange: Sendable {
  func send(_ request: CloudRequest) async throws(CloudExchangeError) -> CloudResponse
}

public final class URLSessionCloudExchange: CloudHTTPExchange {
  let session: URLSession

  public init(timeout: TimeInterval = 10) {
    let c = URLSessionConfiguration.ephemeral
    c.httpCookieStorage = nil
    c.httpShouldSetCookies = false
    c.httpCookieAcceptPolicy = .never
    c.urlCache = nil
    c.urlCredentialStorage = nil
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.timeoutIntervalForRequest = timeout
    c.timeoutIntervalForResource = timeout
    c.waitsForConnectivity = false
    c.httpAdditionalHeaders = nil
    session = URLSession(configuration: c)
  }

  public func send(_ request: CloudRequest) async throws(CloudExchangeError) -> CloudResponse {
    var r = URLRequest(url: request.url)
    r.httpMethod = request.method
    r.httpShouldHandleCookies = false
    r.cachePolicy = .reloadIgnoringLocalCacheData
    for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
    r.httpBody = request.body
    do {
      let (data, response) = try await session.data(for: r)
      guard let http = response as? HTTPURLResponse else { throw CloudExchangeError.transport }
      return CloudResponse(status: http.statusCode, body: data)
    } catch let e as CloudExchangeError {
      throw e
    } catch is CancellationError {
      throw .cancelled
    } catch let e as URLError where e.code == .cancelled {
      throw .cancelled
    } catch let e as URLError where e.code == .timedOut {
      throw .timedOut
    } catch {
      throw .transport
    }
  }
}
