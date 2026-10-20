// Frame v3 seal and open (spec 01 §6.3-§6.6).
//
//   R      = u32be(m) ‖ gzip(plaintext) ‖ 0x00^(|R| − 4 − m)
//   header = 0x03 ‖ u32be(e) ‖ u16be(L) ‖ aad
//   AD     = "hasala/v1/blob" ‖ 0x00 ‖ header ‖ prev_hash          (prev_hash = 0^32 at counter 1)
//   K_blob = HKDF(K_e, nonce, "hasala/v1/blob-key" ‖ 0x00 ‖ SHA256(AD))
//   frame  = header ‖ nonce ‖ AES-256-GCM(K_blob, nonce, R, AD)    (ct ‖ tag), exactly one bucket
//
// The AD binds the whole cleartext header and the chain predecessor, so a blob
// opens only at its position, under its epoch, after its exact predecessor
// (C1). Only `Sealer` constructs a `SealedFrame` (spec 04 §2.4 R4).
import CorePrimitives
import CoreWire
import Foundation

/// A data key `K_e` and its epoch.
///
/// `@unchecked Sendable`: `key` is shared mutable memory, so `key.wipe()` zeroes
/// it for every holder. Wipe only once no other task can still seal or open
/// with it (no lock guards it; a wipe racing a seal is a data race).
public final class EpochKey: @unchecked Sendable {
  public let epoch: UInt32
  public let key: SecureBytes

  public init(epoch: UInt32, key: some ContiguousBytes) throws(PrimitivesError) {
    guard FrameV3.isValidEpoch(epoch) else {
      throw .invalidLength(what: "key epoch", expected: "1...2147483647", got: Int(epoch))
    }
    try KeyDerivation.requireLength(key, 32, "epoch key")
    self.epoch = epoch
    self.key = SecureBytes(copying: key)
  }

  /// `K_1` of an unlocked body.
  public static func first(body: KeyBody, userID: UserID) throws(PrimitivesError) -> EpochKey {
    try EpochKey(epoch: 1, key: try body.epochKey1(userID: userID))
  }
}

public enum SealError: Error, Equatable, Sendable {
  /// The envelope or epoch is unusable: a programming error (§6.5 step 1).
  case invalidEnvelope(String)
  /// The plaintext exceeds 2 MiB, or its gzip fits no bucket: split the batch.
  case tooLarge
  /// `LooksSealed` refused two fresh seals in a row (§6.5 step 9): latch
  /// `sealer_fault` (04 §5.5).
  case sealerFault
  case primitive(PrimitivesError)
  case gzip(GzipError)
}

/// A frame only `Sealer` can make: the bytes the server will store and their
/// chain hash. Persist it whole in the in-flight record (R-OUT-2); a resend uses
/// these exact bytes (R-OUT-3).
public struct SealedFrame: Sendable, Hashable {
  public let bytes: Data
  public let blobHash: Hash32
  public let epoch: UInt32
  public let counter: Int64
  public let prevHash: Hash32

  /// Re-runs `LooksSealed` in every build (R4); the sealer checked already, so a
  /// failure here is a bug and traps.
  fileprivate init(bytes: Data, blobHash: Hash32, epoch: UInt32, counter: Int64, prevHash: Hash32) {
    precondition(LooksSealed.check(bytes) == nil, "SealedFrame built from bytes LooksSealed refuses")
    self.bytes = bytes
    self.blobHash = blobHash
    self.epoch = epoch
    self.counter = counter
    self.prevHash = prevHash
  }
}

public struct Sealer: Sendable {
  public let epoch: UInt32
  public let key: EpochKey

  /// `epoch` is the device's `epoch_hwm`; the key must be that epoch's.
  public init(epoch: UInt32, key: EpochKey) {
    self.epoch = epoch
    self.key = key
  }

  /// §6.5: seals an op-blob plaintext at `envelope` after `prevHash`.
  public func seal(plaintextOps: Data, envelope: Envelope, prevHash: Hash32, random: some RandomSource)
    throws(SealError) -> SealedFrame
  {
    guard FrameV3.isValidEpoch(epoch), key.epoch == epoch else {
      throw .invalidEnvelope("the key is for epoch \(key.epoch), the seal is at \(epoch)")
    }
    guard plaintextOps.count <= FrameV3.maxPlaintext else { throw .tooLarge }
    let g: Data
    do { g = try Gzip.compress(plaintextOps) } catch { throw .gzip(error) }
    let aad = envelope.aad
    guard let bucket = FrameV3.bucket(for: FrameV3.overhead(aadLength: aad.count) + g.count) else { throw .tooLarge }
    let header = FrameV3.header(epoch: epoch, aad: aad)
    let regionLength = bucket - 35 - aad.count
    var region = Data(count: regionLength)
    region[0] = UInt8(g.count >> 24 & 0xff)
    region[1] = UInt8(g.count >> 16 & 0xff)
    region[2] = UInt8(g.count >> 8 & 0xff)
    region[3] = UInt8(g.count & 0xff)
    region.replaceSubrange(4..<(4 + g.count), with: g)

    for _ in 0..<2 {
      let nonce: Data
      do { nonce = try random.bytes(FrameV3.nonceSize) } catch { throw .primitive(error) }
      let frame: Data
      do {
        frame = try FrameAEAD.seal(region: region, header: header, prevHash: prevHash, epochKey: key.key, nonce: nonce)
      } catch {
        throw .primitive(error)
      }
      guard frame.count == bucket else { throw .invalidEnvelope("frame is \(frame.count) bytes, bucket \(bucket)") }
      if LooksSealed.check(frame) == nil {
        return SealedFrame(
          bytes: frame, blobHash: Chain.hash(prev: prevHash, frame: frame), epoch: epoch, counter: envelope.counter,
          prevHash: prevHash)
      }
    }
    throw .sealerFault
  }
}

/// The AEAD layer of a v3 frame, separate from compression (`frame-aead.json`).
package enum FrameAEAD {
  /// `"hasala/v1/blob" ‖ 0x00 ‖ header ‖ prev_hash`.
  package static func associatedData(header: some DataProtocol, prevHash: Hash32) -> Data {
    Domain.blob.prefix + Data(header) + prevHash.bytes
  }

  /// `header ‖ nonce ‖ AES-256-GCM(K_blob, nonce, R, AD)` for a supplied `R`.
  package static func seal(
    region: Data, header: Data, prevHash: Hash32, epochKey: some ContiguousBytes, nonce: Data
  ) throws(PrimitivesError) -> Data {
    guard nonce.count == FrameV3.nonceSize, nonce.contains(where: { $0 != 0 }) else {
      throw .invalidLength(what: "frame nonce", expected: "12 non-zero bytes", got: nonce.count)
    }
    let ad = associatedData(header: header, prevHash: prevHash)
    let kBlob = try KeyDerivation.blobKey(epochKey: epochKey, nonce: nonce, associatedData: ad)
    return header + nonce + (try AESGCM.seal(key: kBlob, nonce: nonce, aad: ad, plaintext: region))
  }

  /// `R` of a frame whose header has been checked, or `nil` when AEAD fails.
  package static func open(_ frame: [UInt8], layout: FrameV3.Layout, prevHash: Hash32, epochKey: some ContiguousBytes)
    -> Data?
  {
    let header = Data(frame[layout.header])
    let nonce = Data(frame[layout.nonce])
    let ad = associatedData(header: header, prevHash: prevHash)
    guard let kBlob = try? KeyDerivation.blobKey(epochKey: epochKey, nonce: nonce, associatedData: ad) else { return nil }
    return try? AESGCM.open(
      key: kBlob, nonce: nonce, aad: ad, sealed: Data(frame[layout.region.lowerBound..<layout.tag.upperBound]))
  }
}

/// What the reader decided for one frame (§6.6 R3-R9).
public enum OpenOutcome: Sendable, Hashable {
  /// The op-blob plaintext (decode it with `OpCodec.decodeR10`).
  case opened(Data)
  case hardStop(ReaderHardStop)
  /// R4: the frame's epoch is above `epoch_hwm`. Re-read `GET /keys` once and
  /// call again with `serverEpoch`.
  case refreshEpoch(UInt32)
  /// R6: no key for this epoch: enter `needsUnlock`; stop the page here and do
  /// not advance the cursor.
  case needsUnlock(epoch: UInt32)
  /// R7-R9: set aside, the cursor advances; `alarm` raises the integrity alarm.
  case setAside(SetAsideReason, alarm: Bool)
}

/// The reader's R3-R9 for frames that passed R0-R2b.
public struct Opener: Sendable {
  public let epochHWM: UInt32
  public let keys: [UInt32: EpochKey]

  public init(epochHWM: UInt32, keys: [EpochKey]) {
    self.epochHWM = epochHWM
    var d: [UInt32: EpochKey] = [:]
    for k in keys { d[k.epoch] = k }
    self.keys = d
  }

  /// Opens `frame` expected at `envelope` after `prevHash`. `serverEpoch` is
  /// the `current_epoch` of a fresh `GET /keys`, passed only after
  /// ``OpenOutcome/refreshEpoch(_:)``.
  public func open(_ frame: Data, envelope: Envelope, prevHash: Hash32, serverEpoch: UInt32? = nil) -> OpenOutcome {
    let b = [UInt8](frame)
    let n = b.count
    // Shape (R0 checks the bucket; repeated so the opener never indexes past the end).
    guard FrameV3.isBucket(n) else { return .hardStop(.tampered(.rowShape)) }
    // R3: the version.
    if b[0] > FrameV3.version { return .hardStop(.updateRequired) }
    guard b[0] == FrameV3.version, let h = FrameV3.parseHeader(b) else { return .hardStop(.tampered(.legacyFrame)) }
    // R4: the aad_len bound and the epoch.
    guard h.aadLength + 67 <= n, FrameV3.isValidEpoch(h.epoch) else { return .hardStop(.tampered(.badHeader)) }
    if h.epoch > epochHWM {
      guard let serverEpoch else { return .refreshEpoch(h.epoch) }
      guard serverEpoch >= h.epoch else { return .hardStop(.tampered(.epochInvalid)) }
    }
    // R5: the embedded AAD is the expected position, compared in constant time.
    let layout = FrameV3.Layout(aadLength: h.aadLength, frameLength: n)
    guard constantTimeEquals(Data(b[layout.aad]), envelope.aad) else { return .hardStop(.tampered(.aadMismatch)) }
    // R6: the key.
    guard let key = keys[h.epoch] else { return .needsUnlock(epoch: h.epoch) }
    // R7: AEAD.
    guard let region = FrameAEAD.open(b, layout: layout, prevHash: prevHash, epochKey: key.key) else {
      return .setAside(.aeadFailed, alarm: true)
    }
    // R8: m ≤ |R| − 4.
    let r = [UInt8](region)
    let m = Int(r[0]) << 24 | Int(r[1]) << 16 | Int(r[2]) << 8 | Int(r[3])
    guard m <= r.count - 4 else { return .setAside(.regionMalformed, alarm: false) }
    // R9: one gzip member, CRC and ISIZE verified, no trailing bytes, ≤ 2 MiB.
    guard let plaintext = try? Gzip.decompress(r[4..<(4 + m)], maxOutputBytes: FrameV3.maxPlaintext) else {
      return .setAside(.payloadInvalid, alarm: false)
    }
    return .opened(plaintext)
  }
}
