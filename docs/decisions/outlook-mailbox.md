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
| 1a | List with `$filter` on `/me/messages`: `receivedDateTime ge <since>` AND an `or` of `endswith(from/emailAddress/address,'@<d>')` / `endswith(…,'.<d>')` per trusted domain. No `$search`, no `$orderby`. | Docs support `$filter` on `from/emailAddress/address` and the `InefficientFilter` rule. `endswith` on messages is **UNVERIFIED** (L1–L3). |
| 1b | The phone re-checks every listed `from` address against the group and refuses the page if one is outside it. | Decided (defence against Graph ignoring a filter silently, which Microsoft documents as possible). |
| 1c | Keep the Gmail overlap: re-list from watermark − 2 days (`BankDomains.overlapMs`). | Decided. "No index lag for `$filter`" is **UNVERIFIED** (L6); the overlap covers it either way. |
| 1d | If `endswith` is refused: fall back to `eq` on exact sender addresses (needs a new template field, owner's call). Never fall back to `$search`. | Decided. |
| 2 | No change detector replaces `historyId`. Every cycle runs the filtered list. | Confirmed from docs (delta lists every message in a folder, so it breaks PO G). |
| 3 | Trust only the single Microsoft-form `Authentication-Results` (no authserv-id), when it is the topmost A-R, the EOP-only headers prove inbound EOP processing, and it reports `compauth=pass` + `dmarc=pass` for the `From:` domain. Else `needs_review`. ARC is ignored. | Rule decided. Its two premises (EOP always stamps one A-R at the top; `$value` keeps header order) are **UNVERIFIED** (C1–C7). Hard gate for WP2. |
| 4a | Read trust headers and the body from `GET /me/messages/{id}/$value` only. Do not use `internetMessageHeaders` for trust. | Decided. Header order in `$value` is **UNVERIFIED** (C4). |
| 4b | Send `Prefer: IdType="ImmutableId"` on every Graph request. The provenance message id is the immutable id. | Confirmed from docs. Support on consumer mailboxes is **UNVERIFIED** (L7). |
| 5 | At most 3 concurrent Graph requests per mailbox. On 429/503 honour `Retry-After` (stop the run, keep the watermark); without it, use the engine's backoff. | Confirmed from docs (4 concurrent, 10,000 per 10 min). |
| 6a | id_token: check `iss`, `tid`, `aud`, `nonce`, `iat`. Take the address from `email`; there is no `email_verified`. `preferred_username` and `oid` are **absent** with the contract's scopes (they need `profile`). | Confirmed from docs. Contract change requested (see below). Presence of `email` on the test account is **UNVERIFIED** (I1). |
| 6b | Register `msauth.app.hasala.ios://auth` under the **Mobile and desktop applications** platform, not iOS/macOS. | Confirmed from docs (correction to WP0). End-to-end redirect is **UNVERIFIED** (I2). |
| 6c | Subscription: `me/messages`, `created`, at most 10,080 min (ask for 10,020); validate both URLs; handle `409 Conflict` on takeover by listing and deleting the app's old subscription. | Confirmed from docs. |

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

If L1 shows that Graph answers 400 to `endswith` on messages, do **not** ship
`$search`. Instead:

1. Add exact sender addresses to the bank templates (a new field; a template change for
   the owner to approve).
2. List with `from/emailAddress/address eq '<addr>'` clauses (`or`-ed, same date bound).
   Exact `eq` values have a 120-character limit (known-issues page).
3. A domain added by "Add a sender" has no address; the UI must then ask for the full
   address.

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
oracle `reference/ledgerd-client/src/mail/authres.ts`, vectors in `conformance/authres/`):
trust only when exactly one A-R has authserv-id `mx.google.com`, it is the topmost A-R,
and it reports `dkim=pass` with `header.d` or `dmarc=pass`. The verified domain is the
DKIM `header.d`, else the DMARC `header.from`. RFC 8601 §5 makes Gmail delete incoming
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
`header.from` as the domain differs from Gmail (DKIM `header.d` first), and is right here:
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

- Before C1–C7 pass on real mail, the Outlook lane must send **every** message to review,
  whatever `outlookVerdict` says. WP5b adds a flag (`outlookTrustProven`, default false).
- The owner turns it on only after the checks pass, in a commit that cites this file's
  results section (to be added after WP0).

### Proposed vectors for WP2 (all synthetic)

pass; `dmarc=fail`; `dmarc=bestguesspass`; `compauth=fail reason=001`; `compauth=softpass`;
forged Microsoft-form A-R below the real one (`multiple_ar`); forged Microsoft-form A-R
above (`multiple_ar`); authserv-id A-R above the Microsoft one (`not_topmost`); no A-R;
only an authserv-id A-R (`no_ar`); `AuthAs` missing / `Internal` / twice (`no_eop`);
`AuthSource` not under `.prod.outlook.com` (`no_eop`); `From` domain ≠ `header.from`
(`fail`); two `From` fields (`fail`); forwarded message with `dkim=pass dmarc=pass`;
`ARC-Authentication-Results` only (`no_ar`); the Gmail bounds vectors again.

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

Until items 5, 6 and 8 are closed, the Outlook lane sends every message to review
(`outlookTrustProven = false`).
