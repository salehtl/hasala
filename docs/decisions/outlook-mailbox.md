# Outlook mailbox: how the phone lists, trusts and fetches mail (WP1)

**Status: DECIDED from Microsoft's documentation; the items marked UNVERIFIED wait for
the owner's test mailbox (WP0).** This file is the WP1 spike of the Outlook plan. WP2
(the trust rule and its conformance vectors) and WP5b (the Graph client) build on it.

Scope: personal Microsoft accounts only (`consumers` tenant), Microsoft Graph v1.0, no
MSAL. The rules of the Gmail lane still hold: the phone lists only mail from the trusted
sender set, nothing that is unproven is trusted, and nothing is dropped silently (an
untrusted message goes to review).

Every example in this file is synthetic (`bank.example`, `alerts.bank.example`,
`evil.example`). No real mail, address, amount or name was used, because the WP0 mailbox
does not exist yet. A claim that needs real mail to confirm is marked **UNVERIFIED** and
has a numbered check in [Checks for the owner](#checks-for-the-owner-wp0).

## Summary of decisions

| # | Decision | Status |
|---|---|---|
| 1a | ~~List with `endswith` per trusted domain.~~ **Replaced by 1d (2026-10-20).** | **Refused**: L1 on the owner's Outlook.com mailbox answered 400 `ErrorInvalidUrlQueryFilter`. |
| 1b | The phone re-checks every listed `from` address against the group and refuses the page if one is outside it. | Decided (defence against Graph ignoring a filter silently, which Microsoft documents as possible). |
| 1c | Keep the Gmail overlap: re-list from watermark − 2 days (`BankDomains.overlapMs`). | Decided. "No index lag for `$filter`" is **UNVERIFIED** (L6); the overlap covers it either way. |
| 1d | List with `$filter` on `/me/messages`: `receivedDateTime ge <since>` AND an `or` of `from/emailAddress/address eq '<address>'`, one per known bank sender address (`OutlookSenders.known`) whose domain is in the trusted set. Never fall back to `$search`. | **In use (2026-10-20).** `eq` answered 200 and listed the owner's DIB alerts. |
| 2 | No change detector replaces `historyId`. Every cycle runs the filtered list. | Confirmed from docs (delta lists every message in a folder, so it breaks PO G). |
| 3 | ~~Trust only the single Microsoft-form `Authentication-Results` (no authserv-id), when it is the topmost A-R, the EOP-only headers prove inbound EOP processing, and it reports `compauth=pass` + `dmarc=pass` for the `From:` domain.~~ **Replaced by 3a (2026-10-20).** The rule stays in the code as the reading of the owner's checks. | Its two premises (EOP always stamps one A-R at the top; `$value` keeps header order) are **UNVERIFIED** (C1–C7). The lane does not use it. |
| 3a | Take a message as the bank's when its one `From` address is a known bank sender address, Graph has it in the Inbox, and the `From` domain publishes DMARC `p=reject` (a bundled list). Do not read Microsoft's verdict or the EOP fields. Else `needs_review`, with the reason code. | **Decided (2026-10-20), waits for the owner's approval of the residual risk (§3a).** Folder ids (L8) and Junk delivery of a spoof (C8) are **UNVERIFIED**. |
| 4a | Read trust headers and the body from `GET /me/messages/{id}/$value` only. Do not use `internetMessageHeaders` for trust. | Decided. Header order in `$value` is **UNVERIFIED** (C4). |
| 4b | Send `Prefer: IdType="ImmutableId"` on every Graph request. The provenance message id is the immutable id. | Confirmed from docs. Support on consumer mailboxes is **UNVERIFIED** (L7). |
| 5 | At most 3 concurrent Graph requests per mailbox. On 429/503 honour `Retry-After` (stop the run, keep the watermark); without it, use the engine's backoff. | Confirmed from docs (4 concurrent, 10,000 per 10 min). |
| 6a | id_token: check `iss`, `tid`, `aud`, `nonce`, `iat`. Take the address from `email`; there is no `email_verified`. `preferred_username` and `oid` are **absent** with the contract's scopes (they need `profile`). | Confirmed from docs. Contract change requested (see below). Presence of `email` on the test account is **UNVERIFIED** (I1). |
| 6b | Register `msauth.app.hasala.ios://auth` under the **Mobile and desktop applications** platform, not iOS/macOS. | Confirmed from docs (correction to WP0). End-to-end redirect is **UNVERIFIED** (I2). |
| 6c | Subscription: `me/mailFolders('inbox')/messages` (the inbox only, as Gmail's watch is), `created`, at most 10,080 min (ask for 10,020); validate both URLs; handle `409 Conflict` on takeover by listing and deleting the app's old subscription. A subscription an older build made on `me/messages` is deleted and made again on the inbox at its next renewal. | Confirmed from docs. **Changed (2026-10-20)** from `me/messages`, which also woke hasalad for sent mail and drafts. |
| 6d | The listing selects `parentFolderId`. A message in Junk Email (`/me/mailFolders/junkemail`) is marked spam, so it waits for review. A message in Deleted Items (`/me/mailFolders/deleteditems`) is left out, as Gmail leaves out Trash. | Decided (2026-10-20). That `parentFolderId` agrees with the well-known folder's `id` under `Prefer: IdType="ImmutableId"` is **UNVERIFIED** (L5); if it does not, nothing is marked or left out, as before. |

### Changes this asks of the contract or of other packages

These need the orchestrator's approval (the plan's "Shared contract" rule):

1. **Identity (WP3a, WP5b).** Drop the `preferred_username` fallback and do not require
   `oid`: neither claim is issued without the `profile` scope, and the contract does not
   request it. Keep the scopes as they are (§6). If the owner prefers the fallback, add
   `profile` to the scopes instead; that also puts `name` into a token the server sees.
2. **WP0.** Register the redirect under "Mobile and desktop applications" (§6).
3. **WP5b.** Outlook download width ≤ 3, and `Retry-After` handling (§5). The Gmail
   engine's `downloadWidth = 6` and its 400 ms / 1200 ms retries are wrong for Graph.
4. **WP5b, WP6, WP2.** Immutable ids (§4). WP6's `check-bundle.sh` pattern
   `A[AQ]MkAD[A-Za-z0-9_=-]{40,}` matches only the default REST id. Immutable ids start
   `AAkALgAA` (Microsoft's example), so add a second pattern, for example
   `AAkALgAA[A-Za-z0-9_=-]{40,}`. WP2's replay fixture should use an immutable-shaped id.
5. **WP5b.** Subscription takeover must handle `409 Conflict` (§6).

---

## 1. Listing filtered by sender

### What the docs say

- `GET /me/messages` lists the whole mailbox, "including the Deleted Items and Clutter
  folders"; `$top` is 1 to 1000; page with `@odata.nextLink` and never edit its `$skip`.
  <https://learn.microsoft.com/en-us/graph/api/user-list-messages?view=graph-rest-1.0>
- **`InefficientFilter`.** With `$filter` and `$orderby` together: properties in
  `$orderby` must be in `$filter`, in the same order, and before any property that is not
  in `$orderby`. Otherwise Graph answers `InefficientFilter` ("The restriction or sort
  order is too complex for this operation"). Same page.
- `$filter=from/emailAddress/address eq 'someuser@example.com'` on `/me/messages` is
  Microsoft's own example.
  <https://learn.microsoft.com/en-us/graph/filter-query-parameter>
- `endswith` is listed as a supported function, but "support by individual resources and
  its properties … varies". Microsoft's `endswith` examples are all directory objects
  (`users`, `groups`) with advanced queries. No Microsoft page shows `endswith` on
  messages. Third-party reports say it works on `from/emailAddress/address`; that is not
  evidence. Same page.
- "Query parameters specified in a request might fail silently. This can be true for
  unsupported query parameters and for unsupported combinations of query parameters."
  <https://learn.microsoft.com/en-us/graph/known-issues#some-limitations-apply-to-query-parameters>
- `$search` on messages: KQL; "Search results are sorted by the date and time the message
  was sent"; at most 1,000 results; `from:` matches "an SMTP address, display name, or
  alias". <https://learn.microsoft.com/en-us/graph/search-query-parameter>. Older Outlook
  guidance and Microsoft Q&A say `$search` cannot be combined with `$filter` or
  `$orderby` on messages. The search index is eventually consistent.

### Why not `$search`

`from:` matches display names and aliases by token, not addresses by suffix. A message
from `"Bank Example Offers" <promo@evil.example>` can match `from:bank.example`. That
lists non-bank mail, which PO G forbids. It also has an index lag, a 1,000-result cap and
no date bound in `$filter`. It is never used, not even as a fallback.

### Why not `eq` per exact address (as the primary)

Hasala's trusted set is **domains** (`BankDomains.effectiveTrusted`, from template
`senderDomain` and "Add a sender"), and membership includes subdomains
(`BankDomains.isMember`). Exact addresses are not known. A bank that starts sending from a
new address would be missed with no error. `eq` stays as the fallback (§1d).

### Decision: `endswith` per domain, two clauses each

For each group of trusted domains (`BankDomains.groups`, at most 20 domains):

```http
GET https://graph.microsoft.com/v1.0/me/messages
    ?$filter=receivedDateTime ge 2026-10-13T00:00:00Z and (
        endswith(from/emailAddress/address,'@bank.example') or
        endswith(from/emailAddress/address,'.bank.example') or
        endswith(from/emailAddress/address,'@other-bank.example') or
        endswith(from/emailAddress/address,'.other-bank.example'))
    &$select=id,receivedDateTime,from
    &$top=100
Prefer: IdType="ImmutableId"
```

(Line breaks for reading; the real request is one percent-encoded line.)

How a domain maps to the query:

- `'@d'` matches exactly `d`; `'.d'` matches every subdomain of `d`. Together they are
  exactly `BankDomains.isMember`: `alerts.bank.example` matches, `notbank.example` does
  not, and `bank.example.evil.example` does not (the address must end with `d`).
- Domains are already `isQuerySafe` (LDH, lower case), so no OData quote escaping is
  needed. WP5b still refuses to build a clause for a domain that is not query-safe.
- `receivedDateTime ge` comes first. There is no `$orderby`: the engine pages to the end
  before the watermark moves, so it does not need an order, and no `$orderby` means no
  `InefficientFilter`. If WP5b wants an order, it may add only
  `$orderby=receivedDateTime desc` (that property is first in `$filter`).
- `$select=id,receivedDateTime,from` keeps pages small (Graph warns that large pages can
  give 504).
- The `since` value is `BankDomains.sinceSec(watermarkMs:)` as ISO 8601 UTC with seconds.
- An empty trusted set lists nothing (same as Gmail, PO G). WP5b keeps the
  `unfilteredListing` refusal: no request without at least one sender clause.

### Decision 1b: the phone re-checks each page

Because Graph can ignore a filter silently, WP5b checks every returned item:
`BankDomains.isMember(BankDomains.domainOf(from.emailAddress.address), of: group)`. If any
item fails, the client throws a new error (`filterNotApplied`), drops the page, fetches
nothing from it, and keeps the watermark. This turns a silent "list everything" into a
loud halt. The ids already returned are discarded and never stored.

### Decision 1c: overlap and lag

`receivedDateTime` is the time the Outlook.com store received the message, not the
sender's `Date:`. `$filter` is a store restriction, not a search-index query, so no index
lag is expected. Microsoft does not say this in so many words: **UNVERIFIED** (L6). Keep
the Gmail overlap of 2 days (`BankDomains.overlapMs`): every cycle re-lists from
watermark − 2 days, and dedupe on the immutable id removes repeats. This covers late
delivery and any lag up to 2 days.

### Decision 1d: if `endswith` is refused

**Result (2026-10-20).** L1 on the owner's Outlook.com mailbox: the §1 query answered
400 `ErrorInvalidUrlQueryFilter` ("The query filter contains one or more invalid
nodes"). The same query with `from/emailAddress/address eq '<address>'` answered 200 and
listed the bank's alerts. Each cycle's 400 halted the lane, and the app showed it as
"Microsoft ended Hasala's access".

What shipped differs from step 1 below: the exact addresses are a client table
(`ios/HasalaCore/.../Mailbox/Outlook/OutlookSenders.swift`), not a template field. A
template field changes the canonical template bytes in Go, the TypeScript reference and
Swift, and the listing filter is not part of template execution. The addresses are the
banks' public notification senders, not personal data. Each one is listed only when its
domain is in the trusted set (`BankDomains.isMember`). The page check (1b) now also
requires the exact address.

**Step 3 (2026-10-20).** On Outlook, "Add a sender" takes a full address
(`BankDomains.normalizeTypedAddress`; a bare domain is refused with `addressRequired`).
The address is kept on this iPhone only, in the ledger.sqlite table
`mailbox_sender_address` (migration `mailbox_sender_address`). The op log still records
only the domain (`sender_trust_set`); no op or template schema changed. The Graph listing
uses `OutlookSenders.known` plus these addresses. Unlink does not clear them; a new
iPhone or a reinstall starts without them.

A trusted domain with no address (known or typed) is reported, not skipped silently:
`MailboxStatus.unlisted` names it, and Bank alerts shows it under "Not read on Outlook"
with a sheet that asks for the address. Gmail lists by domain and reports nothing there.

The original plan:

If L1 shows that Graph answers 400 to `endswith` on messages, do **not** ship
`$search`. Instead:

1. Add exact sender addresses to the bank templates (a new field; a template change for
   the owner to approve).
2. List with `from/emailAddress/address eq '<addr>'` clauses (`or`-ed, same date bound).
   Exact `eq` values have a 120-character limit (known-issues page).
3. A domain added by "Add a sender" has no address; the UI must then ask for the full
   address. (Done: see Step 3 above.)

---

## 2. A change detector to replace `historyId`

What exists:

- **Delta query** (`/me/mailFolders/{id}/messages/delta`) is per folder. Its only filters
  are `receivedDateTime ge|gt`; there is no sender filter and no `$search`. It "can return
  change events that don't match the filter conditions", including read-state changes.
  <https://learn.microsoft.com/en-us/graph/api/message-delta?view=graph-rest-1.0>.
  So it returns the id of every message in the folder. That is the same reason Gmail's
  `history.list` is banned (PO G).
- **Folder counts** (`totalItemCount` on `mailFolder`) are not monotonic: one deletion
  and one arrival leave the count the same.
- **The newest message id** of the mailbox is the id of a non-bank message.

**Decision: no change detector.** `MailSource.changeToken()` returns nil for Outlook, and
every cycle runs the filtered list. This is cheap: one request per domain group per
cycle, usually with an empty or short result, against a budget of 10,000 requests per 10
minutes per mailbox (§5). The push wake is the "something changed" signal. The periodic
cycle is still needed, because Graph drops notifications for slow endpoints and
"Dropped notifications can't be recovered"
(<https://learn.microsoft.com/en-us/graph/change-notifications-delivery-webhooks>).

---

## 3. The Authentication-Results trust rule (hard gate)

### The Gmail rule, for comparison

`AuthResults.gmailVerdict` (`ios/HasalaCore/Sources/HasalaCore/Mail/AuthResults.swift`,
vectors in `conformance/authres/`):
trust only when exactly one A-R has authserv-id `mx.google.com`, it is the topmost A-R,
and it reports `dkim=pass` with a DKIM domain aligned with the one `From` domain. The
DKIM domain is `header.d`, else the domain of `header.i` (Gmail writes only `header.i`).
Every `dmarc` spec must name the `From` domain as `header.from`, and an A-R that cannot
be read cleanly (a quote inside a comment, an unbalanced paren or quote, a segment that
is not a method spec) is `parse_error`. The verified domain is the DKIM domain.
`conformance/authres/README.md` has the full rule. RFC 8601 §5 makes Gmail delete incoming
A-Rs that claim `mx.google.com`, so the authserv-id identifies Gmail's own header.

### What is different on Outlook.com

Microsoft documents its inbound A-R with **no authserv-id**:

```text
Authentication-Results: spf=pass (sender IP is 192.0.2.1) smtp.mailfrom=bank.example;
 dkim=pass (signature was verified) header.d=bank.example;
 dmarc=pass action=none header.from=bank.example;compauth=pass reason=100
```

Fields: `spf`, `dkim` (+ `header.d`), `dmarc` (`pass|fail|bestguesspass|none`, +
`action`, `header.from`), `compauth` (`pass|fail|softpass|none`, "Uses the From: domain as
the basis of evaluation") and `reason` (3 digits; 1xx and 7xx are passes).
<https://learn.microsoft.com/en-us/defender-office-365/message-headers-eop-mdo>

Consequences:

- The Gmail parser reads the first token as the authserv-id, so it would take `spf=pass`
  as the authserv-id. WP2's parser must not.
- Content cannot tell Microsoft's A-R from one the sender wrote, because both have the
  same form. Only position and context can.
- Microsoft's own intra-organisation example does carry an authserv-id
  (`authentication-results: contoso.com; dkim=none …`), so the form is not fixed across
  paths. <https://learn.microsoft.com/en-us/graph/outlook-get-mime-message>

### EOP-only headers

Exchange's *header firewall* removes `X-MS-Exchange-Organization-*` and
`X-MS-Exchange-Forest-*` headers from inbound messages from untrusted sources, and keeps
these on delivery to the mailbox: `…-SCL`, `…-AuthDomain`, `…-AuthMechanism`,
`…-AuthSource`, `…-AuthAs`, `…-OriginalArrivalTime`, `…-OriginalSize`. `AuthAs` is
"always present when the security of a message has been evaluated" (`Anonymous`,
`Internal`, `External` or `Partner`); `AuthSource` is the FQDN of the server that
evaluated it. <https://learn.microsoft.com/en-us/exchange/header-firewall-exchange-2013-help>

This page is for Exchange Server 2013. That Exchange Online / Outlook.com behaves the same
is an inference: **UNVERIFIED** (C2, C3). Microsoft's Graph MIME examples do show
`X-MS-Exchange-Organization-AuthAs` and `-AuthSource` in `$value` output (same
`outlook-get-mime-message` page).

### ARC

Microsoft 365 writes `ARC-*` headers, but an ARC verdict is only as good as a check of
the `ARC-Seal` chain, which needs DNS and signature checks the phone does not do. A sender
who uses their own Microsoft 365 tenant gets a genuine Microsoft ARC set for their own
domain. **Decision: ARC is not a trust input.** The field-name match stays exact, so
`ARC-Authentication-Results` is never counted as an A-R.

### The rule (`outlookVerdict`)

Input: the header block of the `$value` MIME (everything before the first blank line),
with the Gmail bounds (256 Ki UTF-16 units, 512 continuation lines per field) and the same
unfolding, comment stripping, quoting and JavaScript `trim`/lower-case semantics.

Definitions:

- An **A-R** is a field whose name is exactly `Authentication-Results` (trimmed,
  case-insensitive).
- A **Microsoft-form A-R** is an A-R whose first `;`-segment (after comments are
  stripped) begins with a token that contains `=`. An RFC 8601 authserv-id is a value
  token and cannot contain `=`, so the two forms cannot be confused. In a Microsoft-form
  A-R, **every** segment, the first included, is a method spec.

Steps, in order (the first that applies decides):

1. Over the bounds, or unreadable → `parse_error`.
2. No Microsoft-form A-R in the block → `no_ar`.
3. More than one Microsoft-form A-R → `multiple_ar`.
4. The topmost A-R (of any form) is not the Microsoft-form one → `not_topmost`.
5. **EOP proof.** The block must contain exactly one `X-MS-Exchange-Organization-AuthAs`
   field, with value `Anonymous` (trimmed, case-insensitive), and exactly one
   `X-MS-Exchange-Organization-AuthSource` field whose value is an LDH name ending in
   `.prod.outlook.com` (case-insensitive). Otherwise → `no_eop` (a new reason code).
6. **Verdict.** On the Microsoft-form A-R: `compauth=pass` and `dmarc=pass` (exactly
   `pass`; `bestguesspass` is not a pass), and the DMARC `header.from` is a valid LDH
   domain (the existing `domainProp` rules). Otherwise → `fail`.
7. **From binding.** The block has exactly one `From` field, and
   `BankDomains.domainOf(From)` equals that `header.from`. Otherwise → `fail`.
8. Trusted, `pass`. The verified domain is the DMARC `header.from`.

SPF and DKIM results are parsed but are not trust inputs. DMARC already requires an
aligned SPF or DKIM pass, and `compauth` adds Microsoft's own judgement. Using the DMARC
`header.from` as the domain differs from Gmail (the DKIM domain), and is right here:
it is the `From:` domain that `compauth` evaluated. Anything untrusted is `needs_review`,
never dropped.

### Why this is fail-closed

The rule rests on two premises:

- **H1.** For inbound internet mail, EOP always stamps exactly one Microsoft-form A-R,
  above every header the sender wrote. Microsoft says results "are recorded (stamped) in
  the Authentication-results message header in inbound messages".
- **H2.** `$value` returns the headers in the order they were received. Microsoft notes
  that "Outlook does not save messages in MIME format", so `$value` is rebuilt. Order is
  not documented.

Against attacks, whether or not EOP strips sender A-Rs:

| Attack (synthetic) | Result |
|---|---|
| Sender adds a Microsoft-form A-R claiming `dmarc=pass header.from=bank.example` | With H1 there are two Microsoft-form A-Rs → `multiple_ar`. If EOP strips it, it is gone and EOP's real verdict decides. |
| Sender adds a `mx.google.com` or other authserv-id A-R | Not Microsoft-form; EOP's A-R is still topmost (H1) → ignored. If it were above → `not_topmost`. |
| Sender adds `X-MS-Exchange-Organization-AuthAs: Internal` | Header firewall removes it; if not, there are two `AuthAs` fields or a wrong value → `no_eop`. |
| Mail never crossed EOP inbound (draft, import, API-inserted) | No EOP A-R or no `AuthAs: Anonymous` → `no_ar` / `no_eop`. |
| Look-alike domain with its own valid DMARC | `pass` for `bank-example.evil.example`; the sender-trust match downstream rejects it (unchanged from Gmail). |
| Forwarded genuine alert (another mailbox → Outlook.com) | EOP evaluates on arrival; DKIM usually survives forwarding, so `dmarc=pass`. If not → `fail` → review. |

If H1 or H2 is false, the effect depends on the case. If EOP sometimes stamps no A-R and
keeps the sender's, a forged A-R could become the only Microsoft-form one. Step 5 alone
does not stop that. **This is why the rule cannot ship trusted until C1–C3 pass.** Until
then, WP2 implements the rule and WP5b wires it. The gate decides whether a `pass` files
without review (see "Shipping gate" below).

### Shipping gate

- **Replaced by §3a (2026-10-20).** Until then, the Outlook lane sent every message to
  review, whatever `outlookVerdict` said (`outlookTrustProven = false`). The flag is
  deleted. C1–C7 no longer decide anything in the app; they stay as a way to learn how
  Outlook.com marks bank mail.

### Proposed vectors for WP2 (all synthetic)

pass; `dmarc=fail`; `dmarc=bestguesspass`; `compauth=fail reason=001`; `compauth=softpass`;
forged Microsoft-form A-R below the real one (`multiple_ar`); forged Microsoft-form A-R
above (`multiple_ar`); authserv-id A-R above the Microsoft one (`not_topmost`); no A-R;
only an authserv-id A-R (`no_ar`); `AuthAs` missing / `Internal` / twice (`no_eop`);
`AuthSource` not under `.prod.outlook.com` (`no_eop`); `From` domain ≠ `header.from`
(`fail`); two `From` fields (`fail`); forwarded message with `dkim=pass dmarc=pass`;
`ARC-Authentication-Results` only (`no_ar`); the Gmail bounds vectors again.

---

## 3a. The Outlook sender rule (2026-10-20)

The rule of §3 needs C1–C7 on real mail before it can trust anything, so every Outlook
alert went to review. The owner asked for trust to matter less. This rule relies on the
mailbox provider's own filtering and on the banks' DMARC policies instead of on
Microsoft's header.

### The rule (`AuthResults.analyzeOutlookSender`)

Inputs: the header block of the `$value` MIME; whether Graph has the message in the
Inbox; the known sender addresses (`OutlookSenders.known` plus the addresses the user
added); the DMARC `p=reject` domains (`OutlookSenders.dmarcReject`, bundled, no DNS lookup).
The first step that applies decides:

1. Over the bounds of §3 (256 Ki UTF-16 units, 512 continuation lines) → `parse_error`.
2. The message's `parentFolderId` is not the Inbox's id → `not_inbox`. This covers Junk
   Email, Deleted Items, Archive and every folder a user rule moved the message to.
3. Not exactly one `From` field, or its value does not hold exactly one address, or that
   address is not a known sender (ASCII case-insensitive) → `unknown_sender`.
4. The address's domain is not exactly on the `p=reject` list → `no_dmarc_reject`.
   Subdomains do not count: their policy is `sp=`, and `dib.ae` has `sp=none`.
5. Trusted, `pass`. The verified domain is the `From` domain.

The fold accepts the three new codes, but `txn_ingested` records them as `fail` for now
(`AuthResults.Reason.recorded`). An older build refuses an unknown `gates.ar` value, so a
later release starts to record the codes, after every build in use accepts them.

The other gates of `MessageDisposer.finalize` do not change: the domain must be in the
trusted set T, a template must read an amount (or both readers must agree), the
message must not be forwarded, and the recipient check must not be a mismatch. Since
2026-10-29 there is no card gate ([filing-without-cards.md](filing-without-cards.md)).

The bundled list on 2026-10-20 (`dig TXT _dmarc.<domain>`):

| Domain | Policy | Known senders |
|---|---|---|
| `adib.ae` | `p=reject` (no `sp`) | `adibsms@adib.ae` |
| `dib.ae` | `p=reject; sp=none` | `DIB.notification@dib.ae`, `dib.mail@dib.ae` |
| `emiratesnbd.com` | `p=reject; sp=quarantine` | `OnlineBanking@emiratesnbd.com` |

ENBD's alerts come from `OnlineBanking@emiratesnbd.com` (the private corpus). The old
entry `alert@emiratesnbd.com` was a guess, and it never listed a real ENBD alert.

Conformance: `conformance/outlook-sender/` (synthetic). The private-corpus test
`PrivateOutlookSenderRuleTests` requires every real alert that a template reads to pass.

### Why this is enough here

**The threat model.** A spoof that passes makes a wrong row in the user's budget. It
never moves money, and the app never acts on a row by itself. Anything that does not pass
goes to review with its reason code (the transaction sheet shows "Sender check:
<code>"). Nothing is dropped. The Gmail lane keeps its own rule (§3, "The Gmail rule"),
because it reads Gmail's own verdict.

**What stops a spoof.** To pass, a forged alert must say `From: <a known bank address>`
and reach the Inbox. The bank's `p=reject` tells Outlook.com to refuse mail that fails
DMARC for that domain. Outlook.com rejects it, or puts it in Junk Email (`action=oreject`).
Either way it is not in the Inbox, so the rule gives `not_inbox` or never sees it.

**What the rule does not need.** It does not need EOP's A-R at the top, the EOP-only
fields, or the header order of `$value`. Those were the UNVERIFIED premises H1 and H2.

### Residual risk (for the owner to approve)

| # | A spoof passes when… | Likelihood | Effect, and what limits it |
|---|---|---|---|
| R1 | Outlook.com delivers a DMARC-failing message to the Inbox: a Microsoft bug, an `oreject` that is not applied, or a trusted ARC sealer that vouches for it. | Low | One wrong row. The bank's DMARC reports show the abuse to the bank. |
| R2 | The user put the bank in Safe Senders, or wrote a rule that moves mail into the Inbox, and Outlook.com honours it for a DMARC fail. | Low | One wrong row for that user. |
| R3 | The user moves a spoof from Junk to the Inbox ("Not junk"). | Low | The user's own choice. The rule reads the folder at download time. |
| R4 | Someone with access to the mailbox (password, a token with `Mail.ReadWrite`, IMAP) puts a message in the Inbox. §3 caught this (`no_eop`); §3a does not. | Low | Such a person can already read every bank alert. A wrong row is the smallest harm. |
| R5 | A bank lowers its policy (for example to `p=none`), and the bundled list is not updated. | Low, slow | Spoofs could then reach the Inbox. Recheck the list before each release (`dig TXT _dmarc.<domain>`). |
| R6 | The bank's own sending system is abused (a compromised mail platform, a real signed message with false content). | Very low | Every rule passes such mail, Gmail's too. |
| R7 | The recipient check (`MailRecipients`) counts a `DKIM-Signature` header with `d=<bank>` that lists `To` without checking the signature (Outlook gives it no `header.b`). Since 2026-10-29 an unconfirmed recipient files too, and no card is checked ([filing-without-cards.md](filing-without-cards.md)), so this no longer changes what files. | Low | A spoof must still pass R1–R4 first. |

**Failure modes, all fail-closed.** If the Inbox id cannot be read, the download fails and
is tried again on the next cycle. If Graph's `parentFolderId` and the Inbox's `id` are in
different forms (L8 fails), every Outlook alert goes to review with `not_inbox`. A sender
address the bank starts to use and the list does not have goes to review with
`unknown_sender`; the user can add it ("Add a sender"), and it passes if its domain is on
the `p=reject` list.

**Older builds.** `not_inbox`, `unknown_sender` and `no_dmarc_reject` are new values of
`gates.ar`. An older build's fold refuses an op with one of them and records the refusal
(it is not dropped). Every device of an account must run this build before an Outlook lane
on this build authors such an op. During the TestFlight beta this means: ship it, and
let the testers update.

### Checks for the owner (add to WP0)

- **L8.** With `Prefer: IdType="ImmutableId"`, compare a listed Inbox message's
  `parentFolderId` with `GET /me/mailFolders/inbox?$select=id`. Expect the same string.
  Move the message to Junk Email and expect a different one.
- **C8.** From an SMTP account the owner controls, send a message with
  `From: <a known bank address>` to the test mailbox (a spoof the bank's DMARC fails).
  Expect it rejected or in Junk Email, and never in the Inbox. In the app, expect no row,
  or a review row with `not_inbox`. Send one message, to the owner's own test mailbox
  only.

---

## 4. Fetching

- **Raw message:** `GET /me/messages/{id}/$value` returns the MIME. The trust analysis
  (§3) and the parser both read this. Apply the Gmail lane's raw-size bound. 404 (or error
  code `ErrorItemNotFound`) is `gone`.
  <https://learn.microsoft.com/en-us/graph/outlook-get-mime-message>
- **Do not fetch metadata first.** The list already returns `from` and
  `receivedDateTime`, and every listed id belongs to the trusted set. A separate headers
  request would double the request count and add nothing.
- **`internetMessageHeaders`** ("Requires `$select` to retrieve") is not used for trust,
  because Microsoft does not document its order or completeness.
  <https://learn.microsoft.com/en-us/graph/api/resources/message?view=graph-rest-1.0>.
  It may be used in WP0 to compare with `$value` (C4).
- **Immutable ids.** By default "this value changes when the item is moved". With
  `Prefer: IdType="ImmutableId"` the id stays the same across folder moves (it changes
  only on a move to an archive mailbox, or on export and re-import). The header applies
  only to the request that carries it, so send it on every request. Ids are
  case-sensitive. Without this, an alert moved from Junk to the Inbox comes back with a
  new id and would be imported twice.
  <https://learn.microsoft.com/en-us/graph/outlook-immutable-id>
- Percent-encode the id in the path.
- `MailboxNotEnabledForRESTAPI` (a Microsoft account with no Outlook mailbox): map it by
  `error.code`, not by HTTP status (the status is not documented here). The user sees
  "this Microsoft account has no Outlook mailbox" (contract).

---

## 5. Throttling

Docs:

- Outlook limits are per app ID **and mailbox**: 10,000 requests per 10 minutes, and
  **four concurrent requests**.
  <https://learn.microsoft.com/en-us/graph/throttling-limits#outlook-service-limits>
- A throttled request gets `429 Too Many Requests` with `Retry-After` in seconds. "Avoid
  immediate retries, because all requests accrue against your usage limits"; wait
  `Retry-After`; if there is none, use exponential backoff.
  <https://learn.microsoft.com/en-us/graph/throttling>
- 429 can come before the limits when the service is under load.
- Subscription writes are limited per app **per tenant** (500 per 20 s). Every personal
  account shares the one `consumers` tenant, so all Hasala users share this budget.
  Harmless at beta size; renewals should have jitter.

Decisions for WP5b:

- Outlook download width is **3** (the 4th slot is for the list and subscription calls).
- A 429 or 503 with `Retry-After`: stop the run, keep the watermark, and do not start the
  next cycle before `now + clamp(Retry-After, 1 s, 600 s)`. Do not use the Gmail engine's
  400 ms / 1200 ms retries.
- Without `Retry-After`: the engine's existing backoff, and the existing "3 cycles ending
  on 429 → `quota`" rule.
- A 504 on a list page: retry once with `$top=50`.

---

## 6. Identity, redirect and subscriptions

### id_token claims (consumer accounts)

From <https://learn.microsoft.com/en-us/entra/identity-platform/id-token-claims-reference>,
<https://learn.microsoft.com/en-us/entra/identity-platform/scopes-oidc> and
<https://learn.microsoft.com/en-us/entra/identity-platform/optional-claims-reference>:

- `iss` ends in `/v2.0`, and the consumer GUID is
  `9188040d-6c67-4c5b-b112-36a304b66dad`. `tid` is the same GUID for personal accounts.
  `aud` is the app's client id. `nonce` must match. `iat`, `nbf` and `exp` are Unix times.
  The contract's checks are right.
- `email` (the `email` scope on v2.0; the optional claim is not also needed) "is included
  in a token only if an email address is associated with the user account". It "isn't
  guaranteed to be correct, and is mutable". Supported for MSA.
- There is **no `email_verified`** claim. `xms_edov` is not documented for personal
  accounts. Do not rely on it.
- `preferred_username` and `oid` need the **`profile` scope**. The contract requests
  `openid email offline_access Mail.Read`, so neither will be present. Hence change
  request 1: drop the `preferred_username` fallback; do not require `oid`. `sub`
  (pairwise, always present with `openid`) is available if a stable id is ever needed.
- Why an unverified `email` is acceptable here: the server uses it only as the link's
  label and in `AddressHMAC("outlook", …)`. Outlook wakes are routed by
  `SHA256(clientState)`, not by address. The mailbox the phone reads is whatever the
  access token grants. A wrong `email` can therefore not misroute a wake or grant access
  to mail.
- If `email` is absent, the link fails with an error the user sees. It never falls back
  to an empty address.
- `offline_access` must be requested explicitly to get a refresh token; refresh tokens
  are "typically valid for 90 days". Store the new refresh token from every refresh
  response.

### Redirect URI

From <https://learn.microsoft.com/en-us/entra/identity-platform/reply-url>:

- An iOS app "implementing our OAuth protocols directly" (no MSAL) uses the **Mobile and
  desktop applications** platform, not the iOS/macOS platform. Register
  `msauth.app.hasala.ios://auth` there as a custom redirect URI (change request 2).
- Matching is case-sensitive. Query parameters are not allowed in redirect URIs for apps
  that sign in personal accounts (ours has none). No wildcards.
- That the authorize endpoint returns the code to this custom scheme through
  `ASWebAuthenticationSession(.customScheme)`, with the scheme not in `CFBundleURLTypes`,
  is **UNVERIFIED** (I2).

### Subscriptions

From <https://learn.microsoft.com/en-us/graph/api/resources/subscription?view=graph-rest-1.0>,
<https://learn.microsoft.com/en-us/graph/api/subscription-post-subscriptions?view=graph-rest-1.0>,
<https://learn.microsoft.com/en-us/graph/change-notifications-delivery-webhooks> and
<https://learn.microsoft.com/en-us/graph/change-notifications-lifecycle-events>:

- **Lifetime.** Outlook `message`: at most 10,080 minutes ("under seven days"), and 1,440
  minutes with resource data (we use none). The contract's now + 6 d 23 h is 10,020
  minutes, which is inside the limit. Microsoft warns that requests over the maximum will
  fail in the future. An expiry under 45 minutes is raised to 45.
- **Resource and permission.** `me/messages` is a documented resource, and personal
  accounts may subscribe with delegated `Mail.Read`. `changeType: "created"`.
- **`clientState`**: at most 128 characters. 32 random bytes in base64url are 43, so it
  fits.
- **Duplicates.** "When a subscription request contains the same values for changeType
  and resource as an existing subscription, the request fails with … `409 Conflict`".
  On takeover or re-link the old subscription carries the old `clientState`, and PATCH
  changes only `expirationDateTime` and `notificationUrl`. So WP5b must, on 409:
  `GET /subscriptions` (lists the app's subscriptions for the signed-in user), DELETE each
  one whose `notificationUrl` is ours, then create again.
- **Validation.** Graph POSTs `?validationToken=…` to the notification URL, and also to
  the lifecycle URL when it is set. Answer within **10 seconds**: 200, `text/plain`, the
  URL-decoded token as the body. Treat the token as opaque, because "the token format can
  change without notice". The contract's 256-byte printable-ASCII bound is a sound guard,
  but if Graph ever sends more, subscription creation fails visibly (fail closed). WP3b
  should count refusals by length class so this shows in metrics.
- **Delivery.** A 2xx within **3 seconds** counts as delivered; otherwise Graph retries
  for up to 4 hours. Endpoints with more than 10 % slow answers are delayed by 10
  minutes; with more than 15 % over 10 seconds, notifications are dropped and "can't be
  recovered". The hook must answer fast (the contract's 202). 503 on a database failure
  makes Graph retry (good).
- **Query string.** "Any query string parameter included in the notificationUrl property
  is included in the HTTP POST". Put no secret in the URL.
- **Latency** for `message`: under 1 minute on average, 3 minutes at most.
- **Lifecycle events.** `reauthorizationRequired` (all resources), `subscriptionRemoved`
  and `missed` (Outlook `message` supports both). `lifecycleNotificationUrl` must be set
  at creation and cannot be added by PATCH. Answer 202. For `reauthorizationRequired`:
  `PATCH /subscriptions/{id}` with a new expiry (this reauthorizes and renews in one
  step); never a `reauthorize` and a PATCH within 10 minutes of each other. For
  `subscriptionRemoved`: create again, then run a full list. For `missed`: run the list.
  These match the contract's `ReasonNudge`.

---

## Checks for the owner (WP0)

Do these on the WP0 test mailbox. Export each message with **Graph `$value`** (for
example in Graph Explorer, signed in to the test account), not with Outlook's "Save as",
which may rebuild the headers differently. Keep every real `.eml` in the private
`salehtl/hasala-fixtures` repository only.

### Listing (no bank mail needed; synthetic mail to the test mailbox is enough)

- **L1.** Run the §1 query with one domain. Expect 200, not 400.
- **L2.** Send synthetic mail from `x@d`, `x@sub.d`, `x@notd`, a sender with display name
  `"d"` at another domain, and an upper-case `X@D`. Expect the first two to be listed and
  the `notd` and display-name ones not. Record whether `X@D` is listed: if `endswith` is
  case-sensitive, a bank that sends from a mixed-case address would be missed, and WP5b
  must add an upper-case clause per domain.
- **L3.** Query a domain that has no mail. Expect an empty list. If anything comes back,
  Graph ignored the filter; record it, and confirm that the §1b check halts.
- **L4.** 20 domains (40 clauses) in one request: expect no 400, no `InefficientFilter`,
  and the URL inside Graph's limits. Lower the group size if needed.
- **L5.** Move a matching message to Junk Email and to Deleted Items. Expect it still
  listed by `/me/messages`.
- **L6.** Send a matching message and list it at once, then every 10 s. Record the delay
  until it appears (expect none).
- **L7.** With `Prefer: IdType="ImmutableId"`, note the id, move the message between
  folders, and list again. Expect the same id. Note the id prefix (for WP6).

### Trust (needs real bank alerts, plus synthetic spoof probes)

- **C1.** For each real alert: count the A-R fields and their forms. Expect exactly one
  Microsoft-form A-R, topmost among the A-Rs; note any with an authserv-id.
- **C2.** For each real alert: expect exactly one `X-MS-Exchange-Organization-AuthAs:
  Anonymous` and exactly one `-AuthSource` ending in `.prod.outlook.com`. Record where they
  sit relative to the A-R.
- **C3.** Spoof probe. From an SMTP account the owner controls (for example `swaks`),
  send to the test mailbox a synthetic message from a domain the owner controls, with
  these headers added by the sender:
  - a Microsoft-form `Authentication-Results: spf=pass smtp.mailfrom=bank.example;
    dkim=pass header.d=bank.example; dmarc=pass action=none header.from=bank.example;
    compauth=pass reason=100`;
  - `Authentication-Results: mx.google.com; dkim=pass header.d=bank.example`;
  - `X-MS-Exchange-Organization-AuthAs: Internal` and
    `X-MS-Exchange-Organization-AuthSource: relay.evil.example`.

  Record which headers survived, were renamed or were removed, and where EOP's own A-R
  sits. Expect `outlookVerdict` ≠ `pass`.
- **C4.** For three alerts: compare the header order in `$value` with
  `internetMessageHeaders` and with Outlook on the web's "View message source". Expect the
  same order, with the newest `Received` on top.
- **C5.** One alert filed in Junk Email, and one auto-forwarded from another mailbox to
  the test mailbox. Record `dmarc`, `compauth` and `reason`.
- **C6.** Run the WP2 oracle over every exported `.eml`. Expect every genuine alert to be
  `pass` with its bank domain, and every C3 probe to be untrusted.
- **C7.** If a bank sends through Microsoft 365, check whether its alerts carry a second
  Microsoft-form A-R from the bank's own tenant. That would make them `multiple_ar`, and
  the rule would need an amendment.

### Identity

- **I1.** Decode the test account's id_token (on the device; never send it anywhere).
  Expect `email` present, `tid` = the consumers GUID, `iss` as in the contract, and
  neither `preferred_username` nor `oid` (no `profile` scope).
- **I2.** With the redirect registered under "Mobile and desktop applications", a Debug
  build completes the authorize → code → token exchange, and the token response has a
  `refresh_token`, an `id_token` and `Mail.Read` in `scope`.
- **I3.** A Microsoft account whose sign-in address is not Microsoft's (no Outlook
  mailbox): record the HTTP status and `error.code` of `GET /me/messages`. Expect
  `MailboxNotEnabledForRESTAPI`.

## UNVERIFIED items (to close with WP0)

1. `endswith` on `from/emailAddress/address` is accepted, applied (not silently ignored)
   and case-insensitive on consumer mailboxes (L1–L3), and 40 clauses fit (L4).
2. `/me/messages` includes Junk Email and Deleted Items for consumer mailboxes (L5).
3. `$filter` has no index lag (L6).
4. Immutable ids work on consumer mailboxes; the id prefix (L7).
5. EOP stamps exactly one Microsoft-form A-R, topmost, on inbound mail (C1, C3).
6. EOP's header firewall strips sender-supplied `X-MS-Exchange-Organization-*` headers,
   and `AuthAs: Anonymous` / `AuthSource …prod.outlook.com` appear exactly once on inbound
   bank mail (C2, C3).
7. Whether EOP strips or renames sender-supplied A-R headers (C3); the rule does not
   depend on the answer, but record it.
8. `$value` keeps the header order (C4).
9. Junk-filed and forwarded alerts pass (C5); banks on Microsoft 365 do not carry a
   second Microsoft-form A-R (C7).
10. Consumer id_tokens carry `email` (I1).
11. The custom-scheme redirect works without MSAL under "Mobile and desktop applications"
    (I2).
12. The status code that goes with `MailboxNotEnabledForRESTAPI` (I3).

Items 5, 6 and 8 no longer hold the lane back: the lane uses §3a, which does not depend
on them. §3a has its own UNVERIFIED items:

13. Graph's `parentFolderId` and the Inbox's `id` are the same string for an Inbox message
    (L8).
14. Outlook.com rejects, or puts in Junk Email, a message whose `From` domain publishes
    `p=reject` and that fails DMARC (C8).

## Results (WP0)

**Status: NOT RUN.** Fill this section from the redacted output of the tools in
[the runbook](outlook-trust-runbook.md). Paste only what they print: file indices, From
domains, header forms and counts, `dmarc` / `compauth` / `reason`, verdicts. Never paste a
subject, body, amount, address local part, message id or date. The `.eml` files stay
outside this repository.

Mailbox: a personal Outlook.com test account (address not recorded here). Date of the run:
`<YYYY-MM-DD>`. Checker commit: `<sha>`.

| Check | Input | Result | Evidence (redacted) |
|---|---|---|---|
| C1 one Microsoft-form A-R, topmost | `genuine/`, `<n>` alerts from `<bank domains>` | `<PASS / FAIL>` | `C1 … <n>/<n>` |
| C2 one `AuthAs: Anonymous`, one `AuthSource …prod.outlook.com` | `genuine/` | `<PASS / FAIL>` | `C2 …`; positions: `authas@<above/below>`, `authsource@<above/below>`, `order=<…>` |
| C3 spoof probe untrusted | `spoof/`, `<n>` probes | `<PASS / FAIL>` | `C3 …`; forms `<…>`; forged `AuthAs`/`AuthSource` `<kept / removed>`; forged A-Rs `<kept / removed / renamed>`; EOP A-R `ms_index=<n>` |
| C3 copied alerts untrusted | `copied/`, `<n>` messages | `<PASS / FAIL>` | `C3 …`; verdicts `<no_eop …>` |
| C4 `$value` order = `internetMessageHeaders` order | Debug app, `<n>` alerts | `<PASS / FAIL>` | `order_match=<yes/no>`, `rcv0=<same/differs>`; Outlook on the web source `<same / differs>` |
| C5 Junk and auto-forwarded alerts | `genuine/junk/`, `genuine/forwarded/` | `<PASS / FAIL>` | `C5 …`; Junk `scl=<n> dmarc=<…> compauth=<…> reason=<…>`; forwarded `dmarc=<…> compauth=<…> reason=<…>` |
| C6 oracle over every export | all folders | `<PASS / FAIL>` | `C6 …` (genuine) and `C6 … untrusted half` |
| C7 no second Microsoft-form A-R | `genuine/` | `<PASS / FAIL>` | `C7 …`; senders on Microsoft 365: `<none / domains>` |
| L1–L7 listing | Debug app | `<…>` | `<…>` |
| I1–I3 identity | Debug app | `<…>` | `<…>` |

UNVERIFIED items closed by this run: `<5, 6, 8, …>`. Amendments to §3, if any: `<none /
the change and its new vectors>`.

### Turning the gate on

Not used since §3a (2026-10-20): there is no gate to turn on. Record L8 and C8 here when
they are run.
