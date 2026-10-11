// The plaintext refusal's one predicate (spec 01 §8.1): the same eight checks,
// in the same order and with the same names, as Go's `blob.LooksSealed`, `02`
// §11.2 and the SQL `hasala_frame_is_sealed`. The first failing check names
// the refusal; `nil` means the bytes look sealed.
//
// The server cannot prove bytes are ciphertext; this refuses every shape a
// buggy or legacy client would produce. On honest ciphertext only check 8
// (a cleartext gzip header in the region) can fire, with probability 2^-24, and
// the sealer re-seals once when it does (§6.5 step 9).
import CoreWire
import Foundation

public enum LooksSealedCheck: String, Sendable, Hashable, CaseIterable {
  case bucket
  case version
  case epoch
  case aadLen = "aad_len"
  case nonce
  case tag
  case tail
  case gzip
}

public enum LooksSealed {
  public static func check(_ frame: some DataProtocol) -> LooksSealedCheck? {
    let b = [UInt8](frame)
    let n = b.count
    // 1 bucket: n ∈ Buckets.
    guard FrameV3.isBucket(n) else { return .bucket }
    // 2 version.
    guard b[0] == FrameV3.version else { return .version }
    // 3 epoch: 1 ≤ e ≤ 2^31-1, i.e. b[1] < 0x80 and b[1:5] ≠ 0^4 (N-01).
    guard b[1] < 0x80, b[1..<5].contains(where: { $0 != 0 }) else { return .epoch }
    // 4 aad_len: L + 67 ≤ n keeps check 7's window inside R.
    let l = Int(b[5]) << 8 | Int(b[6])
    guard l + 67 <= n else { return .aadLen }
    // 5 nonce ≠ 0^12.
    guard b[(7 + l)..<(19 + l)].contains(where: { $0 != 0 }) else { return .nonce }
    // 6 tag ≠ 0^16.
    guard b[(n - 16)..<n].contains(where: { $0 != 0 }) else { return .tag }
    // 7 tail: the last 32 bytes of the ciphertext region ≠ 0^32.
    guard b[(n - 48)..<(n - 16)].contains(where: { $0 != 0 }) else { return .tail }
    // 8 gzip: R[4:7] is not a cleartext gzip header.
    guard !(b[23 + l] == 0x1f && b[24 + l] == 0x8b && b[25 + l] == 0x08) else { return .gzip }
    return nil
  }
}
