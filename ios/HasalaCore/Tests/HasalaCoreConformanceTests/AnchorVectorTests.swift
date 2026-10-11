// Spec 01 §15.5: every anchor vector A01-A26 (A14-P and A19-K included),
// reproduced by CoreCrypto from the spec's inputs. Go's Ed25519 signatures are
// deterministic and are VERIFIED here; P-256 signatures are randomized samples
// that must verify under A13's DAK public key. No signature bytes are compared.
import CoreCrypto
import CorePrimitives
import CoreWire
import Foundation
import Testing

@Suite("spec 01 §15.5 anchor vectors")
struct AnchorVectorTests {
  typealias A = Anchor
  static func h(_ s: String) -> Data { Anchor.hex(s) }

  static let rkPub = h("011b14200fa13205fe88feed06b6cef5a94bc07e8dfb89e2e97f1344071b1d7d")
  static let aakPub = h("174553b456dddfc6908ecab1c101fe6ab21e2baa0617795b7d43a63482993fd5")
  static let dwkPub = h("cd14b37f956e953194ff7fb73b3d81dcc561d61a7538094b7c3e1a643ee5f3aa")
  static let dakPub = h(
    "04515c3d6eb9e396b904d3feca7f54fdcd0cc1e997bf375dca515ad0a6c3b4035f4536be3a50f318fbf9a5475902a221502bef0d57e08c53b2cc0a56f17d9f9354"
  )
  static let recoveryWrap = h(
    """
    0101101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f
    a0a1a2a3a4a5a6a7a8a9aaab9cc42943bdaccb4dc8d3fbb3fe281a79cae618d515afae
    61cb83a9e01c8642b1141550501c3db96f4366ecf56398553edbcb4c773f882291c2d0
    ce2eeed5b9d8c42df492f96ec29ca9ff6fd42f0da6cff7
    """)
  static let prfWrap = h(
    """
    0102303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f
    b0b1b2b3b4b5b6b7b8b9babbb4e485f01140d0951848802d29d3d798473bec7ef5ab28
    12782a13c7287a3d8ae99619d45466e0b697de90955e7de5b1e18df74758f9e2abe7d9
    0788fabf48d7be9a3312e49484bb29373052401ad028ef
    """)
  static let phraseBox = h(
    "01f0f1f2f3f4f5f6f7f8f9fafbf38d5a2ba3f575f30234c30952c97e71eb7a777ba708e40165b9f1408ecb37fe")
  static let a09BlobHash = Hash32(hex: "baf51ed04dd41eb700cf8ba0467411befaa4494dc6033688e7e9670e3570292f")!
  static let a10BlobHash = Hash32(hex: "cee22837f339529583565b5de892c0783314923db66a5fdf4432590bec301b3d")!
  static let a19S = h("82da856ee5beea8425653d8ba0e280eb8640e4cfe91010b0588434259c6f1e88")

  func hx(_ d: Data) -> String { Hex.encode(d) }
  func sha(_ d: Data) -> String { Hex.encode(sha256(d)) }

  @Test("A01 PRF_SALT")
  func a01() {
    #expect(hx(KeyDerivation.prfSalt) == "6bd5a9ebcc65e64bfab48f34528496a6449975b922e87a7ac79518c742170d01")
  }

  @Test("A02 phrase(E), both directions")
  func a02() throws {
    let words = try Phrase.words(entropy: A.entropy)
    #expect(
      words.joined(separator: " ")
        == "ozone drill grab fiber curtain grace pudding thank cruise elder eight picnic")
    #expect(try Phrase.entropy(words: words).data == A.entropy)
  }

  @Test("A03 RK_seed (same with an empty salt) and RK.pub")
  func a03() throws {
    let seed = try KeyDerivation.recoveryKeySeed(entropy: A.entropy).data
    #expect(hx(seed) == "bd4572ae0cb80d9c07f9221c0c992c6a6e3fc00a7b766dc7fa732227af4130c8")
    let emptySalt = try hkdfSHA256(inputKeyMaterial: A.entropy, salt: Data(), info: Domain.recoveryKey.bytes)
    #expect(emptySalt == seed)
    #expect(try KeyDerivation.recoveryPublicKey(entropy: A.entropy) == Self.rkPub)
  }

  @Test("A04 AAK.pub and DWK.pub")
  func a04() throws {
    #expect(try KeyBody(amk: A.amk, aakSeed: A.aakSeed).authorityPublicKey() == Self.aakPub)
    #expect(try Ed25519.publicKey(seed: A.dwkSeed) == Self.dwkPub)
  }

  @Test("A05 amk_commit, A06 K_1")
  func a05a06() throws {
    #expect(
      hx(try KeyDerivation.amkCommitment(amk: A.amk, userID: A.userID))
        == "68e63be415f5e196e693f3da355d60eea5cf0c1168adea750c02b0185c2aaa22")
    #expect(
      hx(try KeyDerivation.epochKey1(amk: A.amk, userID: A.userID).data)
        == "c2e59f467f32b6e843710e8f959c186013d2d2fe94ec883c64ebfa3155f8e188")
  }

  @Test("A07 RWK and the recovery wrap; it opens back to the body")
  func a07() throws {
    #expect(
      hx(try KeyDerivation.recoveryWrapKey(entropy: A.entropy, salt: A.recoveryWrapSalt).data)
        == "d2536aa0185606de0d738686bacd1be63b86cf4585709cc6db805376853bd800")
    let body = try KeyBody(amk: A.amk, aakSeed: A.aakSeed)
    let wrap = try Wrap.sealRecovery(
      body: body, entropy: A.entropy, userID: A.userID, salt: A.recoveryWrapSalt, nonce: A.recoveryWrapNonce)
    #expect(wrap == Self.recoveryWrap)
    #expect(wrap.count == 127)
    let opened = try Wrap.openRecovery(Self.recoveryWrap, entropy: A.entropy, userID: A.userID)
    #expect(opened.amk.data == A.amk && opened.aakSeed.data == A.aakSeed)
  }

  @Test("A08 PWK and the PRF wrap; it opens back to the body")
  func a08() throws {
    #expect(
      hx(try KeyDerivation.prfWrapKey(prfOutput: A.prfOutput, salt: A.prfWrapSalt).data)
        == "f77bcc6418fafe78e1f05fb437199d52d7610165c0ee33d104f3d4937fcd3f9c")
    let body = try KeyBody(amk: A.amk, aakSeed: A.aakSeed)
    let wrap = try Wrap.sealPRF(
      body: body, prfOutput: A.prfOutput, userID: A.userID, credentialID: A.credentialID, salt: A.prfWrapSalt,
      nonce: A.prfWrapNonce)
    #expect(wrap == Self.prfWrap)
    let opened = try Wrap.openPRF(Self.prfWrap, prfOutput: A.prfOutput, userID: A.userID, credentialID: A.credentialID)
    #expect(opened.amk.data == A.amk)
  }

  /// A09/A10's frame at `counter` with `nonce` after `prev`.
  static func frame(counter: Int64, nonce: Data, prev: Hash32) throws -> (frame: Data, ad: Data, header: Data) {
    let env = try Envelope(userID: A.userID, writerID: A.writerID, counter: counter)
    let header = FrameV3.header(epoch: 1, aad: env.aad)
    let k1 = try KeyDerivation.epochKey1(amk: A.amk, userID: A.userID)
    let region = A.region(1024 - 35 - env.aad.count)
    let frame = try FrameAEAD.seal(region: region, header: header, prevHash: prev, epochKey: k1, nonce: nonce)
    return (frame, FrameAEAD.associatedData(header: header, prevHash: prev), header)
  }

  @Test("A09 frame at counter 1: header, SHA256(AD), K_blob, ct, tag, frame and blob_hash")
  func a09() throws {
    let (frame, ad, header) = try Self.frame(counter: 1, nonce: A.frameNonce1, prev: .zero)
    #expect(
      hx(header)
        == "0300000001005336663163326239652d346433612d346635622d386337642d306531"
        + "6632613362346335647c686f747c696f732d30613162326333642d346535662d3461"
        + "36622d386337642d3965306631613262336334647c31")
    #expect(header.count - 7 == 83)
    #expect(sha(ad) == "2485727d9cc32680ca4519b03301855757c0bcd0eb252022113b172b6755aa31")
    let k1 = try KeyDerivation.epochKey1(amk: A.amk, userID: A.userID)
    #expect(
      hx(try KeyDerivation.blobKey(epochKey: k1, nonce: A.frameNonce1, associatedData: ad).data)
        == "86b19ef7697c451eba5aa36bf7296de24c4feba11d5cbb6079aa03214597aabd")
    #expect(frame.count == 1024)
    let layout = FrameV3.Layout(aadLength: 83, frameLength: 1024)
    #expect(layout.regionLength == 906)
    #expect(hx(frame[layout.region].prefix(16)) == "9438cfe68d4a955181d8c18f408556c3")
    #expect(hx(frame[layout.tag]) == "420dd0db074a3bb3b5ba33dd3feb49a2")
    #expect(sha(frame) == "8aff44368ce9015d29617089fbc81ddf7176626d04f41be297189cca90b4c708")
    #expect(Chain.hash(prev: .zero, frame: frame) == Self.a09BlobHash)
  }

  @Test("A10 frame at counter 2 after A09")
  func a10() throws {
    let (frame, ad, _) = try Self.frame(counter: 2, nonce: A.frameNonce2, prev: Self.a09BlobHash)
    let k1 = try KeyDerivation.epochKey1(amk: A.amk, userID: A.userID)
    #expect(
      hx(try KeyDerivation.blobKey(epochKey: k1, nonce: A.frameNonce2, associatedData: ad).data)
        == "da2cd8d053e2129d99e76459682f1c5644ba543879bbd722598aadf078d11753")
    #expect(hx(frame.suffix(16)) == "67412fe8521354551b47038661c7aeb1")
    #expect(sha(frame) == "c2357f3d9071227ffe86f8a8b7f1110afcbe51b2ed8e3692b7191e9a961c5418")
    #expect(Chain.hash(prev: Self.a09BlobHash, frame: frame) == Self.a10BlobHash)
  }

  @Test("A11 step-up params and challenges")
  func a11() throws {
    #expect(hx(StepUp.encode([A.credentialID])) == "000000100102030405060708090a0b0c0d0e0f10")
    let cases: [(StepUpParams, String, String)] = [
      (
        .passkeyDelete(credentialID: A.credentialID),
        "7686789f2d3f75ea516987626f0da957e1e04998a6f5797b5d3153321ac449b5",
        "20f8bbc4410b52bef9b467a00dcf8313777d3dd8afea81a22bd7fb09d6d97b79"
      ),
      (
        .sessionLogoutAll, "feec00bcd26e8dda1501ae355f6057831a4c7c1069c04080359d023da70fc84c",
        "620e8efa0c5b068d7385582c1c97f76f789c0d9d6d6ca220b4d792f7248aa717"
      ),
      (
        .keysBootstrap(authorityPublicKey: Self.aakPub),
        "2ca5b81b21d38d25acc0e7a2d67cc21de22ec4d80970b057de8e87a0da720cf7",
        "ff9ba915366a6b698c8748c98784e6a0a6fc7ab36d2f60ebe63b1103d316782c"
      ),
      (
        .accountDelete(A.userID), "4f663475064aa7fb55648bf8b26a3534728987013c93208fdf2fcf7ea1a3180b",
        "d819d9ababfbdc54b1758aa770d0b097a6490c8c3a77eef4771e4a2718f63eb2"
      ),
    ]
    for (p, params, c) in cases {
      #expect(hx(StepUp.paramsHash(p)) == params, "\(p.action)")
      #expect(hx(try StepUp.challenge(nonce: A.stepUpNonce, params: p)) == c, "\(p.action)")
      #expect(StepUp.serverChallengeMatches(Self.h(c), nonce: A.stepUpNonce, params: p))
    }
  }

  @Test("A12 C_reg")
  func a12() throws {
    #expect(
      hx(try SigningMessage.registerChallenge(nonce: A.registerNonce, authorityPublicKey: Self.aakPub))
        == "6c4baf6196d04c602ba74784866cf12d34d518bfedd63f2f14d6d2d9b91ffd3e")
  }

  @Test("A13 RegistrationMessage, DAK.pub from the fixed scalar, the Go AAK signature verifies")
  func a13() throws {
    #expect(DAK.isValidPublicKey(Self.dakPub))
    #expect(try SoftDAK.publicKey(scalar: A.dakScalar) == Self.dakPub)
    let m = try SigningMessage.registration(
      nonce: A.writerChallengeNonce, writerID: A.writerID, dwkPublicKey: Self.dwkPub, dakPublicKey: Self.dakPub)
    #expect(m.count == 201)
    #expect(sha(m) == "688a20d5661d707d09ccfa6a384e5d0eba641377a77437b1d5d1037066b292a7")
    let sig = Self.h(
      "0021a4d3606fe175df135861cfa90cc77f39bd22866ec0631147ebeb846b78248b4244dc83efc4715a15ae271f5fdc8c8c4891ed255fcf18ea94c0138879ab0d"
    )
    #expect(Ed25519.verify(publicKey: Self.aakPub, signature: sig, message: m))
  }

  static func bootstrapPayload(password: Bool) throws -> BootstrapPayload {
    let emailNorm = try EmailNorm.normalize(A.address)
    return BootstrapPayload(
      userID: A.userID, amkCommitment: try KeyDerivation.amkCommitment(amk: A.amk, userID: A.userID),
      authorityPublicKey: aakPub, recoveryPublicKey: rkPub, recoveryWrap: recoveryWrap, phraseBox: phraseBox,
      emailNorm: emailNorm, authKind: password ? .password : .passkey,
      authHash: password ? sha256(a19S) : sha256(A.attestationObject), writerPublicKey: dwkPub,
      writerDAKPublicKey: dakPub, writerID: A.writerID,
      prfWrap: password ? nil : (credentialID: A.credentialID, wrap: prfWrap))
  }

  @Test("A14 BootstrapPayload (passkey) and BootstrapMessage")
  func a14() throws {
    let payload = try Self.bootstrapPayload(password: false).encoded()
    #expect(payload.count == 644)
    #expect(sha(payload) == "15663ec145c6fac5a3743b7e9c76cff6dbe80520a6b92f49870b017d6792d1c8")
    let m = try SigningMessage.bootstrap(nonce: A.writerChallengeNonce, payload: payload)
    #expect(m.count == 84)
    #expect(sha(m) == "959d895fe96b5b02593d3ef2aa3fe905112b7e2f88888a422287ede0453c2c8c")
    let sig = Self.h(
      "f90856a3ffb6b798a40f7aaf51b62c4881b2167294f823e7659c6e45a6a1cae49c0c315424ef0f6eb9d9dda4c36fdb054fee4644d14aa8b08753e5c544f3d70d"
    )
    #expect(Ed25519.verify(publicKey: Self.aakPub, signature: sig, message: m))
  }

  @Test("A14-P BootstrapPayload (password)")
  func a14p() throws {
    let payload = try Self.bootstrapPayload(password: true).encoded()
    #expect(payload.count == 501)
    #expect(sha(payload) == "831b7aa7fac401971227aea692f12b3f533e68e203546e15f4dbf7f38fd4c3b8")
    let m = try SigningMessage.bootstrap(nonce: A.writerChallengeNonce, payload: payload)
    #expect(sha(m) == "730469bf7a6a9842045cd9cdd8be5004a01d678a7ef44cbe0468e9df1f9a25d1")
    let sig = Self.h(
      "0931c86dc9f9dddf610d50fd3fd4a3a959e883b27fc31ebb04769f9ec7553bcdeeb17bbd0178001a7cf0377a9bee7503439aa27cbf5b692433e5357a76118b03"
    )
    #expect(Ed25519.verify(publicKey: Self.aakPub, signature: sig, message: m))
  }

  @Test("A15 RevocationMessage and DeletionMessage")
  func a15() throws {
    let m = try SigningMessage.revocation(
      nonce: A.stepUpNonce, writerID: A.writerID, finalCounter: 2, finalHead: Self.a10BlobHash)
    #expect(m.count == 142)
    #expect(sha(m) == "4ba686ac12eb6ff61fd95c9c085546651d6ada83cafd84438fe52864bccb4409")
    let sig = Self.h(
      "dab2b343bf60045d4411110dea3ace1c6c57dcd6940f1c51d45db3c262d265257b7eb22b7d27b402312bd7cc9032930f2af4d7c0712db7e42dc3f9bd9c9b7100"
    )
    #expect(Ed25519.verify(publicKey: Self.dwkPub, signature: sig, message: m))
    let d = try SigningMessage.deletion(nonce: A.stepUpNonce, userID: A.userID)
    #expect(d.count == 94)
    #expect(sha(d) == "ef962c66923f1cea34ca06218ffeec5e050c2e108502933495ef6ee1aefd1e7a")
  }

  @Test("A16 SessionBindMessage")
  func a16() throws {
    let m = try SigningMessage.sessionBind(loginChallenge: A.loginChallenge, writerID: A.writerID)
    #expect(m.count == 96)
    #expect(sha(m) == "6d72c9719e29a0cdd21dce1b65bdf3345f5b226c898cd69ea31033006e7dfc44")
    let sig = Self.h(
      "61000688ced4db1f0e16a998c66ec24a644b86d04f38ce85a2ad6c788d44038a8a6a1b45f58006894972e5f35e7419966a12aed282421062d2414559c199f00c"
    )
    #expect(Ed25519.verify(publicKey: Self.dwkPub, signature: sig, message: m))
  }

  @Test("A17 RecoverySigninMessage: passkey, no PRF wrap, password")
  func a17() throws {
    let m = try SigningMessage.recoverySigninPasskey(
      nonce: A.recoverNonce, clientDataJSON: A.clientDataJSON, attestationObject: A.attestationObject,
      prfWrap: Self.prfWrap)
    #expect(m.count == 155)
    #expect(sha(m) == "aa10f54f7b1803ef2f612a98bad651979e9ced9c4d731aa11e85d4a656c4954d")
    #expect(
      Ed25519.verify(
        publicKey: Self.rkPub,
        signature: Self.h(
          "bd9a2c8db7134972f11aadfb19acfb0a0d8907616a47c0de3178c84c00a6e221b1744e04a9b13af63f9b7377913ce0d6359ab30d295e22b7fed6cc3f817cfe05"
        ), message: m))
    let noWrap = try SigningMessage.recoverySigninPasskey(
      nonce: A.recoverNonce, clientDataJSON: A.clientDataJSON, attestationObject: A.attestationObject, prfWrap: nil)
    #expect(sha(noWrap) == "92446a72eb039ebbce55d9e63e1f76a2d38dbca9c94a61cefeb1f0957dab844d")
    let pw = try SigningMessage.recoverySigninPassword(nonce: A.recoverNonce, newVerifier: Self.a19S)
    #expect(pw.count == 155)
    #expect(sha(pw) == "b310740ced78f61b183bd39b3af7b944c0a0d3d85df2a625a42a085486e33aec")
    #expect(
      Ed25519.verify(
        publicKey: Self.rkPub,
        signature: Self.h(
          "b3a35450d10c1ea56e4009e21993d2fd6a8e81af490a5a81099942a6c7c56f069de9cf6c49ac5b0f5b549138fd15505600b4e4d3b517f7e480eb1587967a700a"
        ), message: pw))
  }

  @Test("A18 RecoveryRotateMessage with the new phrase box")
  func a18() throws {
    let e2 = Data(repeating: 0x80, count: 16)
    let rk2 = try KeyDerivation.recoveryPublicKey(entropy: e2)
    #expect(hx(rk2) == "21751a01ea5863cde7576580c8b3e685ad5d57b42856b882bcf7d59ec119f308")
    let box = try PhraseBox.seal(
      entropy: e2, amk: A.amk, userID: A.userID, recoveryPublicKey: rk2, nonce: A.phraseBoxNonce)
    #expect(
      hx(box) == "01f0f1f2f3f4f5f6f7f8f9fafbed85873e09a697b969fabdbd7aa0e523d1a4758be33f023d6ba5f9a86baaeb65")
    let newWrap = A.run(0x11, 0x8f)
    #expect(newWrap.count == 127)
    let m = try SigningMessage.recoveryRotate(
      nonce: A.stepUpNonce, newRecoveryPublicKey: rk2, newRecoveryWrap: newWrap, newPhraseBox: box)
    #expect(m.count == 154)
    #expect(sha(m) == "0d1f00191fa1124551412b38930d1bf6bc84169f67325a8d8b89c161d83a2854")
    #expect(
      Ed25519.verify(
        publicKey: Self.aakPub,
        signature: Self.h(
          "d93da013c1b02072a362bdc1523281c0503a104106f68a9ec0bd039fd3636c379defa63c206c658695a0823c381fc9cece715e99e859b54014c20418d9aebd05"
        ), message: m))
    #expect(
      hx(StepUp.paramsHash(.keysRecoveryRotate(newRecoveryPublicKey: rk2)))
        == "af6881cb23865fa9166f64da4b42c7b6a346f43d413f2738df5dc04177819ba3")
    #expect(try PhraseBox.open(box, amk: A.amk, userID: A.userID, recoveryPublicKey: rk2).data == e2)
  }

  @Test("A19 server keys, the address, S at 600,000, the peppered hash, code_mac and the phrase box")
  func a19() throws {
    let k = A.authKeyA19
    #expect(hx(ServerKeys.kSalt(A.saltKey)) == "248de31e3491cc548e63a8f05c7bd945c6c2845de96ce5870cb90deb0594f479")
    #expect(hx(ServerKeys.kPepper(k)) == "3a77f4a685ba3d258457446f847322fb851278b7143f364f7b3ea959b1e5be52")
    #expect(hx(ServerKeys.kCode(k)) == "ed9f25497d0517584f83203aae713cca83934b308a45ac89755c0a01973afe49")
    #expect(hx(ServerKeys.kTag(k)) == "085f6fe9c3db0ea7fe445fd4cc53f203fde9ed69f19711f2c95c88137471f81f")
    #expect(ServerKeys.keyID(k) == "03be86c86f5c0987")
    let emailNorm = try EmailNorm.normalize(A.address)
    #expect(emailNorm == "maya.rahman+hasala@gmail.com")
    #expect(hx(EmailNorm.hash(emailNorm)) == "6856c023e016e2a03b5ef29b0885b6d4d67e727c19138fed7c5048d41dedeeac")
    let tag = ServerKeys.emailTag(k, emailNorm: emailNorm)
    #expect(hx(tag) == "c213f4c1a7877e8ae1d5b83f69a59c28363d320dbb149eb3c9487737bca17b8a")
    let sSrv = ServerKeys.serverSalt(A.saltKey, emailNorm: emailNorm)
    #expect(hx(sSrv) == "44b6d3bbf924d4988797f591a3532a88455b2a75ea88d9ad647f736e100e5db6")
    // The input is NFD; NFC is what is stretched.
    #expect(
      Hex.encode(Array(A.passwordNFD.precomposedStringWithCanonicalMapping.utf8))
        == "486173616c6120636166c3a9203230323621")
    let s = try PasswordStretch.stretch(password: A.passwordNFD, serverSalt: sSrv, emailNorm: emailNorm)
    #expect(s.data == Self.a19S)
    #expect(sha(s.data) == "6b2e179e793c2fb3450b56ed96e237c6e661441ce10834a8127edb696cf5bd12")
    #expect(
      hx(ServerKeys.pepperedVerifier(k, s: s)) == "03a50fa0277e5cd716367205f9dbca3a6e858e855a3c0f5f4f5b8c5577ea8ca1")
    #expect(
      hx(ServerKeys.passwordHash(k, s: s, pwSalt: A.pwSalt))
        == "1a52b4928b8afbb0530365a47030bc55c94f8e19289e95f5854c62df10ccd568")
    #expect(
      hx(ServerKeys.codeMAC(k, purpose: A.codePurpose, codeID: A.codeID, emailTag: tag, code: A.code))
        == "1d600ed6f4e79f3e7706bc4f4274af7a8dfab898620fc780f83554d89b02b721")
    #expect(
      hx(try KeyDerivation.phraseBoxKey(amk: A.amk, userID: A.userID).data)
        == "d02f4066e537419b47f48789776a2261caa5a071f12337819707f764b69a8447")
    let box = try PhraseBox.seal(
      entropy: A.entropy, amk: A.amk, userID: A.userID, recoveryPublicKey: Self.rkPub, nonce: A.phraseBoxNonce)
    #expect(box == Self.phraseBox)
    #expect(try PhraseBox.open(box, amk: A.amk, userID: A.userID, recoveryPublicKey: Self.rkPub).data == A.entropy)
  }

  @Test("A19-K keys apart: salt from salt_key only, pepper, code and tag from auth_key")
  func a19k() throws {
    let k = A.authKeyA19K
    let emailNorm = try EmailNorm.normalize(A.address)
    #expect(
      hx(ServerKeys.serverSalt(A.saltKey, emailNorm: emailNorm))
        == "44b6d3bbf924d4988797f591a3532a88455b2a75ea88d9ad647f736e100e5db6")
    #expect(ServerKeys.keyID(A.saltKey) == "03be86c86f5c0987")
    #expect(hx(ServerKeys.kPepper(k)) == "aee2a77f0c3827d6c06bb2d239baf1c53788bc58084aebc86d81db8ad6d39985")
    #expect(hx(ServerKeys.kCode(k)) == "7d03066d1b664157152763169f09619f1f5594cbb8aebd3dd7165a5ca0f48ca5")
    #expect(hx(ServerKeys.kTag(k)) == "90def03ca93eb9496264988e3619db9e1f00988759b04003fd77593be680f4b5")
    #expect(ServerKeys.keyID(k) == "987df2f4eff01510")
    let tag = ServerKeys.emailTag(k, emailNorm: emailNorm)
    #expect(hx(tag) == "c77bed03efbe7558c40f4ac9d312abd7cd871f1db5becec7bcd8dbb85584b652")
    #expect(
      hx(ServerKeys.pepperedVerifier(k, s: Self.a19S))
        == "f848425cdfb0a008b16296b18285256aff3bc064c5a9b229b9c76743a98f452e")
    #expect(
      hx(ServerKeys.passwordHash(k, s: Self.a19S, pwSalt: A.pwSalt))
        == "3d47bda72857d6944ea68175c69f62b213f61a9bd5e25b931cbab4558eba7d97")
    #expect(
      hx(ServerKeys.codeMAC(k, purpose: A.codePurpose, codeID: A.codeID, emailTag: tag, code: A.code))
        == "7f40507fd64bd6eefa92d6767dfaa93f29f0e33013bdbcee3f784663bb1b2779")
  }

  @Test("A20 PasskeyAddMessage and WrapPutMessage")
  func a20() throws {
    let m = try SigningMessage.passkeyAdd(
      nonce: A.stepUpNonce, clientDataJSON: A.clientDataJSON, attestationObject: A.attestationObject,
      prfWrap: Self.prfWrap)
    #expect(m.count == 150)
    #expect(sha(m) == "6342d493bc9c962539d9bb3fbff660d8ee5eb447774e16d3c352310e476a8b1a")
    #expect(
      Ed25519.verify(
        publicKey: Self.dwkPub,
        signature: Self.h(
          "3cc6c9e7324e351b37dc8fec7cac5f8cd1ce90880fe5445f667ea8a5b3ffe9d5106388a41edaddb2451334d81cec033d3c2759fe8e30390d6bba59cce70ff00a"
        ), message: m))
    let w = try SigningMessage.wrapPut(nonce: A.stepUpNonce, credentialID: A.credentialID, wrap: Self.prfWrap)
    #expect(w.count == 115)
    #expect(sha(w) == "25b2edd8e4c52cffeed739dde5b4c34e7c2c9d2419de21cf8afa6a7894cfdbb3")
    #expect(
      Ed25519.verify(
        publicKey: Self.dwkPub,
        signature: Self.h(
          "3a57246c0d36744d88773ba41569e6df1c25601c357445a6003bce00050a56aa3213101376e10781335a07155d777242c9f259896bae57b638d41c33348f7d0d"
        ), message: w))
  }

  @Test("A21 HeadMessage")
  func a21() throws {
    let m = SigningMessage.head(userID: A.userID, counter: 2, blobHash: Self.a10BlobHash, writerID: A.writerID)
    #expect(m.count == 119)
    #expect(sha(m) == "7c619f41c6468e7518ed154a7d3cc4092cd984bc894e93b3d7a7459351e18ebe")
    #expect(
      Ed25519.verify(
        publicKey: Self.dwkPub,
        signature: Self.h(
          "9fe6caedc5a099e5c208fad9e55f9b64e07d9572c04b501803268afbfc050d5a1b0c6d8917e87c5b2515abb301e139a304e9e8aab5c91364bcba822552503206"
        ), message: m))
  }

  @Test("A22 DeviceStepUpMessage; the sample DAK signature verifies")
  func a22() throws {
    let c = try StepUp.challenge(nonce: A.stepUpNonce, params: .passkeyDelete(credentialID: A.credentialID))
    let m = try SigningMessage.deviceStepUp(challenge: c, writerID: A.writerID)
    #expect(m.count == 98)
    #expect(sha(m) == "4dd3692a57c47e5a4ed330506eed12311879ef1cedc5fa7a20798827548a59a4")
    #expect(
      DAK.verify(
        publicKey: Self.dakPub,
        signature: Self.h(
          "08a85800b697f1d67e631eae9bbd7b5c334c8ab12a9d4fe23b22e285bea93240b419e2c9902201b5a0251d72126abab16ec93df005f7d8a39eabe50afb7c2c68"
        ), message: m))
  }

  @Test("A23 password, email, phrase and freeze step-up params")
  func a23() throws {
    let sh = sha256(Self.a19S)
    let addr = try EmailNorm.normalize(A.newAddress)
    #expect(addr == "maya@example.ae")
    let cases: [(StepUpParams, String, String)] = [
      (
        .passwordSet(newVerifierHash: sh), "a8b6d00338c359977557b4affe9ae18808c9042557475e686f804f24240d2242",
        "7ac70a895bc9effe81bf9df8b998a1d9982ead3bb7b5083d2e33f998f8eb478c"
      ),
      (
        .passwordChange(newVerifierHash: sh), "71e79da4e20713d241e3f74141c02f3b1d4cac608a7fdc60328112aba7936028",
        "f2cdff80e8a21b2ee4af805282b3865b68d56c3cbea97f7c8faaaf6fd37b6483"
      ),
      (
        .passwordRemove,
        "38b1eadf39badfcc5cbf27fa56a67b29ac9a87f3fbd9a4239df4bdb6afe276b3",
        "5a2f8180d615adcc6a8dca66027f6123cf2f3156c7928fe166322f7ad86d9a62"
      ),
      (
        .passwordReset(newVerifierHash: sh), "972fd0715c61e898cb74e05cea8a15693bfcc49644c792b970f2489d73ad0f3f",
        "c6177f57f949746d8cfb585cefadc74de380d207858ae144d83abe7d36d24743"
      ),
      (
        .emailChange(newEmailNorm: addr, newVerifierHash: sh),
        "917c1f970ef94b228665fa2a4dfa10de29ff3fdbb1c4dd9b89caa101d80065ef",
        "febb9ec28f7243b18968af9f38f9681441d2d61225f4cdfdb9a00407ae49a829"
      ),
      (
        .emailChange(newEmailNorm: addr, newVerifierHash: nil),
        "4e707d6e9045a6e3e98b172e285a1fde53455406edba5f594f296d3537093995",
        "deb5f9cb198cd7c49263c7d3655d068a1d63044eba7256ec3257b85a42d65129"
      ),
      (
        .phraseView, "69fb93febed80853281da2e586009820a3df214874b2472010ad1236a1e13c96",
        "5e0f69f1376552c429b9c94891141258f56c1d165cd60846342a06cfdd9c7982"
      ),
      (
        .accountFreeze, "9a0e3fa7c7b4bb2ad248bf21b53d37ede9e097866800460b1b35edc10a6fdb89",
        "d383ec9bf1bf6d16df27fe71f61c1778156cd3379a15a49af65cd30a95b5d701"
      ),
      (
        .accountUnfreeze, "5a46e00c837618abd9ba6391bdba189d676d1136bbcef39d67ca0508ac2809d0",
        "141c4d710b66a4b06e99ec39271bb28e142a59b85ad6c53a9d4a92d009d5b980"
      ),
    ]
    for (p, params, c) in cases {
      #expect(hx(StepUp.paramsHash(p)) == params, "\(p.action)")
      #expect(hx(try StepUp.challenge(nonce: A.stepUpNonce, params: p)) == c, "\(p.action)")
    }
  }

  @Test("A24 EmailChangeMessage")
  func a24() throws {
    let m = try SigningMessage.emailChange(nonce: A.stepUpNonce, newEmailNorm: try EmailNorm.normalize(A.newAddress))
    #expect(m.count == 87)
    #expect(sha(m) == "98144cc898dc7df4383d4a0119f8c1dc840e3a8cf39d1bbade98f4d1dfe27062")
    #expect(
      Ed25519.verify(
        publicKey: Self.rkPub,
        signature: Self.h(
          "0499ff4fe466802f9def4c26585db70b2d660abd0db2e08192e922560a34d134b21988ff7ba352cf3be768692c321ca24834beb701c722d9031b4ec36c281405"
        ), message: m))
  }

  @Test("A25 device-approved reset: EK, code80, ResetApprove and ResetFinish")
  func a25() throws {
    let ek = try Ed25519.publicKey(seed: A.ekSeed)
    #expect(hx(ek) == "74fca2a3b389fb1a64d9bf52cc0dd4c2964f3804c0cf7c755e8513c6db8198dc")
    #expect(hx(try ResetCode.code80(ephemeralPublicKey: ek)) == "d2e8838f66d3baba34ce")
    #expect(try ResetCode.text(ephemeralPublicKey: ek) == "2LUIHD3G2O5LUNGO")
    #expect(ResetCode.matches("2luihd3g-2o5l unGO", ephemeralPublicKey: ek))
    let approve = try SigningMessage.resetApprove(
      nonce: A.resetNonce, userID: A.userID, ephemeralPublicKey: ek, writerID: A.writerID)
    #expect(approve.count == 145)
    #expect(sha(approve) == "9a611eac0b80a4e4860ca08208baaf35b650e023a670f36db16a3ee1f756ae68")
    #expect(
      DAK.verify(
        publicKey: Self.dakPub,
        signature: Self.h(
          "dbcc5dbcb8a175e343c07710eeac8c774cfed6d2ec1b4d196387f167329790f9bd1e643b9b2673d60f7a9809ee79dc3e810e09c6add27f10f982438ef8547d1d"
        ), message: approve))
    let finish = try SigningMessage.resetFinish(nonce: A.resetNonce, newVerifier: Self.a19S)
    #expect(finish.count == 87)
    #expect(sha(finish) == "f5ee20d9be28b7140147798965d5824a7583037b6ad03d048a4bcf2865a0762d")
    #expect(
      Ed25519.verify(
        publicKey: ek,
        signature: Self.h(
          "9e8fad086eaaa4c0f6936f7e93fe4a37199c82ccfa489bb1115ccd9488c11774e9d9e4a1d19100a2e98fd06333e0bd2322aeec72d0f9017ddd3300081d0de205"
        ), message: finish))
  }

  @Test("A26 DeviceFreezeMessage, byte for byte")
  func a26() throws {
    let m = try SigningMessage.deviceFreeze(nonce: A.stepUpNonce, userID: A.userID, writerID: A.writerID)
    #expect(m.count == 113)
    #expect(
      hx(m)
        == "686173616c612f76312f6465766963652d667265657a6500f0f1f2f3f4f5f6f7"
        + "f8f9fafbfcfdfeff000102030405060708090a0b0c0d0e0f6f1c2b9e4d3a4f5b"
        + "8c7d0e1f2a3b4c5d00696f732d30613162326333642d346535662d346136622d"
        + "386337642d396530663161326233633464")
    #expect(sha(m) == "4414904713351714ebd2a291f682ec934a3428bdf1b26f8286a7b26a0569d92f")
    #expect(
      DAK.verify(
        publicKey: Self.dakPub,
        signature: Self.h(
          "152c41efcdc0adf56c663d547f6b3969730aae27048f225ce4db83f046772af690800deb095ccc52877f6852dc9ccf91f72ac78faa55627d47d85b06275e461d"
        ), message: m))
  }
}
