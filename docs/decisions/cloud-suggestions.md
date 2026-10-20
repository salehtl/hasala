# Cloud suggestions: opt-in Clef and Clairic (design)

**Status: Merchant suggestions (Clef) DECIDED and in progress (2026-10-20). Alert reading
help (Clairic) DEFERRED.** The spike is done ([results](#spike-results-2026-10-20)). The
owner approved Merchant suggestions with the recommended answers to D1-D3 and D6 (see
[Decisions for the owner](#decisions-for-the-owner)). The Clairic sections stay in this
file for later reference; nothing for Clairic is built.

Before a tester who isn't a developer can turn Merchant suggestions on, these must be
done: Cloudflare's written confirmation of check 2, a security review of the Worker with
all findings closed, and the privacy-policy change with 30 days' notice. Until then the
policy must not describe the feature (see [Privacy policy changes](#privacy-policy-changes)).

Every example in this file is synthetic. No real mail, merchant, amount or name was used.

## Summary

Two optional features, both **off by default**, each with its own switch:

| Feature | Model | What leaves the phone | Where it plugs in | What it may do |
|---|---|---|---|---|
| **Merchant suggestions** | Clef (`@cf/cloudflare/clef`) | One canonical merchant string per request, plus the built-in category list | A second `CategoryModel` behind the existing model tier (`Categorize/ModelTier.swift`) | Suggest a category. Never files a row (`ModelTier.autoConfirm = false` stays). |
| **Alert reading help** (deferred) | Clairic (`@cf/cloudflare/clairic`) | The body text of **one** bank alert, redacted on the phone, shown to the person first | The review sheet for an alert no template could read (the empty review shape, `ParsedMail.fields == nil`) | Pre-fill the sheet's fields. The person saves them; the op is an ordinary user edit. |

The requests go from the phone to a new Worker, `assist.hasala.app`, which holds the
Workers AI binding. The Worker has no account identity, stores nothing, and logs nothing.
hasalad never sees these requests, so "the server is blind" stays true for hasalad.

What this changes in the product's promises: today nothing goes to an AI service. With a
switch on, a merchant name or a redacted alert goes to Cloudflare Workers AI for one
answer and is not kept. The privacy policy already reserves this ("off by default,
explained before you turn it on, and you can turn it off at any time"). The changes it
needs are under [Privacy policy changes](#privacy-policy-changes).

## Why this split

- **Templates stay the parser.** Parsing is deterministic and checked byte for byte across
  Go, TypeScript and Swift (`conformance/`). A model cannot be inside that path, and
  `Mailbox/Disposition.swift` (op-authoring code, the highest-risk code in the repository)
  does not change. Clairic only helps with mail that already falls out of the templates
  into review, and only when the person opens that review item.
- **The model tier already has the right shape for Clef.** `CategoryModel.suggest(subject:allowed:)`
  takes one subject and a closed set of allowed categories and returns one id or
  `.unknown`. A Clef `choice` question is the same contract, with a probability per option.
  The tier's guarantees (suggest only, debits with no category, one call per distinct
  subject, a budget per context, never in a background refresh or a push wake) carry over
  unchanged.
- **Clef can cover what Apple's model can't.** The Foundation Models tier runs only on
  Latin-script subjects (`Categorize/LatinGate.swift`). If Clef reads Arabic merchant
  names well (unverified, see [Checks before building](#checks-before-building)), Arabic
  merchants stop going straight to the review queue.

## Anonymity

"Anonymous" here means: no request carries anything that names the person or their
account, no two requests are linked by an identifier we send, and nothing is kept after
the answer. The rules below are what make that true; each is a requirement, not a
preference.

### What a request contains

**Merchant suggestions (Clef):**

- The canonical subject (`Canon.subject(merchantRaw)`), the same string the dictionary
  matches. Example: `CAFE EXAMPLE JBR`.
- The ids, names and hints of the **built-in** categories (`Categorize/Taxonomy.swift`).
  Custom category names are not sent by default, because a person may name a category
  after a person or a place (see decision D2). A custom category can still be the answer
  to a rule or a manual edit; it just isn't offered to the model.
- Nothing else: no amount, date, card, bank, direction, account id, device id, or other
  subjects.

**Alert reading help (Clairic):**

- The alert's body text after [redaction](#redaction-on-the-phone), and three field specs:
  the amount as written (`text`), the amount (`number`, the cross-check) and the
  merchant (`text`).
- No `reference_date`: the date isn't taken from Clairic (see
  [Spike results](#spike-results-2026-10-20)).
- No headers, no sender address, no Gmail or Outlook message id, no attachments, no images.

### One subject per request

Subjects are not batched, although Clef accepts several questions in one request. A batch
of one person's merchants is a profile of where they shop; single requests are
unlinkable except by network address and timing (below). The phone keeps its own cache of
answers per subject, so a subject is asked about once per device.

### No identity at the Worker

- The Worker accepts requests without a Hasala session token. It must not call hasalad and
  must not receive the person's account id, email, push token or App Attest key id.
- Abuse control in v1: a per-IP rate limit in the Worker (Cloudflare's rate-limiting
  binding, held in memory at the edge, not stored by us) and a global daily request cap
  that fails closed. See decision D3 for the stronger option (Privacy Pass tokens).
- The request carries a fixed app version header only, so the Worker can refuse versions
  with a known bad redaction.

### Nothing kept

- Workers observability off, no `console.log` of bodies, no Logpush, no tail Workers.
- No AI Gateway in front of the model: AI Gateway logs prompts and responses by default.
  If a gateway is ever added for caps or caching, its logging must be off and its cache
  must be off.
- The Worker returns the model's answer and forgets the request. No KV, D1, R2, Durable
  Object or Queue binding on this Worker. A fence test checks the Worker's
  `wrangler.jsonc` for these bindings (see [Build plan](#build-plan)).

### What we can't hide

- **Network address.** Cloudflare's edge sees the phone's IP address on every request, as
  it already does for hasalad and the website. The Worker uses it only for the rate limit,
  in memory. The policy says so plainly.
- **Timing.** Merchant suggestions run in the foreground sweep only (the tier already
  forbids `refresh` and push wakes). Requests from one sweep go out with a small random
  delay between them, so a sweep is not one burst. They are still close in time, and the
  policy does not claim otherwise.
- **The alert's content.** A redacted alert still holds an amount, a merchant and a day.
  Cloudflare can't tie that to a person from our request, but the person's bank could
  recognise the transaction if it ever saw the text. That's why Alert reading help is
  per alert, shows the exact text first, and is a separate switch.

## Redaction on the phone

Clairic needs the text around the amount and the merchant, so redaction removes what
identifies the person and keeps what describes the transaction. It runs in HasalaCore,
before anything is sent, as a pure function with synthetic test vectors.

Removed, replaced with a fixed placeholder:

| What | How it is found | Placeholder |
|---|---|---|
| Card and account numbers, masked or not | Runs of 4 or more digits mixed with `*`, `x`, `X`, `-`, spaces, that are not an amount or a date | `[NUMBER]` |
| IBANs | `AE` followed by 21 digits, with or without spaces | `[IBAN]` |
| Email addresses | `local@domain` | `[EMAIL]` |
| Phone numbers | `+971` / `00971` / `05x` forms and other 9+ digit runs | `[PHONE]` |
| Reference and transaction ids | Any remaining run of 6+ characters mixing digits and letters | `[REF]` |
| The person's name | Exact, case-insensitive match of the name on the account and each of its words (3+ letters), in Latin and Arabic, from the device | `[NAME]` |
| Greeting lines | A line starting with a greeting word (`Dear`, `Hello`, `Hi`, `عزيزي`, `عزيزتي`, …) is dropped whole | (removed) |
| Footer | Everything after the first line that starts a known footer (unsubscribe, disclaimer, "This is an automated", …) | (removed) |
| Links | URLs | `[LINK]` |

Kept: amounts with currency, the merchant text, dates, times and the alert's own words.

Then the person sees the redacted text in the review sheet under "Send this to Cloudflare
to read?", with Send and Cancel. Nothing is sent without that tap, every time. A
"Don't ask again" option is **not** offered in v1 (decision D4).

If redaction fails a sanity check (the text is empty, or more than half of it was removed,
or a digit run of 12+ survived), the phone doesn't offer the button.

## How the answers are used

### Clef → a category suggestion

- New type `CloudCategoryModel: CategoryModel` in a new `HasalaCloud` target the app
  links (the core sees only the protocol, as with `HasalaModel`).
- `suggest(subject:allowed:)` sends one `choice` question to `clef` (not `clef-flash`,
  which was slower and less accurate in the spike). The criteria are the allowed
  categories with their `TaxonomyV1.modelHints`, plus an `unknown` option ("the name
  alone does not say what kind of business this is"). It answers `.category(id)` only
  when the top option is not `unknown`, its probability is ≥ 0.6, **and** it is at least
  0.2 above the second; otherwise `.unknown`. In the spike these thresholds gave 99%
  precision at 87% coverage.
- Budget: Clef took a median of 1.9 s (p90 3.1 s) per call. The foreground phase budget of
  20 s fits about 10 calls one after another, not the 40 the tier allows. Up to 4 calls
  may run at once: each is still a single, unlinked subject.
- `modelTag` is `cf-clef/<version>`, written to `txn_categorized {source: model}` as
  today. The row keeps `needs_review`, so it never counts in a total until the person
  confirms it.
- Order when both are available (decision D1): Apple's model first for Latin subjects;
  Clef for subjects that fail the Latin gate, or when Apple's model is unavailable or
  answers `.unknown`.
- Failures map onto `ModelFailure` (`timeout`, `rateLimited`, `busy`, `other`). A failure
  leaves the row in review, as today.

### Clairic → pre-filled review fields

- Runs only for a message from a **trusted** sender (`gates.senderTrusted`, A-R pass). A
  message that may be spoofed is never sent.
- The phone fetches the alert again by its message id (as "open the original alert" does
  today), redacts it, shows it, and sends it on the person's tap.
- Amount: Clairic's `number` fields have **no span**. In Cloudflare's own example, the
  invoice total comes back as `1080`, a sum the model worked out from the line items, not
  text copied from the input. So the amount is asked as a `text` field, whose answer is a
  span of the alert, and the phone converts that span with the existing money normaliser
  into integer fils. The `number` field is asked as well, only as a cross-check: if the
  two disagree in magnitude, the amount field stays empty. (The number's sign is
  unreliable: it came back negative for 17 of 81 debits and positive for the rest.) No
  float touches money.
- Currency: taken from the amount span (its ISO code prefix or suffix), never from a
  separate currency field. A field asking for the ISO code came back `null` in 93 of 96
  alerts, even when the alert said `AED`.
- Merchant: the span text. A `null` answer, or a confidence below 0.7, leaves it empty.
- Date: **not taken from Clairic.** When an alert has no date, Clairic returns the
  `reference_date` with a confidence near 1 (65 of 65 such alerts), and a `date` answer
  has no span to check it against. It also moved one written date by a day. The sheet
  keeps the empty shape's day (`dayPostedAt`, the mail's received day), as today.
- Direction: **not taken from Clairic.** As a span, it was right for only 57 of 94
  alerts. The sheet asks the person, as it does today for the empty shape.
- A declined payment came back with an amount. That's acceptable only because the sheet
  is a pre-fill the person checks; the sheet must never save without the person's tap.
- The fields are a pre-fill. Saving them is an ordinary user edit, so no new op kind and no
  change to the fold. The original empty review shape stays in the log as it is.

## The switches

- Profile › Privacy › **Cloud suggestions**, with two switches: **Merchant suggestions**
  and **Alert reading help**. Both off by default, on every device separately (they're
  device settings, like Hide amounts, and never sync).
- Turning one on shows one screen first: what is sent, an example of a request, that
  Cloudflare answers and keeps nothing, that the IP address is visible to Cloudflare, and
  that turning it off stops it at once. The switch turns on only from that screen's
  button.
- Suggestions from Clef show "Suggested by Cloudflare AI" in the review sheet; Apple's say
  "Suggested on this iPhone". A person can always tell which is which.
- Release builds show the section only when the Worker's URL is in the build
  (`BuildSurface`), so a build without it shows nothing.

## Cost

At the beta's scale this costs almost nothing, and the global cap bounds it.

- Clef: 403 input tokens per subject (median in the spike) × $0.24 per million = about
  $0.0001 per new merchant. 100 people × 200 new merchants a month ≈ 20,000 requests ≈
  $2 a month.
- Clairic: 1,036 input tokens per alert (median; 791 of them are the field schema) ×
  $0.10 per million = $0.0001 per alert, and only for alerts a person chooses to send.
- The whole spike (120 subjects twice, 96 alerts) cost less than one US cent.
- Global cap: 10,000 Clef and 1,000 Clairic requests a day, then the Worker answers
  `rateLimited` until the next UTC day.

## Checks before building

Each of these can change the design. Run them with synthetic data only.

1. **Arabic. RESULT (2026-10-20): passes.** Clef reads Arabic merchant names as well as
   Latin ones. See [Spike results](#spike-results-2026-10-20).
2. **Retention and training. RESULT (2026-10-20): passes, with one gap.** Cloudflare's
   [Workers AI data usage page](https://developers.cloudflare.com/workers-ai/platform/data-usage/)
   (last updated 2026-10-16) says Cloudflare does not use Customer Content processed by
   Workers AI to train models, and that for a standard inference request it does not keep
   inputs or outputs once the request is processed. It keeps operational metadata (model
   id, timestamps, token counts) without content. Content is stored only when we add a
   storage service, turn on AI Gateway logging or caching, use an asynchronous or batch
   feature, or when the law requires it. The design already forbids all of these on the
   Worker, and its requests must be synchronous (no `queueRequest`). The gap: the page
   doesn't name Clef or Clairic, and both are Cloudflare's own models, while its
   statements are about Workers AI in general. Ask Cloudflare to confirm in writing that
   the terms cover these two models, including Clairic while it is in preview, before
   shipping.
3. **Clairic is in preview.** Its page says it may be withdrawn without notice. Alert
   reading help must degrade to today's empty review sheet when the model is gone. Decide
   whether a preview model is acceptable even for the QA beta (decision D5).
4. **Google Limited Use.** Sending a redacted Gmail alert to an AI service for a feature the
   person asked for is a transfer "to provide user-facing features". Re-read the Google API
   Services User Data Policy's AI section against this design before shipping Alert
   reading help, because Hasala uses the restricted `gmail.readonly` scope and will need
   verification above 100 users. Merchant suggestions use only a string derived from the
   alert, so the same check applies there.
5. **Clairic on bank alerts. RESULT (2026-10-20): passes for amount and merchant, fails for
   date, direction and currency.** The design now takes only the amount and merchant from
   Clairic. See [Spike results](#spike-results-2026-10-20).
6. **The `source.model` tag.** Check that the fold and the projection accept a model tag
   other than `apple-fm/…` (03c §3.2.1), and add a conformance case if the tag is part of
   one.

## Spike results (2026-10-20)

Run on Workers AI from the owner's account with synthetic data only. The sets, the runner
and the raw answers are in `hasala-agent-scratch/explorations/cloud-suggestions-spike/`
(not in this repository).

### Clef on merchant names

The set: 120 invented merchant subjects, labelled by hand against the 11 categories the
tier allows: 60 in Arabic script, 55 Latin (some transliterated Arabic, such as
`MATAAM AL BAIT`), 5 mixed. 6 of them (3 Arabic, 3 Latin) are deliberately unclear
names, such as a general trading company, labelled `unknown`.

| | Top choice right | After the gate (≥ 0.6, margin ≥ 0.2): answered | After the gate: right |
|---|---|---|---|
| `clef`, Arabic (57) | 52 (91%) | 45 (79%) | 45 of 45 (100%) |
| `clef`, Latin (52) | 48 (92%) | 49 (94%) | 48 of 49 (98%) |
| `clef`, mixed (5) | 5 | 5 | 5 |
| `clef`, all (114) | 105 (92%) | 99 (87%) | 98 of 99 (99%) |
| `clef-flash`, all (114) | 96 (84%) | 87 (76%) | 86 of 87 (99%) |

- All 6 unclear names came back `unknown` after the gate, with both models.
- The one wrong answer that passed the gate: `AL NOOR BAKERY` → dining (p 0.76), labelled
  groceries. A bakery is honestly ambiguous.
- What the gate held back were mostly names with no category word: co-operatives
  (`UNION COOP BR 12`, `جمعية الاتحاد التعاونية فرع ٣`), utility brands (`EMPOWER COOLING`,
  `SEWA SHARJAH`), a car wash, a bookshop. They stay in review, which is what should happen.
- Other gate settings: 0.5/0.1 answered 102 at 99%; 0.7/0.3 answered 94 at 99%; 0.8/0.4
  answered 81 at 100%. 0.6/0.2 is kept.
- `clef`: median 1.9 s, p90 3.1 s. `clef-flash`: median 2.8 s, p90 6.0 s, so it is slower
  as well as less accurate. Use `clef`.
- Limits of this result: the names are invented and clean, and most carry a word that
  says what the business is. Real alert descriptors are often cut short or carry terminal
  codes, so expect lower coverage on real data (not lower precision, if the gate holds).
  Apple's model was not run on the same set, so this doesn't show whether Clef beats it on
  Latin names (decision D1).

### Clairic on bank alerts

The set: 96 synthetic alerts. 88 are the matched cases of the bank fixtures in
`conformance/templates/` (ADIB, DIB, ENBD, plus the generic `synth.*` edge cases), with
their expected values. 8 are new layouts no template reads: a new purchase layout, an
Arabic purchase with Arabic-Indic digits, a refund, a foreign-currency purchase, an ATM
withdrawal, a salary credit, a declined payment and a one-time-password email.

| Field | Fixture alerts (88) | New layouts (8) |
|---|---|---|
| Amount, from the `text` span | 86 | 7 |
| Amount, `number` field (magnitude) agrees with the span | 88 | 8 |
| Merchant, exact | 69 | 8 |
| Date, when the alert has one | 23 of 23 | 6 of 7 |
| Date, when the alert has none: returned the `reference_date` | 65 of 65 | n/a |
| Direction, from a `text` span | 52 | 5 of 6 |
| Currency field not `null` | 2 | 1 |

On the 70 alerts in a real bank's shape (the ADIB, DIB and ENBD fixtures plus the new
layouts), the amount was right in 68 and the merchant in 55.

- The two wrong amounts: in a fixture with two amounts, Clairic took the second one; in a
  fixture with a malformed amount, it returned `null` (safe). The declined payment got its
  amount, and the one-time-password email correctly got none.
- Merchant misses were mostly `null` where a template takes a fixed label (`ATM`, `FEE`,
  a transfer's beneficiary), plus a truncated `SAMPLE.AE DUBAI` and an emoji dropped. A
  `null` merchant leaves the field empty, which is safe.
- Median 2.0 s, p90 3.0 s, always 5 passes.
- What this changed in the design: amount from the span with the number as a
  cross-check, currency from the amount span, no date and no direction from Clairic (see
  [How the answers are used](#how-the-answers-are-used)).

## Decisions for the owner

| # | Question | Recommendation |
|---|---|---|
| D1 | Clef for every subject, or only where Apple's model can't answer? | **Decided:** only where Apple's model can't (non-Latin subjects, Apple's model unavailable, or its answer `unknown`). Less data leaves the phone. |
| D2 | Offer custom category names to Clef? | **Decided:** not in v1. Revisit with a per-category "may be sent" mark. |
| D3 | Abuse control: per-IP rate limit only, or Privacy Pass tokens issued by hasalad? | **Decided:** rate limit for the beta. Privacy Pass is unlinkable and stronger, but it needs blind RSA (RFC 9474), which CryptoKit doesn't offer, and a third-party crypto library would trip the export-compliance guard (`inspect-ipa.sh` I9, `docs/decisions/export-compliance.md`). |
| D4 | Allow "Don't ask again" for Alert reading help? | Deferred with Clairic. No in v1. Each alert is shown and confirmed. |
| D5 | Ship a preview model (Clairic) in the QA beta? | **Decided:** no. Clairic is deferred; it may first be used as a build-time tool that drafts bank templates from synthetic alerts. |
| D6 | Amend the 2026-10-11 decisions in CLAUDE.md? | **Decided, done for Merchant suggestions only:** "The server is blind" stays for hasalad; add that opt-in cloud suggestions may send a merchant string, or a redacted alert the person approved, to Cloudflare Workers AI through an identity-free Worker that keeps nothing. "Categorization occurs on the device" gains the cloud step after Apple's model. |

## Privacy policy changes

While Clairic is deferred, drop every Alert reading help part from the text below (the
second bullet of the new section, the alert words in the short version, Limited Use and
the provider row).

Do these in the same pull request that ships the feature to testers, not before, and give the
30 days' notice the policy promises ("Changes to this policy"), because this materially
changes what is sent where. Set `lastUpdated` to the ship date.

**Front matter `plainWords`.** Replace the last sentence
"We don't sell data, show ads or send anything to an AI service." with:

> We don't sell data or show ads. Nothing goes to an AI service unless you turn on Cloud
> suggestions, and even then we send only what's listed here, without your name or account.

**The short version**, the "No ads, no data sales, no AI services." bullet becomes:

> - **No ads, no data sales. AI services only if you ask.** Hasala sorts transactions on
>   your iPhone. If you turn on Cloud suggestions (off by default), Hasala can send a
>   merchant name, or a bank alert you've seen and approved with your personal details
>   removed, to Cloudflare's AI service for an answer. It isn't sent with your name, your
>   account or anything that links it to you, and it isn't kept. Data from your Gmail or
>   Outlook is never used to train AI models (see [Cloud suggestions](#cloud-suggestions)).

**New section**, after "Notifications":

> ## Cloud suggestions
>
> Cloud suggestions are off unless you turn them on, on each iPhone, under Profile ›
> Privacy › Cloud suggestions. There are two, and you can turn each on or off at any time.
>
> **Merchant suggestions.** When Hasala can't sort a payment with your rules, its merchant
> list or Apple's on-device model, it can ask Cloudflare's AI service to suggest a
> category. It sends the merchant name as it appears in the alert, for example
> "CAFE EXAMPLE JBR", and Hasala's built-in category names. It doesn't send the amount,
> the date, your card, your bank, your own category names or anything about your account.
> Each merchant is sent on its own. The suggestion is marked "Suggested by Cloudflare AI",
> and it doesn't count in your totals until you confirm it.
>
> **Alert reading help.** When Hasala can't read a bank alert, you can ask Cloudflare's AI
> service to read it. Hasala first removes your name, card and account numbers, IBAN,
> email addresses, phone numbers, reference numbers and links, and shows you exactly what
> it will send. Nothing is sent until you tap Send, each time. The alert's amount,
> merchant and date are sent, because that's what it needs to read. Hasala fills in the
> transaction for you to check and save.
>
> **What Cloudflare sees and keeps.** These requests go to a Hasala service on Cloudflare,
> not to our server. They carry no account, sign-in or device identifier. Like any request
> over the internet, Cloudflare sees your IP address; the service uses it only to limit
> abuse, in memory, and doesn't record it. The service doesn't store or log what you send,
> and Cloudflare doesn't keep it or use it to train its models. We never see these
> requests.
>
> **What we can't hide.** A removed name or number can't be linked back to you from our
> request, but an alert still describes one payment. If you'd rather nothing about your
> payments leaves your iPhone, leave Cloud suggestions off; everything else in Hasala
> works the same.

**How we use your data**, add to the list:

> - give you Cloud suggestions, if you turn them on;

and to the grounds:

> - **Your consent.** This also covers Cloud suggestions, which you turn on yourself and can
>   turn off at any time.

**Limited Use**, item 2, replace "In practice it isn't transferred at all." with:

> If you turn on Cloud suggestions, a merchant name, or an alert you approved with your
> personal details removed, is sent to Cloudflare's AI service to give you a suggestion,
> and isn't kept. Otherwise it isn't transferred at all.

**Limited Use**, item 6 becomes:

> 6. **No AI training.** We don't use it to develop, improve or train AI or machine
>    learning models, and Cloudflare's AI service doesn't either. Hasala's categorisation
>    runs on your iPhone using Apple's on-device model. Only if you turn on
>    [Cloud suggestions](#cloud-suggestions) does Hasala send a merchant name, or an alert
>    you approved, to Cloudflare's AI service, for one answer.

**Our promises for Outlook data**: no change to the text. It already refers to Limited Use.

**Who else handles your data**, new row:

> | **Cloudflare Workers AI** | If you turn on Cloud suggestions: runs the AI models that suggest a category or read an alert. | The merchant name or the redacted alert you approved, Hasala's built-in category names, and your IP address. No account or device identifier. It answers and keeps nothing. |

and change "Apart from that, we don't use any other service provider that handles your
personal data." to keep it true (the new row is listed above it).

**How long we keep data**, add:

> - Cloud suggestions requests: not kept. Our service answers each request and forgets it.

**Security page** (`docs/legal/security.md`): add one line under what the design doesn't
protect against: with Cloud suggestions on, Cloudflare sees the merchant names, or the
redacted alerts, the person chose to send.

## Build plan

In order; each step is its own pull request.

1. **Spike (no app change). DONE 2026-10-20**, see [Spike results](#spike-results-2026-10-20).
   Still open from it: Cloudflare's written confirmation for check 2, and a run of
   Apple's model on the same merchant set for D1.
2. **Redaction.** `Redact` in HasalaCore: a pure function with synthetic vectors for each
   bank's format, including Arabic names and greetings, and the sanity checks.
3. **The Worker** in `infra/assist/` (or `web/`'s sibling): two routes, the AI binding,
   rate limit, global cap, version refusal, no storage bindings. A fence test that fails
   on any KV, D1, R2, Durable Object, Queue, AI Gateway, Logpush or observability setting
   in its `wrangler.jsonc`. Deployed by the owner.
4. **Merchant suggestions.** `HasalaCloud` target with `CloudCategoryModel`, the order of
   D1, the switch and its screen, the "Suggested by Cloudflare AI" label, the check 6 fix.
5. **Alert reading help.** The review-sheet button, preview, send and pre-fill, with the
   money conversion from span text.
6. **Policy and decisions.** The privacy-policy and security-page text above, the CLAUDE.md
   decision amendment (D6), and the 30-day notice to testers.
