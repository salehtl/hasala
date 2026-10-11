// The sync routes (`02` #28–#30, §11): ledgerd's `Row` and `UploadBlob` field
// names, blobs in standard base64, hashes in hex, counters and seqs as decimal
// strings; `Row.head_sig` is b64 or null, and one upload carries one `head_sig`.
@_exported import CoreAuth
import CorePrimitives
import CoreWire
import Foundation

public struct PullRow: Codable, Sendable, Hashable {
  public let seq: String
  public let stream: String
  public let writer_id: String
  public let writer_counter: String
  public let type_flag: String
  public let size_bucket: Int
  public let blob_hash: String
  public let prev_hash: String
  public let created_at: String
  public let blob: String
  public let head_sig: String?

  public init(
    seq: String, stream: String, writer_id: String, writer_counter: String, type_flag: String, size_bucket: Int,
    blob_hash: String, prev_hash: String, created_at: String, blob: String, head_sig: String?
  ) {
    self.seq = seq
    self.stream = stream
    self.writer_id = writer_id
    self.writer_counter = writer_counter
    self.type_flag = type_flag
    self.size_bucket = size_bucket
    self.blob_hash = blob_hash
    self.prev_hash = prev_hash
    self.created_at = created_at
    self.blob = blob
    self.head_sig = head_sig
  }
}

public struct PullPage: Codable, Sendable, Hashable {
  public let stream: String
  public let rows: [PullRow]
  public let next: String
  public let complete: Bool

  public init(stream: String, rows: [PullRow], next: String, complete: Bool) {
    self.stream = stream
    self.rows = rows
    self.next = next
    self.complete = complete
  }
}

public struct HashEntry: Codable, Sendable, Hashable {
  public let seq: String
  public let writer_id: String
  public let writer_counter: String
  public let blob_hash: String
  public let prev_hash: String

  public init(seq: String, writer_id: String, writer_counter: String, blob_hash: String, prev_hash: String) {
    self.seq = seq
    self.writer_id = writer_id
    self.writer_counter = writer_counter
    self.blob_hash = blob_hash
    self.prev_hash = prev_hash
  }
}

public struct HashesPage: Codable, Sendable, Hashable {
  public let stream: String
  public let hashes: [HashEntry]
  public let next: String
  public let complete: Bool

  public init(stream: String, hashes: [HashEntry], next: String, complete: Bool) {
    self.stream = stream
    self.hashes = hashes
    self.next = next
    self.complete = complete
  }
}

public struct UploadBlobJSON: Codable, Sendable, Hashable {
  public let writer_counter: String
  public let prev_hash: String
  public let blob_hash: String
  public let type_flag: String
  public let size_bucket: Int
  public let blob: String

  public init(_ b: InflightBlobWire) {
    writer_counter = String(b.counter)
    prev_hash = b.prevHash.hex
    blob_hash = b.blobHash.hex
    type_flag = "edit"
    size_bucket = b.sizeBucket
    blob = Base64.encode(b.blob)
  }
}

/// The fields of one in-flight blob the upload needs.
public struct InflightBlobWire: Sendable, Hashable {
  public let counter: Int64
  public let prevHash: Hash32
  public let blobHash: Hash32
  public let sizeBucket: Int
  public let blob: Data

  public init(counter: Int64, prevHash: Hash32, blobHash: Hash32, sizeBucket: Int, blob: Data) {
    self.counter = counter
    self.prevHash = prevHash
    self.blobHash = blobHash
    self.sizeBucket = sizeBucket
    self.blob = blob
  }
}

public struct UploadRequest: Codable, Sendable, Hashable {
  public let writer_id: String
  public let stream: String
  public let blobs: [UploadBlobJSON]
  public let head_sig: String

  public init(writerID: WriterID, blobs: [InflightBlobWire], headSig: Data) {
    writer_id = writerID.string
    stream = "hot"
    self.blobs = blobs.map(UploadBlobJSON.init)
    head_sig = Base64.encode(headSig)
  }
}

public struct UploadResponse: Codable, Sendable, Hashable {
  public let seqs: [String]
  public init(seqs: [String]) { self.seqs = seqs }
}

/// The `conflict` detail the server pins verbatim (`02` §6.3).
public let partiallyAppliedDetail = "read the chain head and resend only the rows above it"

extension AuthClient {
  public func pull(after: Int64, limit: Int = 500, bearer: String) async throws(APIError) -> PullPage {
    try await api.call(.get, "/api/v1/sync?stream=hot&after=\(after)&limit=\(limit)", bearer: bearer)
  }

  public func hashes(after: Int64, limit: Int = 1000, bearer: String) async throws(APIError) -> HashesPage {
    try await api.call(.get, "/api/v1/sync/hashes?stream=hot&after=\(after)&limit=\(limit)", bearer: bearer)
  }

  /// `POST /api/v1/sync`, raw: the push applies §5.5's table to the status.
  public func upload(_ r: UploadRequest, bearer: String) async throws(APIError) -> APIResponse {
    try await api.send(APIRequest(method: .post, path: "/api/v1/sync", body: try APIClient.encode(r), bearer: bearer))
  }
}
