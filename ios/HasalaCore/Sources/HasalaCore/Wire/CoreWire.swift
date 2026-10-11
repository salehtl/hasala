// CoreWire (Wire/), spec 04 §2.2. Owner: WS-9.
//
// The op model and its envelope codec (schema 4; `Op.swift`, `OpCodec.swift`,
// `Checkpoint.swift`), the read-only v1 frame and cold-record readers for the
// ledgerd fixtures (`FrameV1Reader.swift`, `RawBody.swift`), the frame v3 layout
// and envelope (`FrameV3.swift`), the hash chain (`Chain.swift`), and the
// row-level reader checks R0 and R2b of spec 01 §6.6 (`RowShape.swift`,
// `HeadCheck.swift`).
//
// Byte-exact module (spec 04 §2.4 R2). Everything that needs a key lives in
// CoreCrypto; this module hashes and verifies only.
