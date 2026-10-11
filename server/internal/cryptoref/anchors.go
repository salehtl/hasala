package cryptoref

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"encoding/hex"
	"math/big"
	"strings"

	"github.com/google/uuid"
)

// The anchor inputs of spec 01 §15.5. Every generator and test in this tree
// that reproduces an anchor takes its inputs from here, so an input can never
// differ between the file that writes a vector and the test that pins it.

// Range is the run of consecutive byte values a, a+1, …, b (spec 01 §1's
// "x..y"), wrapping at 0xff.
func Range(a, b byte) []byte {
	var out []byte
	for v := a; ; v++ {
		out = append(out, v)
		if v == b {
			return out
		}
	}
}

// Hex decodes a hex string that may contain spaces or newlines; it panics on
// bad input (anchors are constants).
func Hex(s string) []byte {
	b, err := hex.DecodeString(strings.Join(strings.Fields(s), ""))
	if err != nil {
		panic(err)
	}
	return b
}

// Anchor inputs (spec 01 §15.5, "Inputs").
var (
	AnchorUser           = uuid.MustParse("6f1c2b9e-4d3a-4f5b-8c7d-0e1f2a3b4c5d")
	AnchorWriterID       = "ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
	AnchorE              = Hex("9e885d952ad362caeb4efe34a8e91bd2")
	AnchorAMK            = Range(0x40, 0x5f)
	AnchorAAKSeed        = Range(0x60, 0x7f)
	AnchorDWKSeed        = Range(0x80, 0x9f)
	AnchorP              = Range(0xc0, 0xdf)
	AnchorCredentialID   = Range(0x01, 0x10)
	AnchorRecoverySalt   = Range(0x10, 0x2f)
	AnchorRecoveryNonce  = Range(0xa0, 0xab)
	AnchorPRFSalt        = Range(0x30, 0x4f)
	AnchorPRFNonce       = Range(0xb0, 0xbb)
	AnchorFrameNonce1    = Range(0xd0, 0xdb)
	AnchorFrameNonce2    = Range(0xe0, 0xeb)
	AnchorStepUpNonce    = append(Range(0xf0, 0xff), Range(0x00, 0x0f)...)
	AnchorWriterNonce    = Range(0x50, 0x6f) // also C1-P's signup nonce (A14-P)
	AnchorRegisterNonce  = Range(0x20, 0x3f)
	AnchorLoginChallenge = Range(0x70, 0x8f)
	AnchorRecoverNonce   = Range(0x90, 0xaf)
	AnchorAttestation    = Range(0x00, 0x3f)
	AnchorClientDataJSON = []byte(`{"type":"webauthn.create","challenge":"AAAA","origin":"https://hasala.app"}`)
	AnchorDAKScalar      = Range(0x01, 0x20)
	AnchorSaltKey        = Range(0x11, 0x30)
	AnchorAuthKeyA19     = Range(0x11, 0x30) // A19: the same bytes as salt_key
	AnchorAuthKeyA19K    = Range(0x31, 0x50) // A19-K: keys apart
	AnchorEmailInput     = "  Maya.Rahman+Hasala@Gmail.COM "
	AnchorPasswordNFD    = "Hasala cafe\u0301 2026!"
	AnchorPasswordNFCHex = "486173616c6120636166c3a9203230323621"
	AnchorPWSalt         = Range(0xa0, 0xaf)
	AnchorBoxNonce       = Range(0xf0, 0xfb)
	AnchorCodeID         = uuid.MustParse("0f1e2d3c-4b5a-4968-8776-655443322110")
	AnchorCodePurpose    = "password_reset"
	AnchorCode           = "042817"
	AnchorEKSeed         = Range(0xb0, 0xcf)
	AnchorResetNonce     = Range(0x10, 0x2f)
	AnchorNewEmailInput  = "Maya@Example.AE"
	AnchorRotateE        = bytes.Repeat([]byte{0x80}, 16) // A18: E' = 80×16
	AnchorRotateWrap     = Range(0x11, 0x8f)              // A18: the new wrap, 127 B
)

// AnchorDAK is the P-256 key whose private scalar is 01..20 (A13's public key).
func AnchorDAK() *ecdsa.PrivateKey {
	c := elliptic.P256()
	d := new(big.Int).SetBytes(AnchorDAKScalar)
	x, y := c.ScalarBaseMult(AnchorDAKScalar)
	return &ecdsa.PrivateKey{PublicKey: ecdsa.PublicKey{Curve: c, X: x, Y: y}, D: d}
}

// AnchorDAKPub is A13's DAK.pub, X9.63 uncompressed.
func AnchorDAKPub() []byte {
	k := AnchorDAK()
	out := []byte{0x04}
	out = append(out, k.X.FillBytes(make([]byte, 32))...)
	return append(out, k.Y.FillBytes(make([]byte, 32))...)
}

// Anchor outputs (spec 01 §15.5, "Outputs"), as printed. Keys are the anchor
// id and a short field name.
var Anchors = map[string]string{
	"A01 PRF_SALT":   "6bd5a9ebcc65e64bfab48f34528496a6449975b922e87a7ac79518c742170d01",
	"A02 phrase":     "ozone drill grab fiber curtain grace pudding thank cruise elder eight picnic",
	"A03 RK_seed":    "bd4572ae0cb80d9c07f9221c0c992c6a6e3fc00a7b766dc7fa732227af4130c8",
	"A03 RK.pub":     "011b14200fa13205fe88feed06b6cef5a94bc07e8dfb89e2e97f1344071b1d7d",
	"A04 AAK.pub":    "174553b456dddfc6908ecab1c101fe6ab21e2baa0617795b7d43a63482993fd5",
	"A04 DWK.pub":    "cd14b37f956e953194ff7fb73b3d81dcc561d61a7538094b7c3e1a643ee5f3aa",
	"A05 amk_commit": "68e63be415f5e196e693f3da355d60eea5cf0c1168adea750c02b0185c2aaa22",
	"A06 K_1":        "c2e59f467f32b6e843710e8f959c186013d2d2fe94ec883c64ebfa3155f8e188",
	"A07 RWK":        "d2536aa0185606de0d738686bacd1be63b86cf4585709cc6db805376853bd800",
	"A07 recovery_wrap": "0101101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f" +
		"a0a1a2a3a4a5a6a7a8a9aaab9cc42943bdaccb4dc8d3fbb3fe281a79cae618d515afae" +
		"61cb83a9e01c8642b1141550501c3db96f4366ecf56398553edbcb4c773f882291c2d0" +
		"ce2eeed5b9d8c42df492f96ec29ca9ff6fd42f0da6cff7",
	"A08 PWK": "f77bcc6418fafe78e1f05fb437199d52d7610165c0ee33d104f3d4937fcd3f9c",
	"A08 prf_wrap": "0102303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f" +
		"b0b1b2b3b4b5b6b7b8b9babbb4e485f01140d0951848802d29d3d798473bec7ef5ab28" +
		"12782a13c7287a3d8ae99619d45466e0b697de90955e7de5b1e18df74758f9e2abe7d9" +
		"0788fabf48d7be9a3312e49484bb29373052401ad028ef",
	"A09 header": "0300000001005336663163326239652d346433612d346635622d386337642d306531" +
		"6632613362346335647c686f747c696f732d30613162326333642d346535662d3461" +
		"36622d386337642d3965306631613262336334647c31",
	"A09 SHA256(AD)":                 "2485727d9cc32680ca4519b03301855757c0bcd0eb252022113b172b6755aa31",
	"A09 K_blob":                     "86b19ef7697c451eba5aa36bf7296de24c4feba11d5cbb6079aa03214597aabd",
	"A09 ct[0:16]":                   "9438cfe68d4a955181d8c18f408556c3",
	"A09 tag":                        "420dd0db074a3bb3b5ba33dd3feb49a2",
	"A09 SHA256(frame)":              "8aff44368ce9015d29617089fbc81ddf7176626d04f41be297189cca90b4c708",
	"A09 blob_hash":                  "baf51ed04dd41eb700cf8ba0467411befaa4494dc6033688e7e9670e3570292f",
	"A10 K_blob":                     "da2cd8d053e2129d99e76459682f1c5644ba543879bbd722598aadf078d11753",
	"A10 tag":                        "67412fe8521354551b47038661c7aeb1",
	"A10 SHA256(frame)":              "c2357f3d9071227ffe86f8a8b7f1110afcbe51b2ed8e3692b7191e9a961c5418",
	"A10 blob_hash":                  "cee22837f339529583565b5de892c0783314923db66a5fdf4432590bec301b3d",
	"A11 enc(cred)":                  "000000100102030405060708090a0b0c0d0e0f10",
	"A11 params passkey.delete":      "7686789f2d3f75ea516987626f0da957e1e04998a6f5797b5d3153321ac449b5",
	"A11 C passkey.delete":           "20f8bbc4410b52bef9b467a00dcf8313777d3dd8afea81a22bd7fb09d6d97b79",
	"A11 params session.logout_all":  "feec00bcd26e8dda1501ae355f6057831a4c7c1069c04080359d023da70fc84c",
	"A11 C session.logout_all":       "620e8efa0c5b068d7385582c1c97f76f789c0d9d6d6ca220b4d792f7248aa717",
	"A11 params keys.bootstrap":      "2ca5b81b21d38d25acc0e7a2d67cc21de22ec4d80970b057de8e87a0da720cf7",
	"A11 C keys.bootstrap":           "ff9ba915366a6b698c8748c98784e6a0a6fc7ab36d2f60ebe63b1103d316782c",
	"A11 params account.delete":      "4f663475064aa7fb55648bf8b26a3534728987013c93208fdf2fcf7ea1a3180b",
	"A11 C account.delete":           "d819d9ababfbdc54b1758aa770d0b097a6490c8c3a77eef4771e4a2718f63eb2",
	"A12 C_reg":                      "6c4baf6196d04c602ba74784866cf12d34d518bfedd63f2f14d6d2d9b91ffd3e",
	"A13 DAK.pub":                    "04515c3d6eb9e396b904d3feca7f54fdcd0cc1e997bf375dca515ad0a6c3b4035f4536be3a50f318fbf9a5475902a221502bef0d57e08c53b2cc0a56f17d9f9354",
	"A13 SHA256":                     "688a20d5661d707d09ccfa6a384e5d0eba641377a77437b1d5d1037066b292a7",
	"A13 AAK sig":                    "0021a4d3606fe175df135861cfa90cc77f39bd22866ec0631147ebeb846b78248b4244dc83efc4715a15ae271f5fdc8c8c4891ed255fcf18ea94c0138879ab0d",
	"A14 SHA256(payload)":            "15663ec145c6fac5a3743b7e9c76cff6dbe80520a6b92f49870b017d6792d1c8",
	"A14 SHA256(BootstrapMessage)":   "959d895fe96b5b02593d3ef2aa3fe905112b7e2f88888a422287ede0453c2c8c",
	"A14 AAK sig":                    "f90856a3ffb6b798a40f7aaf51b62c4881b2167294f823e7659c6e45a6a1cae49c0c315424ef0f6eb9d9dda4c36fdb054fee4644d14aa8b08753e5c544f3d70d",
	"A14-P SHA256(payload)":          "831b7aa7fac401971227aea692f12b3f533e68e203546e15f4dbf7f38fd4c3b8",
	"A14-P SHA256(BootstrapMessage)": "730469bf7a6a9842045cd9cdd8be5004a01d678a7ef44cbe0468e9df1f9a25d1",
	"A14-P AAK sig":                  "0931c86dc9f9dddf610d50fd3fd4a3a959e883b27fc31ebb04769f9ec7553bcdeeb17bbd0178001a7cf0377a9bee7503439aa27cbf5b692433e5357a76118b03",
	"A15 SHA256":                     "4ba686ac12eb6ff61fd95c9c085546651d6ada83cafd84438fe52864bccb4409",
	"A15 DWK sig":                    "dab2b343bf60045d4411110dea3ace1c6c57dcd6940f1c51d45db3c262d265257b7eb22b7d27b402312bd7cc9032930f2af4d7c0712db7e42dc3f9bd9c9b7100",
	"A15 SHA256(DeletionMessage)":    "ef962c66923f1cea34ca06218ffeec5e050c2e108502933495ef6ee1aefd1e7a",
	"A16 SHA256":                     "6d72c9719e29a0cdd21dce1b65bdf3345f5b226c898cd69ea31033006e7dfc44",
	"A16 DWK sig":                    "61000688ced4db1f0e16a998c66ec24a644b86d04f38ce85a2ad6c788d44038a8a6a1b45f58006894972e5f35e7419966a12aed282421062d2414559c199f00c",
	"A17 SHA256":                     "aa10f54f7b1803ef2f612a98bad651979e9ced9c4d731aa11e85d4a656c4954d",
	"A17 RK sig":                     "bd9a2c8db7134972f11aadfb19acfb0a0d8907616a47c0de3178c84c00a6e221b1744e04a9b13af63f9b7377913ce0d6359ab30d295e22b7fed6cc3f817cfe05",
	"A17 SHA256 no PRF wrap":         "92446a72eb039ebbce55d9e63e1f76a2d38dbca9c94a61cefeb1f0957dab844d",
	"A17 SHA256 password":            "b310740ced78f61b183bd39b3af7b944c0a0d3d85df2a625a42a085486e33aec",
	"A17 RK sig password":            "b3a35450d10c1ea56e4009e21993d2fd6a8e81af490a5a81099942a6c7c56f069de9cf6c49ac5b0f5b549138fd15505600b4e4d3b517f7e480eb1587967a700a",
	"A18 RK'.pub":                    "21751a01ea5863cde7576580c8b3e685ad5d57b42856b882bcf7d59ec119f308",
	"A18 new phrase_box":             "01f0f1f2f3f4f5f6f7f8f9fafbed85873e09a697b969fabdbd7aa0e523d1a4758be33f023d6ba5f9a86baaeb65",
	"A18 SHA256":                     "0d1f00191fa1124551412b38930d1bf6bc84169f67325a8d8b89c161d83a2854",
	"A18 AAK sig":                    "d93da013c1b02072a362bdc1523281c0503a104106f68a9ec0bd039fd3636c379defa63c206c658695a0823c381fc9cece715e99e859b54014c20418d9aebd05",
	"A18 params recovery-rotate":     "af6881cb23865fa9166f64da4b42c7b6a346f43d413f2738df5dc04177819ba3",
	"A19 K_salt":                     "248de31e3491cc548e63a8f05c7bd945c6c2845de96ce5870cb90deb0594f479",
	"A19 K_pepper":                   "3a77f4a685ba3d258457446f847322fb851278b7143f364f7b3ea959b1e5be52",
	"A19 K_code":                     "ed9f25497d0517584f83203aae713cca83934b308a45ac89755c0a01973afe49",
	"A19 K_tag":                      "085f6fe9c3db0ea7fe445fd4cc53f203fde9ed69f19711f2c95c88137471f81f",
	"A19 auth_key_id":                "03be86c86f5c0987",
	"A19 email_norm":                 "maya.rahman+hasala@gmail.com",
	"A19 email_hash":                 "6856c023e016e2a03b5ef29b0885b6d4d67e727c19138fed7c5048d41dedeeac",
	"A19 email_tag":                  "c213f4c1a7877e8ae1d5b83f69a59c28363d320dbb149eb3c9487737bca17b8a",
	"A19 s_srv":                      "44b6d3bbf924d4988797f591a3532a88455b2a75ea88d9ad647f736e100e5db6",
	"A19 S":                          "82da856ee5beea8425653d8ba0e280eb8640e4cfe91010b0588434259c6f1e88",
	"A19 SHA256(S)":                  "6b2e179e793c2fb3450b56ed96e237c6e661441ce10834a8127edb696cf5bd12",
	"A19 HMAC(K_pepper, S)":          "03a50fa0277e5cd716367205f9dbca3a6e858e855a3c0f5f4f5b8c5577ea8ca1",
	"A19 pw_hash":                    "1a52b4928b8afbb0530365a47030bc55c94f8e19289e95f5854c62df10ccd568",
	"A19 code_mac":                   "1d600ed6f4e79f3e7706bc4f4274af7a8dfab898620fc780f83554d89b02b721",
	"A19 K_pv":                       "d02f4066e537419b47f48789776a2261caa5a071f12337819707f764b69a8447",
	"A19 phrase_box":                 "01f0f1f2f3f4f5f6f7f8f9fafbf38d5a2ba3f575f30234c30952c97e71eb7a777ba708e40165b9f1408ecb37fe",
	"A19-K s_srv":                    "44b6d3bbf924d4988797f591a3532a88455b2a75ea88d9ad647f736e100e5db6",
	"A19-K salt_key_id":              "03be86c86f5c0987",
	"A19-K K_pepper":                 "aee2a77f0c3827d6c06bb2d239baf1c53788bc58084aebc86d81db8ad6d39985",
	"A19-K K_code":                   "7d03066d1b664157152763169f09619f1f5594cbb8aebd3dd7165a5ca0f48ca5",
	"A19-K K_tag":                    "90def03ca93eb9496264988e3619db9e1f00988759b04003fd77593be680f4b5",
	"A19-K auth_key_id":              "987df2f4eff01510",
	"A19-K email_tag":                "c77bed03efbe7558c40f4ac9d312abd7cd871f1db5becec7bcd8dbb85584b652",
	"A19-K HMAC(K_pepper, S)":        "f848425cdfb0a008b16296b18285256aff3bc064c5a9b229b9c76743a98f452e",
	"A19-K pw_hash":                  "3d47bda72857d6944ea68175c69f62b213f61a9bd5e25b931cbab4558eba7d97",
	"A19-K code_mac":                 "7f40507fd64bd6eefa92d6767dfaa93f29f0e33013bdbcee3f784663bb1b2779",
	"A20 SHA256 PasskeyAdd":          "6342d493bc9c962539d9bb3fbff660d8ee5eb447774e16d3c352310e476a8b1a",
	"A20 DWK sig PasskeyAdd":         "3cc6c9e7324e351b37dc8fec7cac5f8cd1ce90880fe5445f667ea8a5b3ffe9d5106388a41edaddb2451334d81cec033d3c2759fe8e30390d6bba59cce70ff00a",
	"A20 SHA256 WrapPut":             "25b2edd8e4c52cffeed739dde5b4c34e7c2c9d2419de21cf8afa6a7894cfdbb3",
	"A20 DWK sig WrapPut":            "3a57246c0d36744d88773ba41569e6df1c25601c357445a6003bce00050a56aa3213101376e10781335a07155d777242c9f259896bae57b638d41c33348f7d0d",
	"A21 SHA256":                     "7c619f41c6468e7518ed154a7d3cc4092cd984bc894e93b3d7a7459351e18ebe",
	"A21 DWK sig":                    "9fe6caedc5a099e5c208fad9e55f9b64e07d9572c04b501803268afbfc050d5a1b0c6d8917e87c5b2515abb301e139a304e9e8aab5c91364bcba822552503206",
	"A22 SHA256":                     "4dd3692a57c47e5a4ed330506eed12311879ef1cedc5fa7a20798827548a59a4",
	"A22 DAK sig":                    "08a85800b697f1d67e631eae9bbd7b5c334c8ab12a9d4fe23b22e285bea93240b419e2c9902201b5a0251d72126abab16ec93df005f7d8a39eabe50afb7c2c68",
	"A23 params password.set":        "a8b6d00338c359977557b4affe9ae18808c9042557475e686f804f24240d2242",
	"A23 C password.set":             "7ac70a895bc9effe81bf9df8b998a1d9982ead3bb7b5083d2e33f998f8eb478c",
	"A23 params password.change":     "71e79da4e20713d241e3f74141c02f3b1d4cac608a7fdc60328112aba7936028",
	"A23 C password.change":          "f2cdff80e8a21b2ee4af805282b3865b68d56c3cbea97f7c8faaaf6fd37b6483",
	"A23 params password.remove":     "38b1eadf39badfcc5cbf27fa56a67b29ac9a87f3fbd9a4239df4bdb6afe276b3",
	"A23 C password.remove":          "5a2f8180d615adcc6a8dca66027f6123cf2f3156c7928fe166322f7ad86d9a62",
	"A23 params password.reset":      "972fd0715c61e898cb74e05cea8a15693bfcc49644c792b970f2489d73ad0f3f",
	"A23 C password.reset":           "c6177f57f949746d8cfb585cefadc74de380d207858ae144d83abe7d36d24743",
	"A23 params email.change":        "917c1f970ef94b228665fa2a4dfa10de29ff3fdbb1c4dd9b89caa101d80065ef",
	"A23 C email.change":             "febb9ec28f7243b18968af9f38f9681441d2d61225f4cdfdb9a00407ae49a829",
	"A23 params email.change empty":  "4e707d6e9045a6e3e98b172e285a1fde53455406edba5f594f296d3537093995",
	"A23 C email.change empty":       "deb5f9cb198cd7c49263c7d3655d068a1d63044eba7256ec3257b85a42d65129",
	"A23 params phrase.view":         "69fb93febed80853281da2e586009820a3df214874b2472010ad1236a1e13c96",
	"A23 C phrase.view":              "5e0f69f1376552c429b9c94891141258f56c1d165cd60846342a06cfdd9c7982",
	"A23 params account.freeze":      "9a0e3fa7c7b4bb2ad248bf21b53d37ede9e097866800460b1b35edc10a6fdb89",
	"A23 C account.freeze":           "d383ec9bf1bf6d16df27fe71f61c1778156cd3379a15a49af65cd30a95b5d701",
	"A23 params account.unfreeze":    "5a46e00c837618abd9ba6391bdba189d676d1136bbcef39d67ca0508ac2809d0",
	"A23 C account.unfreeze":         "141c4d710b66a4b06e99ec39271bb28e142a59b85ad6c53a9d4a92d009d5b980",
	"A24 SHA256":                     "98144cc898dc7df4383d4a0119f8c1dc840e3a8cf39d1bbade98f4d1dfe27062",
	"A24 RK sig":                     "0499ff4fe466802f9def4c26585db70b2d660abd0db2e08192e922560a34d134b21988ff7ba352cf3be768692c321ca24834beb701c722d9031b4ec36c281405",
	"A25 EK.pub":                     "74fca2a3b389fb1a64d9bf52cc0dd4c2964f3804c0cf7c755e8513c6db8198dc",
	"A25 code80":                     "d2e8838f66d3baba34ce",
	"A25 code":                       "2LUIHD3G2O5LUNGO",
	"A25 SHA256 ResetApprove":        "9a611eac0b80a4e4860ca08208baaf35b650e023a670f36db16a3ee1f756ae68",
	"A25 DAK sig ResetApprove":       "dbcc5dbcb8a175e343c07710eeac8c774cfed6d2ec1b4d196387f167329790f9bd1e643b9b2673d60f7a9809ee79dc3e810e09c6add27f10f982438ef8547d1d",
	"A25 SHA256 ResetFinish":         "f5ee20d9be28b7140147798965d5824a7583037b6ad03d048a4bcf2865a0762d",
	"A25 EK sig":                     "9e8fad086eaaa4c0f6936f7e93fe4a37199c82ccfa489bb1115ccd9488c11774e9d9e4a1d19100a2e98fd06333e0bd2322aeec72d0f9017ddd3300081d0de205",
	"A26 bytes": "686173616c612f76312f6465766963652d667265657a6500f0f1f2f3f4f5f6f7" +
		"f8f9fafbfcfdfeff000102030405060708090a0b0c0d0e0f6f1c2b9e4d3a4f5b" +
		"8c7d0e1f2a3b4c5d00696f732d30613162326333642d346535662d346136622d" +
		"386337642d396530663161326233633464",
	"A26 SHA256":  "4414904713351714ebd2a291f682ec934a3428bdf1b26f8286a7b26a0569d92f",
	"A26 DAK sig": "152c41efcdc0adf56c663d547f6b3969730aae27048f225ce4db83f046772af690800deb095ccc52877f6852dc9ccf91f72ac78faa55627d47d85b06275e461d",
}
