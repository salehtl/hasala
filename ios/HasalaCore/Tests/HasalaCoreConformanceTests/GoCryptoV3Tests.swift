// conformance/crypto-v3 (Go-written, WS-2): Swift must pass every file
// (spec 01 §15.2 step 1). The suite is disabled, by name, until the directory
// exists in this checkout; it lands with the Go vector generator.
import CoreCrypto
import CoreJSON
import CorePrimitives
import CoreWire
import Foundation
import Testing

enum GoVectors {
  static let present = FileManager.default.fileExists(
    atPath: Fixtures.conformanceRoot.appendingPathComponent("crypto-v3/manifest.json").path)
  static func load(_ name: String) throws -> JSONValue { try Fixtures.json("crypto-v3/" + name) }
  static func hex(_ v: JSONValue?) throws -> Data {
    guard let s = v?.stringValue else { throw FixtureError.missing("hex") }
    return try Hex.decode(s)
  }
}

@Suite("conformance/crypto-v3 (Go)", .enabled(if: GoVectors.present, "conformance/crypto-v3 is not in this checkout"))
struct GoCryptoV3Tests {
  typealias G = GoVectors

  @Test("manifest: the domain registry is ours, row for row (AT-X3)")
  func manifest() throws {
    let m = try G.load("manifest.json")
    let domains = try m.array("domains")
    #expect(domains.count == Domain.allCases.count)
    for (d, mine) in zip(domains, Domain.allCases) { #expect(d["string"]?.stringValue == mine.rawValue) }
  }

  @Test("phrase.json: published vectors, round trips, normalization and every error")
  func phrase() throws {
    let m = try G.load("phrase.json")
    for v in try m.array("published") + m.array("round_trip") {
      let e = try G.hex(v["entropy"])
      #expect(try Phrase.words(entropy: e).joined(separator: " ") == (try v.string("words")))
      #expect(try Phrase.entropy(typed: try v.string("words")).data == e)
    }
    for c in try m.array("cases") {
      let input = try c.string("input")
      let name = try c.string("name")
      #expect(Phrase.normalize(input) == (try c.array("normalized")).map { $0.stringValue ?? "" }, "\(name)")
      if let e = c["entropy"]?.stringValue {
        #expect(try Phrase.entropy(typed: input).data == (try Hex.decode(e)), "\(name)")
        continue
      }
      let err = try #require(c["error"])
      let want: PhraseError
      switch try err.string("kind") {
      case "length": want = .length(count: try err.int("count"))
      case "unknownWord": want = .unknownWord(index: try err.int("index"), word: try err.string("word"))
      default: want = .checksum
      }
      #expect(throws: want, "\(name)") { try Phrase.entropy(typed: input) }
    }
  }

  @Test("derive.json: every derivation set and blob key")
  func derive() throws {
    let m = try G.load("derive.json")
    #expect(Hex.encode(KeyDerivation.prfSalt) == (try m.string("prf_salt_unlock")))
    for s in try m.array("sets") {
      let user = try #require(UserID(try s.string("user_id")))
      let e = try G.hex(s["e"])
      let amk = try G.hex(s["amk"])
      #expect(try KeyDerivation.recoveryKeySeed(entropy: e).data == (try G.hex(s["rk_seed"])))
      #expect(try KeyDerivation.recoveryPublicKey(entropy: e) == (try G.hex(s["rk_pub"])))
      #expect(try KeyDerivation.recoveryWrapKey(entropy: e, salt: try G.hex(s["recovery_wrap_salt"])).data == (try G.hex(s["rwk"])))
      #expect(try KeyDerivation.prfWrapKey(prfOutput: try G.hex(s["p"]), salt: try G.hex(s["prf_wrap_salt"])).data == (try G.hex(s["pwk"])))
      #expect(try KeyDerivation.amkCommitment(amk: amk, userID: user) == (try G.hex(s["amk_commitment"])))
      if let k1 = s["k_1"] { #expect(try KeyDerivation.epochKey1(amk: amk, userID: user).data == (try G.hex(k1))) }
      if let kpv = s["k_pv"] { #expect(try KeyDerivation.phraseBoxKey(amk: amk, userID: user).data == (try G.hex(kpv))) }
      if let a = s["aak_pub"] { #expect(try Ed25519.publicKey(seed: try G.hex(s["aak_seed"])) == (try G.hex(a))) }
      if let d = s["dwk_pub"] { #expect(try Ed25519.publicKey(seed: try G.hex(s["dwk_seed"])) == (try G.hex(d))) }
    }
    for k in try m.array("blob_keys") {
      let ad = try G.hex(k["ad"])
      #expect(Hex.encode(sha256(ad)) == (try k.string("sha256_ad")))
      #expect(
        try KeyDerivation.blobKey(epochKey: try G.hex(k["k_e"]), nonce: try G.hex(k["nonce"]), associatedData: ad).data
          == (try G.hex(k["k_blob"])))
    }
  }

  static func published(_ c: JSONValue) throws -> PublishedAccountKeys {
    PublishedAccountKeys(
      userID: UserID(try c.string("user_id"))!, recoveryPublicKey: try G.hex(c["recovery_pubkey"]),
      amkCommitment: try G.hex(c["amk_commitment"]), authorityPublicKey: try G.hex(c["authority_pubkey"]))
  }

  @Test("wraps.json: wraps from fixed inputs, byte for byte; every W case's outcome")
  func wraps() throws {
    let m = try G.load("wraps.json")
    for w in try m.array("wraps") {
      let user = UserID(try w.string("user_id"))!
      let raw = try G.hex(w["body"])
      let body = try KeyBody(amk: raw[1..<33], aakSeed: raw[33..<65])
      let built: Data
      if try w.string("kind") == "recovery" {
        built = try Wrap.sealRecovery(
          body: body, entropy: try G.hex(w["secret"]), userID: user, salt: try G.hex(w["salt"]), nonce: try G.hex(w["nonce"]))
      } else {
        built = try Wrap.sealPRF(
          body: body, prfOutput: try G.hex(w["secret"]), userID: user, credentialID: try G.hex(w["credential_id"]),
          salt: try G.hex(w["salt"]), nonce: try G.hex(w["nonce"]))
      }
      #expect(built == (try G.hex(w["wrap"])), "\(w["name"].map { "\($0)" } ?? "")")
    }
    for c in try m.array("cases") {
      let label = "\(try c.string("id")) \(try c.string("name"))"
      let pub = try Self.published(c)
      let outcome: String
      do {
        let body: KeyBody
        if try c.string("kind") == "recovery" {
          body = try AccountUnlock.withPhrase(entropy: try G.hex(c["secret"]), recoveryWrap: try G.hex(c["wrap"]), published: pub)
        } else {
          body = try AccountUnlock.withPRF(
            prfOutput: try G.hex(c["secret"]), credentialID: try G.hex(c["credential_id"]), prfWrap: try G.hex(c["wrap"]),
            published: pub)
        }
        outcome = "opens"
        if let amk = c["amk"]?.stringValue { #expect(Hex.encode(body.amk.data) == amk, "\(label)") }
      } catch UnwrapError.accountKeysMismatch {
        outcome = "integrityAlarm(accountKeysMismatch)"
      } catch UnwrapError.phraseBoxMismatch {
        outcome = "integrityAlarm(phraseBoxMismatch)"
      } catch {
        outcome = "\(error)"
      }
      #expect(outcome == (try c.string("outcome")), "\(label)")
    }
  }

  @Test("phrase-box.json: boxes from fixed inputs, and every W11-W13 case")
  func phraseBox() throws {
    let m = try G.load("phrase-box.json")
    for b in try m.array("boxes") {
      let box = try PhraseBox.seal(
        entropy: try G.hex(b["e"]), amk: try G.hex(b["amk"]), userID: UserID(try b.string("user_id"))!,
        recoveryPublicKey: try G.hex(b["recovery_pubkey"]), nonce: try G.hex(b["nonce"]))
      #expect(box == (try G.hex(b["box"])))
    }
    for c in try m.array("cases") {
      let label = "\(try c.string("id")) \(try c.string("name"))"
      let outcome: String
      do {
        let e = try PhraseBox.open(
          try G.hex(c["box"]), amk: try G.hex(c["amk"]), userID: UserID(try c.string("user_id"))!,
          recoveryPublicKey: try G.hex(c["recovery_pubkey"]))
        outcome = "opens"
        #expect(Hex.encode(e.data) == c["e"]?.stringValue, "\(label)")
      } catch UnwrapError.phraseBoxMismatch {
        outcome = "integrityAlarm(phraseBoxMismatch)"
      } catch {
        outcome = "\(error)"
      }
      #expect(outcome == (try c.string("outcome")), "\(label)")
    }
  }

  @Test("frame-aead.json: header, SHA256(AD), K_blob and ct ‖ tag for a supplied R")
  func frameAEAD() throws {
    for c in try G.load("frame-aead.json").array("cases") {
      let env = try Envelope(
        userID: UserID(try c.string("user_id"))!, writerID: WriterID(try c.string("writer_id"))!,
        counter: Int64(try c.int("writer_counter")))
      let header = FrameV3.header(epoch: UInt32(try c.int("epoch")), aad: env.aad)
      #expect(header == (try G.hex(c["header"])))
      let prev = Hash32(try G.hex(c["prev_hash"]))!
      let ad = FrameAEAD.associatedData(header: header, prevHash: prev)
      #expect(Hex.encode(sha256(ad)) == (try c.string("sha256_ad")))
      let kE = try G.hex(c["k_e"])
      let nonce = try G.hex(c["nonce"])
      #expect(try KeyDerivation.blobKey(epochKey: kE, nonce: nonce, associatedData: ad).data == (try G.hex(c["k_blob"])))
      let frame = try G.hex(c["frame"])
      #expect(frame.prefix(header.count) == header && frame.dropFirst(header.count).prefix(12) == nonce)
      #expect(frame.dropFirst(header.count + 12) == (try G.hex(c["ct_tag"])))
      if let r = c["region"], !r.isNull {
        // R supplied: seal it and get Go's bytes.
        #expect(try FrameAEAD.seal(region: try G.hex(r), header: header, prevHash: prev, epochKey: kE, nonce: nonce) == frame)
      } else {
        // R withheld: the frame must open under the same key schedule.
        let layout = FrameV3.Layout(aadLength: env.aad.count, frameLength: frame.count)
        #expect(FrameAEAD.open([UInt8](frame), layout: layout, prevHash: prev, epochKey: kE) != nil)
      }
      if let h = c["blob_hash"]?.stringValue { #expect(Chain.hash(prev: prev, frame: frame).hex == h) }
    }
  }

  @Test("frames.json: Go-sealed frames (Go gzip) open to their plaintext")
  func frames() throws {
    for f in try G.load("frames.json").array("frames") {
      let bytes = try Fixtures.data("crypto-v3/" + (try f.string("file")))
      #expect(bytes.count == (try f.int("bucket")))
      #expect(LooksSealed.check(bytes) == nil)
      let env = try Envelope(
        userID: UserID(try f.string("user_id"))!, writerID: WriterID(try f.string("writer_id"))!,
        counter: Int64(try f.int("writer_counter")))
      #expect(env.aad.count == (try f.int("aad_len")))
      let key = try EpochKey(epoch: UInt32(try f.int("epoch")), key: try G.hex(f["k_e"]))
      let out = Opener(epochHWM: key.epoch, keys: [key]).open(bytes, envelope: env, prevHash: Hash32(try G.hex(f["prev_hash"]))!)
      #expect(out == .opened(Data((try f.string("plaintext")).utf8)), "\(f["name"].map { "\($0)" } ?? "")")
    }
  }

  @Test("chain.json: the five-frame chain from 0^32 and the v1 steps")
  func chain() throws {
    let m = try G.load("chain.json")
    let user = UserID(try m.string("user_id"))!
    let writer = WriterID(try m.string("writer_id"))!
    let key = try EpochKey(epoch: 1, key: try G.hex(m["k_e"]))
    // Every blob_hash is checked from the genesis, as spec 01 §7 defines it. The
    // files' prev_hash fields all repeat the chain's LAST hash (a generator
    // aliasing defect on the Go side, reported to WS-2), so they are recorded as
    // a known issue rather than trusted.
    var prev = Hash32.zero
    var listed: [Hash32] = []
    var derived: [Hash32] = []
    for r in try m.array("rows") {
      let frame = try G.hex(r["frame"])
      let next = Chain.hash(prev: prev, frame: frame)
      #expect(next.hex == (try r.string("blob_hash")))
      let env = try Envelope(userID: user, writerID: writer, counter: Int64(try r.int("writer_counter")))
      if case .opened = Opener(epochHWM: 1, keys: [key]).open(frame, envelope: env, prevHash: prev) {} else {
        Issue.record("chain row \(r["writer_counter"].map { "\($0)" } ?? "") did not open after its predecessor")
      }
      listed.append(Hash32(try G.hex(r["prev_hash"]))!)
      derived.append(prev)
      prev = next
    }
    prev = .zero
    for s in try m.array("v1_chain_steps") {
      let fill = try G.hex(s["fill_byte"])[0]
      let h = Chain.hash(prev: prev, frame: Data(repeating: fill, count: try s.int("length")))
      #expect(h.hex == (try s.string("blob_hash")))
      listed.append(Hash32(try G.hex(s["prev_hash"]))!)
      derived.append(prev)
      prev = h
    }
    #expect(listed == derived)
  }

  @Test("predicate.json: LooksSealed agrees with Go (and the SQL) on every case")
  func predicate() throws {
    let m = try G.load("predicate.json")
    var filler = Data()
    func stream(_ n: Int) -> Data {
      var i: UInt32 = UInt32(filler.count / 32)
      while filler.count < n {
        filler += sha256(Data("predicate-filler".utf8) + [UInt8(i >> 24), UInt8(i >> 16 & 0xff), UInt8(i >> 8 & 0xff), UInt8(i & 0xff)])
        i += 1
      }
      return filler.prefix(n)
    }
    for c in try m.array("cases") {
      var frame: Data
      if let f = c["frame"] {
        frame = try G.hex(f)
      } else {
        frame = Data(stream(try c.int("n")))
        for p in c["patches"]?.arrayValue ?? [] {
          let at = try p.int("at")
          let bytes = try G.hex(p["hex"])
          frame.replaceSubrange(at..<(at + bytes.count), with: bytes)
        }
      }
      #expect((LooksSealed.check(frame)?.rawValue ?? "ok") == (try c.string("want")), "\(c["name"].map { "\($0)" } ?? "")")
    }
  }

  @Test("tamper.json: the reader (§6.6) reaches Go's outcome on every T case")
  func tamper() throws {
    let m = try G.load("tamper.json")
    let user = UserID(try m.string("user_id"))!
    for c in try m.array("cases") {
      let label = "\(try c.string("id")) \(try c.string("name"))"
      let st = try #require(c["reader_state"])
      var keys: [EpochKey] = []
      for k in st["keys"]?.objectValue?.members ?? [] {
        keys.append(try EpochKey(epoch: UInt32(k.key)!, key: try G.hex(k.value)))
      }
      var pinned: [WriterID: Chain.Head] = [:]
      for p in st["pinned_heads"]?.objectValue?.members ?? [] {
        pinned[WriterID(p.key)!] = Chain.Head(counter: Int64(try p.value.int("counter")), hash: Hash32(try G.hex(p.value["blob_hash"]))!)
      }
      var roster: [WriterID: HeadCheck.RosterWriter] = [:]
      for w in st["roster"]?.objectValue?.members ?? [] {
        let live = w.value["live"]?.boolValue ?? true
        roster[WriterID(w.key)!] = HeadCheck.RosterWriter(
          dwkPublicKey: try G.hex(w.value["pubkey"]),
          revokedAt: live
            ? nil : Chain.Head(counter: Int64(try w.value.int("final_counter")), hash: Hash32(try G.hex(w.value["final_head"]))!))
      }
      var own: (writer: WriterID, authoredHead: Int64)?
      if let ow = st["own_writer"]?.stringValue { own = (WriterID(ow)!, Int64(try st.int("own_authored_head"))) }
      let state = PageReader.State(
        userID: user, opener: Opener(epochHWM: UInt32(try st.int("epoch_hwm")), keys: keys),
        // The vector's roster is the one the reader decides with, i.e. after R1's
        // one re-fetch: an unknown writer in it is `tampered(unknownWriter)`.
        serverEpoch: UInt32(try st.int("server_epoch")), pinnedHeads: pinned, roster: roster, rosterRefreshed: true,
        own: own)
      let page = try c.array("page").map { r in
        PageReader.Row(
          stream: try r.string("stream"), writerID: try r.string("writer_id"), counter: String(try r.int("writer_counter")),
          sizeBucket: try r.int("size_bucket"), prevHash: try G.hex(r["prev_hash"]), blobHash: try G.hex(r["blob_hash"]),
          headSig: r["head_sig"]?.stringValue.flatMap { try? Hex.decode($0) }, blob: try G.hex(r["blob"]))
      }
      let got = PageReader.read(page, state: state)
      let want = try #require(c["reader"])
      let wantRows = try want.array("rows")
      #expect(got.rows.count == wantRows.count, "\(label)")
      for (g, w) in zip(got.rows, wantRows) {
        switch g {
        case .opened: #expect(w["kind"]?.stringValue == "opened", "\(label)")
        case .setAside(let reason, let alarm):
          #expect(w["kind"]?.stringValue == "setAside" && w["reason"]?.stringValue == reason.rawValue, "\(label)")
          #expect((w["alarm"]?.boolValue ?? false) == alarm, "\(label)")
        }
      }
      if let hs = want["hard_stop"] {
        #expect(got.stopRow == (try hs.int("row")), "\(label)")
        let o = try #require(hs["outcome"])
        switch got.stop {
        case .hardStop(.tampered(let r))?:
          #expect(o["kind"]?.stringValue == "tampered" && o["reason"]?.stringValue == r.rawValue, "\(label): \(r)")
        case .hardStop(.updateRequired)?: #expect(o["kind"]?.stringValue == "updateRequired", "\(label)")
        case .needsUnlock(let e)?:
          #expect(o["kind"]?.stringValue == "needsUnlock" && Int64(e) == o["epoch"]?.numberValue?.int64Value, "\(label)")
        default: Issue.record("\(label): got \(String(describing: got.stop)), want \(o)")
        }
      } else {
        #expect(got.stop == nil, "\(label): \(String(describing: got.stop))")
      }
    }
  }

  @Test("password.json: email_norm, the server subkeys, S for every stretch input, the peppered verifiers, name_ok")
  func password() throws {
    let m = try G.load("password.json")
    for e in try m.array("email_norm") {
      let input = try e.string("input")
      if let want = e["email_norm"]?.stringValue {
        #expect(try EmailNorm.normalize(input) == want, "\(input)")
      } else {
        #expect(throws: EmailNormError.badEmail, "\(input)") { try EmailNorm.normalize(input) }
      }
    }
    for k in try m.array("server_keys") {
      let salt = try G.hex(k["salt_key"])
      let auth = try G.hex(k["auth_key_generation_1"])
      #expect(Hex.encode(ServerKeys.kSalt(salt)) == (try k.string("k_salt")))
      #expect(Hex.encode(ServerKeys.kPepper(auth)) == (try k.string("k_pepper_1")))
      #expect(Hex.encode(ServerKeys.kCode(auth)) == (try k.string("k_code")))
      #expect(Hex.encode(ServerKeys.kTag(auth)) == (try k.string("k_tag")))
      #expect(ServerKeys.keyID(salt) == (try k.string("salt_key_id")))
      #expect(ServerKeys.keyID(auth) == (try k.string("auth_key_id")))
    }
    for s in try m.array("stretch") {
      let norm = try s.string("email_norm")
      let sSrv = try G.hex(s["s_srv"])
      #expect(try PasswordStretch.salt(serverSalt: sSrv, emailNorm: norm) == (try G.hex(s["salt_c"])))
      let pw = try s.string("password")
      #expect(pw.precomposedStringWithCanonicalMapping.unicodeScalars.count == (try s.int("scalars_after_nfc")))
      let got = try PasswordStretch.stretch(password: pw, serverSalt: sSrv, emailNorm: norm)
      #expect(Hex.encode(got.data) == (try s.string("s")), "\(s["name"].map { "\($0)" } ?? "")")
    }
    for n in try m.array("name_ok") {
      #expect(NameOK.check(try n.string("name")) == (n["name_ok"]?.boolValue == true), "\(n["why"].map { "\($0)" } ?? "")")
    }
  }

  @Test("approval.json: EK, code80 and its base32, the reset messages, the signatures")
  func approval() throws {
    for c in try G.load("approval.json").array("cases") {
      let ek = try Ed25519.publicKey(seed: try G.hex(c["ek_seed"]))
      #expect(ek == (try G.hex(c["ek_pub"])))
      #expect(try ResetCode.code80(ephemeralPublicKey: ek) == (try G.hex(c["code80"])))
      #expect(try ResetCode.text(ephemeralPublicKey: ek) == (try c.string("code")))
      let nonce = try G.hex(c["reset_nonce"])
      let approve = try SigningMessage.resetApprove(
        nonce: nonce, userID: UserID(try c.string("user_id"))!, ephemeralPublicKey: ek,
        writerID: WriterID(try c.string("approver_writer_id"))!)
      #expect(approve == (try G.hex(c["reset_approve_message"])))
      if let pub = c["dak_pubkey"], let sig = c["dak_sig_sample"] {
        #expect(DAK.verify(publicKey: try G.hex(pub), signature: try G.hex(sig), message: approve))
      }
      let finish = try SigningMessage.resetFinish(nonce: nonce, newVerifier: try G.hex(c["s_new"]))
      #expect(finish == (try G.hex(c["reset_finish_message"])))
      #expect(Ed25519.verify(publicKey: ek, signature: try G.hex(c["ek_sig"]), message: finish))
    }
  }
}

enum APIVectors {
  static let present = FileManager.default.fileExists(
    atPath: Fixtures.conformanceRoot.appendingPathComponent("api-v1/messages.json").path)
}

// conformance/api-v1 (Go-written, WS-3; spec 02 §22): every §10.1 message and
// every §10.2 action, rebuilt by CoreCrypto from its fields.
@Suite("conformance/api-v1 (Go)", .enabled(if: APIVectors.present, "conformance/api-v1 is not in this checkout"))
struct GoAPIV1Tests {
  typealias G = GoVectors

  static func message(_ x: JSONValue) throws -> Data {
    let f = try #require(x["fields"])
    func h(_ k: String) throws -> Data { try G.hex(f[k]) }
    func w(_ k: String = "writer_id") throws -> WriterID { try #require(WriterID(try f.string(k))) }
    func u() throws -> UserID { try #require(UserID(try f.string("user_id"))) }
    func optionalHex(_ k: String) throws -> Data? { f[k].flatMap { $0.isNull ? nil : try? Hex.decode($0.stringValue ?? "") } }
    switch try x.string("domain") {
    case Domain.register.rawValue:
      return Domain.register.prefix + (try h("nonce")) + (try h("authority_pubkey"))
    case Domain.writerRegistration.rawValue:
      return try SigningMessage.registration(
        nonce: try h("nonce"), writerID: try w(), dwkPublicKey: try h("dwk_pub"), dakPublicKey: try h("dak_pub"))
    case Domain.writerRevocation.rawValue:
      return try SigningMessage.revocation(
        nonce: try h("nonce"), writerID: try w(), finalCounter: Int64(try f.string("final_counter"))!,
        finalHead: Hash32(try h("final_head"))!)
    case Domain.sessionBind.rawValue:
      return try SigningMessage.sessionBind(loginChallenge: try h("login_challenge"), writerID: try w())
    case Domain.accountDelete.rawValue:
      return try SigningMessage.deletion(nonce: try h("nonce"), userID: try u())
    case Domain.bootstrap.rawValue:
      let wr = try #require(f["writer"])
      // A password payload's prf_wrap is {credential_id: null, wrap: null}: no wrap.
      let prf = f["prf_wrap"].flatMap { $0.isNull || $0["wrap"]?.isNull == true ? nil : $0 }
      let payload = BootstrapPayload(
        userID: try u(), amkCommitment: try h("amk_commitment"), authorityPublicKey: try h("authority_pubkey"),
        recoveryPublicKey: try h("recovery_pubkey"), recoveryWrap: try h("recovery_wrap"), phraseBox: try h("phrase_box"),
        emailNorm: "", authKind: AuthKind(rawValue: UInt8(try f.int("auth_kind")))!, authHash: try h("auth_hash"),
        writerPublicKey: try G.hex(wr["pubkey"]), writerDAKPublicKey: try G.hex(wr["dak_pubkey"]),
        writerID: try #require(WriterID(try wr.string("writer_id"))),
        prfWrap: try prf.map { (credentialID: try G.hex($0["credential_id"]), wrap: try G.hex($0["wrap"])) })
      // The payload carries email_hash, not the address: splice the given hash in.
      var bytes = try payload.encoded()
      bytes.replaceSubrange(293..<325, with: try h("email_hash"))
      #expect(bytes == (try G.hex(x["extra"]?["payload"])), "\(x["name"]?.stringValue ?? "")")
      return try SigningMessage.bootstrap(nonce: try h("nonce"), payload: bytes)
    case Domain.recoverySignin.rawValue:
      if try f.int("auth_kind") == 2 {
        return try SigningMessage.recoverySigninPassword(nonce: try h("nonce"), newVerifier: try h("s_new"))
      }
      return try SigningMessage.recoverySigninPasskey(
        nonce: try h("nonce"), clientDataJSON: try h("client_data_json"), attestationObject: try h("attestation_object"),
        prfWrap: try optionalHex("prf_wrap"))
    case Domain.recoveryRotate.rawValue:
      return try SigningMessage.recoveryRotate(
        nonce: try h("nonce"), newRecoveryPublicKey: try h("new_recovery_pubkey"), newRecoveryWrap: try h("new_recovery_wrap"),
        newPhraseBox: try h("new_phrase_box"))
    case Domain.epochRotate.rawValue:
      return try SigningMessage.epochRotate(nonce: try h("nonce"), newEpoch: UInt32(try f.int("new_epoch")), keyring: try h("keyring"))
    case Domain.writerHead.rawValue:
      return SigningMessage.head(
        userID: try u(), counter: Int64(try f.string("counter"))!, blobHash: Hash32(try h("blob_hash"))!, writerID: try w())
    case Domain.passkeyAdd.rawValue:
      return try SigningMessage.passkeyAdd(
        nonce: try h("nonce"), clientDataJSON: try h("client_data_json"), attestationObject: try h("attestation_object"),
        prfWrap: try optionalHex("prf_wrap"))
    case Domain.wrapPut.rawValue:
      return try SigningMessage.wrapPut(nonce: try h("nonce"), credentialID: try h("credential_id"), wrap: try h("wrap"))
    case Domain.stepUpDevice.rawValue:
      return try SigningMessage.deviceStepUp(challenge: try h("c"), writerID: try w())
    case Domain.resetApprove.rawValue:
      return try SigningMessage.resetApprove(nonce: try h("nonce"), userID: try u(), ephemeralPublicKey: try h("ek_pub"), writerID: try w())
    case Domain.resetFinish.rawValue:
      return try SigningMessage.resetFinish(nonce: try h("nonce"), newVerifier: try h("s_new"))
    case Domain.emailChange.rawValue:
      return try SigningMessage.emailChange(nonce: try h("nonce"), newEmailNorm: try f.string("new_email_norm"))
    case Domain.deviceFreeze.rawValue:
      return try SigningMessage.deviceFreeze(nonce: try h("nonce"), userID: try u(), writerID: try w())
    default:
      Issue.record("unknown domain \(x["domain"]?.stringValue ?? "")")
      return Data()
    }
  }

  @Test("messages.json: every message rebuilt byte for byte; every signature verifies")
  func messages() throws {
    let m = try Fixtures.json("api-v1/messages.json")
    for x in try m.array("messages") {
      let name = x["name"]?.stringValue ?? ""
      let built = try Self.message(x)
      #expect(built == (try G.hex(x["bytes"])), "\(name)")
      #expect(built.count == (try x.int("length")), "\(name)")
      if x["domain"]?.stringValue == Domain.register.rawValue {
        #expect(
          try SigningMessage.registerChallenge(nonce: try G.hex(x["fields"]?["nonce"]), authorityPublicKey: try G.hex(x["fields"]?["authority_pubkey"]))
            == (try G.hex(x["extra"]?["c_reg"])))
      }
      guard let sig = x["signature"]?.stringValue else { continue }
      let pub = try G.hex(x["pubkey"])
      if x["alg"]?.stringValue == "p256" {
        #expect(DAK.verify(publicKey: pub, signature: try Hex.decode(sig), message: built), "\(name)")
      } else {
        #expect(Ed25519.verify(publicKey: pub, signature: try Hex.decode(sig), message: built), "\(name)")
      }
    }
  }

  static let representatives: [StepUpParams] = [
    .passkeyAdd, .passkeyDelete(credentialID: Data()), .keysBootstrap(authorityPublicKey: Data()),
    .keysWrapPut(credentialID: Data()), .keysWrapDelete(credentialID: Data()), .keysRecoveryRotate(newRecoveryPublicKey: Data()),
    .keysEpochRotate(newEpoch: 2), .writerRevoke(WriterID("ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d")!),
    .mailboxLink(idToken: ""), .mailboxUnlink, .sessionLogoutAll, .accountDelete(UserID("6f1c2b9e-4d3a-4f5b-8c7d-0e1f2a3b4c5d")!),
    .passwordSet(newVerifierHash: Data()), .passwordChange(newVerifierHash: Data()), .passwordRemove,
    .passwordReset(newVerifierHash: Data()), .emailChange(newEmailNorm: "", newVerifierHash: nil), .phraseView,
    .accountFreeze, .accountUnfreeze,
  ]

  @Test("stepup.json: enc(T), params_hash, C, the proof kinds and DeviceStepUpMessage for every action")
  func stepUp() throws {
    let m = try Fixtures.json("api-v1/stepup.json")
    let kinds = Dictionary(Self.representatives.map { ($0.action, $0.proofKinds.map(\.rawValue)) }, uniquingKeysWith: { a, _ in a })
    var seen = Set<String>()
    for a in try m.array("actions") {
      let action = try a.string("action")
      let tuple = try a.array("fields").map { try Hex.decode($0.stringValue ?? "") }
      #expect(Hex.encode(StepUp.encode(tuple)) == (try a.string("enc")), "\(action)")
      let ph = StepUp.paramsHash(action: action, tuple: tuple)
      #expect(Hex.encode(ph) == (try a.string("params_hash")), "\(action)")
      let c = try StepUp.challenge(nonce: try G.hex(a["nonce"]), action: action, paramsHash: ph)
      #expect(Hex.encode(c) == (try a.string("c")), "\(action)")
      if a["synthetic"]?.boolValue == true { continue }
      seen.insert(action)
      #expect(kinds[action] == a["proof_kinds"]?.arrayValue?.map { $0.stringValue ?? "" }, "\(action)")
      if let msg = a["device_step_up_message"]?.stringValue {
        let w = try #require(WriterID(try a.string("device_writer_id")))
        #expect(Hex.encode(try SigningMessage.deviceStepUp(challenge: c, writerID: w)) == msg, "\(action)")
      }
    }
    #expect(seen == Set(StepUpParams.actions))
  }
}
