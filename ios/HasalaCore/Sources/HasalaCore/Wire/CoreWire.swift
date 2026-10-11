// CoreWire (Wire/), spec 04 §2.2. Owner: WS-9.
//
// The op model and its envelope codec (schema 4; `Op.swift`, `OpCodec.swift`,
// `Checkpoint.swift`), the read-only v1 frame and raw-body readers for the
// ledgerd fixtures (`FrameV1Reader.swift`), the frame v3 layout and envelope
// (`FrameV3.swift`), the hash chain (`Chain.swift`), the row-level reader check
// R0 of spec 01 §6.6 (`RowShape.swift`) and the reader's outcome types
// (`ReaderOutcome.swift`).
//
// Deviation from spec 01 §12.1 / 04 §2.2: `HeadCheck` (R2b) lives in CoreCrypto
// (`Crypto/DeviceKeys.swift`), not here. It builds `HeadMessage`, which is
// `SigningMessages` (§10.1, CoreCrypto by the same table), and CoreWire may not
// import CoreCrypto; keeping one builder of every signed byte string outranks
// the module placement.
//
// Byte-exact module (spec 04 §2.4 R2). Everything that needs a key lives in
// CoreCrypto; this module hashes and verifies only.
