/**
 * The D4 conformance probe — does Gmail actually strip a forged
 * `Authentication-Results: mx.google.com` header?
 *
 * This is the ledgerd operator-decision log §9 item 5, and it is the one check the whole Gmail lane's
 * trust model rests on. It cannot run against a fake: the claim under test is a
 * statement about **Google's production mail servers**, so a fixture that
 * behaves as we hope proves nothing at all. It needs a real burner Gmail.
 *
 * # What D4 assumes
 *
 * `client/src/mail/authres.ts` believes a DKIM/DMARC verdict when the fetched
 * bytes carry exactly one `Authentication-Results` header whose authserv-id is
 * `mx.google.com`, and it precedes every other A-R. That is sound ONLY because
 * RFC 8601 §5 requires a receiving ADMD to delete incoming A-R headers claiming
 * its own authserv-id — otherwise anyone who can send mail to the burner could
 * embed `dkim=pass header.d=yourbank.example` and be believed.
 *
 * The design spec (§1, D4) says in as many words that it "does not assume Gmail
 * conforms", and makes this probe a precondition of the fetch lane. Until it
 * runs, the lane's soundness is an assumption, not a fact.
 *
 * # Running it
 *
 *   1. Compose the probe message:
 *        bun harness/d4probe.mjs compose --bank yourbank.example > /tmp/d4.eml
 *
 *   2. Send it to the burner FROM OUTSIDE GOOGLE, so it crosses Gmail's inbound
 *      MX — that crossing is the whole point. Any host that can talk SMTP:
 *        python3 - <<'EOF'
 *        import smtplib
 *        smtplib.SMTP("smtp.example.net", 587)  # your own outbound relay
 *        EOF
 *      A message composed in Gmail, or inserted via the API, DOES NOT TEST
 *      ANYTHING — it never passes the inbound MX, so nothing would strip it and
 *      a "fail" here would be an artefact of how it was delivered.
 *
 *   3. Inspect what Gmail stored, with an access token for the burner:
 *        bun harness/d4probe.mjs inspect --token "$ACCESS_TOKEN"
 *
 *      A token is one broker call from a connected device, or from the OAuth
 *      playground with scope https://www.googleapis.com/auth/gmail.readonly.
 *
 * # Reading the result
 *
 *   PASS      — the forgery is gone, one genuine `mx.google.com` A-R remains
 *               topmost. D4 holds. Record it in the plan's task report.
 *   FAIL-OPEN — the forgery SURVIVED and is topmost. Catastrophic: the parser
 *               would believe an attacker's `header.d`. The fetch lane must be
 *               taken to everything-needs-review until D4 is replaced.
 *   FAIL-SHUT — the forgery survived but is not alone/topmost. The parser
 *               refuses it (`multiple_ar` / `not_topmost`), so nothing is
 *               believed wrongly — but Gmail is NOT stripping, so the trust
 *               primitive rests on ordering alone and D4 must be re-argued.
 */

import { parseArgs } from "node:util";

const PROBE_SUBJECT = "ledger D4 conformance probe";
const GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me";

/** The forged header, byte-for-byte what an attacker would embed. */
function forged(bank) {
  return `Authentication-Results: mx.google.com; dkim=pass header.d=${bank}; dmarc=pass header.from=${bank}`;
}

/**
 * A harmless header sent beside the forgery, to tell two outcomes apart.
 *
 * If neither the forgery nor this marker arrives, the sending path rewrote the
 * headers and the probe proves nothing about what Gmail's inbound MX does. If
 * this marker arrives and the forgery does not, then custom headers DO survive
 * that path, and the A-R was removed specifically. Without the marker those two
 * cases look identical, and the second one would be read as a PASS it did not
 * earn.
 */
const MARKER_HEADER = "X-Ledger-D4-Probe";

function compose(bank, to, from) {
  // The forgery goes FIRST, which is the strongest form of the attack: if Gmail
  // prepends its own A-R without stripping this one, an ordering-only rule that
  // read "the first mx.google.com header" would read the attacker's.
  return [
    forged(bank),
    `${MARKER_HEADER}: control-header-sent-beside-the-forgery`,
    // The sender is the ATTACKER'S own domain, not the bank's. That is the
    // real shape of the attack: an attacker cannot sign as the bank, so they
    // send from a domain they control and forge the verdict header to claim
    // the bank passed. A probe that also spoofed `From:` would be rejected
    // before it proved anything.
    `From: ledger probe <${from}>`,
    `To: ${to}`,
    `Subject: ${PROBE_SUBJECT}`,
    "Date: " + new Date().toUTCString(),
    "MIME-Version: 1.0",
    'Content-Type: text/plain; charset="utf-8"',
    "",
    "This message carries a forged Authentication-Results header claiming",
    "mx.google.com as its authserv-id. If Gmail conforms to RFC 8601 section 5,",
    "the forgery is deleted before the message is stored.",
    "",
  ].join("\r\n");
}

async function gmailGet(path, token) {
  const res = await fetch(`${GMAIL}${path}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!res.ok) {
    throw new Error(`gmail ${path} -> ${res.status} ${await res.text()}`);
  }
  return res.json();
}

/** Every Authentication-Results header, in order, with its authserv-id. */
function arHeaders(raw) {
  // Unfold continuation lines first: a folded A-R is one logical header, and
  // treating its continuation as a separate line would miscount them.
  const unfolded = raw.replace(/\r?\n[ \t]+/g, " ");
  const out = [];
  for (const line of unfolded.split(/\r?\n/)) {
    if (line === "") break; // end of headers
    const m = /^Authentication-Results:\s*(.*)$/i.exec(line);
    if (m === null) continue;
    const authservId = m[1].split(";")[0].trim();
    out.push({ authservId, value: m[1] });
  }
  return out;
}

/** The verdict, from the raw RFC822 bytes. Shared by `inspect` and `classify`. */
function classify(raw) {
  const found = arHeaders(raw);
  const google = found.filter((h) => h.authservId.toLowerCase() === "mx.google.com");
  const markerSurvived = new RegExp(`^${MARKER_HEADER}:`, "im").test(
    raw.replace(/\r?\n[ \t]+/g, " ").split(/\r?\n\r?\n/)[0] ?? "",
  );

  console.log(`Authentication-Results headers found: ${found.length}`);
  for (const [i, h] of found.entries()) {
    console.log(`  [${i}] ${h.authservId}`);
    console.log(`      ${h.value.slice(0, 200)}`);
  }
  console.log(`control marker (${MARKER_HEADER}) survived: ${markerSurvived ? "YES" : "no"}`);
  console.log("");

  const topmostIsGoogle = found.length > 0 && found[0].authservId.toLowerCase() === "mx.google.com";

  if (google.length > 1) {
    console.log(`FAIL — ${google.length} mx.google.com A-R headers survived.`);
    console.log("Gmail did NOT strip the forgery.");
    console.log("The parser refuses multiple_ar, so it fails SHUT rather than open,");
    console.log("but D4's premise is false: take the fetch lane to");
    console.log("everything-needs-review until the primitive is replaced.");
    return 1;
  }
  if (google.length === 1 && topmostIsGoogle) {
    if (!markerSurvived) {
      // The distinction the marker exists for.
      console.log("INCONCLUSIVE — one mx.google.com A-R, and it is topmost, BUT the");
      console.log("control marker did not survive either. The sending path rewrote the");
      console.log("headers, so this run does not show what Gmail's inbound MX did with");
      console.log("the forgery. Re-send through a path that preserves custom headers.");
      return 2;
    }
    console.log("PASS — exactly one mx.google.com A-R, and it is topmost.");
    console.log("Custom headers DID survive this path (the control marker arrived),");
    console.log("so the forgery was removed specifically, not lost in transit.");
    console.log("D4 holds for this delivery path. Record it in the task report.");
    return 0;
  }
  if (google.length === 1) {
    console.log("FAIL-SHUT — one mx.google.com A-R, but another A-R precedes it.");
    console.log("The parser returns not_topmost and refuses to trust. Nothing is");
    console.log("believed wrongly, but re-argue D4 before relying on it.");
    return 1;
  }
  console.log("FAIL-OPEN — no genuine mx.google.com A-R was added at all.");
  console.log("Whatever is topmost is what the parser would read. Treat as unsound.");
  return 1;
}

async function inspect(token) {
  const list = await gmailGet(
    // `in:anywhere` reaches Spam and Trash, which a default search does NOT.
    // A message that carries a forged authentication header and fails SPF is
    // very likely to land in Spam — so without this the probe would report
    // "no probe message found" for the delivery most likely to happen, and
    // read as inconclusive when the evidence was sitting there.
    `/messages?q=${encodeURIComponent(`in:anywhere subject:"${PROBE_SUBJECT}"`)}`,
    token,
  );
  const ids = (list.messages ?? []).map((m) => m.id);
  if (ids.length === 0) {
    console.error(
      `no probe message found. Send one first (see this file's header), and note\n` +
        `it must arrive from OUTSIDE Google so it crosses Gmail's inbound MX.`,
    );
    process.exit(2);
  }

  // Newest first is Gmail's list order; take the most recent probe.
  const msg = await gmailGet(`/messages/${encodeURIComponent(ids[0])}?format=raw`, token);
  const bytes = Buffer.from(msg.raw, "base64url");
  const raw = bytes.toString("utf8");

  console.log(`probe message id: ${ids[0]}`);
  process.exit(classify(raw));
}

const { values, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    bank: { type: "string", default: "yourbank.example" },
    to: { type: "string", default: "your-burner@gmail.com" },
    from: { type: "string", default: "probe@example.invalid" },
    token: { type: "string" },
    file: { type: "string" },
  },
});

const mode = positionals[0];
if (mode === "compose") {
  process.stdout.write(compose(values.bank, values.to, values.from));
} else if (mode === "inspect") {
  if (values.token === undefined) {
    console.error("inspect needs --token <gmail access token>");
    process.exit(2);
  }
  await inspect(values.token);
} else if (mode === "classify") {
  // The same verdict, over bytes fetched some other way — IMAP, say, for a
  // mailbox whose OAuth token is not to hand. The classification must not
  // depend on HOW the bytes were retrieved, only on what Gmail stored.
  if (values.file === undefined) {
    console.error("classify needs --file <path to raw RFC822 bytes>");
    process.exit(2);
  }
  const { readFileSync } = await import("node:fs");
  process.exit(classify(readFileSync(values.file, "utf8")));
} else {
  console.error("usage: d4probe.mjs compose [--bank d] [--to a]");
  console.error("     | inspect --token <access token>");
  console.error("     | classify --file <raw.eml>");
  console.error("read this file's header before running any of them.");
  process.exit(2);
}
