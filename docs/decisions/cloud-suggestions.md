# Cloud suggestions: opt-in Clef and Clairic (design)

**Status: Merchant suggestions (Clef) DECIDED and in progress (2026-10-20). Alert reading
help (Clairic) DROPPED.** The spike is done ([results](#spike-results-2026-10-20)). The
owner approved Merchant suggestions with the recommended answers to D1-D3 and D6 (see
[Decisions for the owner](#decisions-for-the-owner)). Clairic was then tried for mail
reading on synthetic mail on the extraction bench and dropped; mail that no template
reads is now read on the phone, with no model and no network call
(`template-free-reading.md`). The Clairic sections stay in this file for reference;
nothing for Clairic is built.

The owner decided (2026-10-20): the Workers AI data usage page is enough for check 2, and
no written confirmation from Cloudflare is needed. The policy states the claim as
Cloudflare's terms and links that page. Because the feature is opt-in and off by default,
the policy describes it from the day it ships, with no 30-day wait; testers are told in
TestFlight's What to Test. A security review of the Worker and the client runs before
the Worker is deployed (see [Privacy policy changes](#privacy-policy-changes)).

The owner decided (2026-10-21) that a person could start a sort of the payments waiting
in Review, and then (2026-10-23) that no one has to: with Merchant suggestions on, Hasala
works through the waiting merchant names by itself while the app is open, within the
per-device day cap. Since the streamlined onboarding (2026-10-21), setup ends after the
mailbox connect, and its ask is a card in Review, asked once on each iPhone.
See [Sorting what's waiting](#sorting-whats-waiting-owner-decisions-2026-10-20-2026-10-21-and-2026-10-23).

The owner decided (2026-10-24) that the legal pages suit an experimental beta, and they were
rewritten (Sorting rebuild 9). The privacy policy no longer promises 30 days' notice:
"Changes in the beta" says that features and the pages can change at short notice, that a
change takes effect when it is posted, and that testers are told what changed in the app or
in the TestFlight notes when it affects how their data is used. A new optional cloud feature
is still off until the person turns it on. This settles the notice question for the
background stage (see [Privacy policy changes](#privacy-policy-changes)).

Every example in this file is synthetic. No real mail, merchant, amount or name was used.

## Summary

Two optional features, both **off by default**, each with its own switch:

| Feature | Model | What leaves the phone | Where it plugs in | What it may do |
|---|---|---|---|---|
| **Merchant suggestions** | Clef (`@cf/cloudflare/clef`) | One canonical merchant string per request, plus the built-in category list | A second `CategoryModel` behind the existing model tier (`Categorize/ModelTier.swift`) | Suggest a category. Files a row only with the second opt-in, [Sort automatically](#sort-automatically-owner-decision-2026-10-20), above its stricter gate; Apple's model never files one (`ModelTier.autoConfirm = false` stays). |
| **Alert reading help** (dropped, see `template-free-reading.md`) | Clairic (`@cf/cloudflare/clairic`) | The body text of **one** bank alert, redacted on the phone, shown to the person first | The review sheet for an alert no template could read (the empty review shape, `ParsedMail.fields == nil`) | Pre-fill the sheet's fields. The person saves them; the op is an ordinary user edit. |

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
- Only rows read by a card-payment alert template go to Clef: `adib.alert.v1`,
  `dib.card.v1` and `enbd.alert.v1` (`ModelSuggestionSweep.cloudTemplates`). A transfer
  template's merchant is a beneficiary's name, so transfers (`enbd.transfer.v1`), account
  alerts (`adib.account.v1`, `dib.account.v1`) and manual entries stay on the device. A
  subject shared with any of those rows is not sent either. The check is fail-closed: a
  row with no template, or a new template, is not sent until it is added to the list.

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

The background stage ([Sorting what's waiting](#sorting-whats-waiting-owner-decisions-2026-10-20-2026-10-21-and-2026-10-23))
doesn't batch either. Each request still carries one name. A batched endpoint would save
round trips only, not model cost, and the Worker's fence test forbids it.

### No identity at the Worker

- The Worker accepts requests without a Hasala session token. It must not call hasalad and
  must not receive the person's account id, email, push token or App Attest key id.
- Abuse control in v1: a per-IP rate limit in the Worker (Cloudflare's rate-limiting
  binding, held in memory at the edge, not stored by us) and a global daily request cap
  that fails closed. See decision D3 for the stronger option (Privacy Pass tokens).
- As built: `PER_IP` allows 30 requests per 60 s and `GLOBAL` 600 per 60 s. `GLOBAL` was
  60 for some hours on 2026-10-20. At twice `PER_IP` it left too little room for the
  phones at one location, so it went back to 600, and the fence test keeps it at 20 times
  `PER_IP` or more. Cost is not the job of `GLOBAL`: the AI Gateway spend limit below is the
  account-wide stop. One phone's foreground sweep can send up to 40 requests, so `PER_IP`
  stays at 30. The per-IP limit is keyed on the IPv4 address or the IPv6 /64, and it is
  checked before the global limit, so a refused request does not use a global token. Both
  limits count per Cloudflare location, so the global limit is not an account-wide or daily
  cap.
- The account-wide stop (2026-10-20) is an AI Gateway spend limit. The Worker sends each
  model call through one dedicated gateway (`hasala-assist`, from the `AI_GATEWAY`
  variable). The gateway counts the dollar cost of all calls, across all locations, and
  refuses each call when the limit is reached, until its window resets. The Worker then
  answers 503 `model_unavailable`, and the phone treats it as busy: the foreground sweep
  stops its cloud stage, and the background run pauses. This fails closed. An empty `AI_GATEWAY` also gives 503, without a model call.
  The cost is an estimate, and a burst can go a little over the limit. A Workers AI
  billing alert stays as a second, late warning. The gateway sees no more than the
  Worker already sends to the model, and it gets no account identity.
- The request carries a fixed app version header only, so the Worker can refuse versions
  with a known bad redaction.

### Nothing kept

- Workers observability off, no `console.log` of bodies, no Logpush, no tail Workers.
- AI Gateway logs prompts and responses by default, so a gateway is allowed only with its
  logging off and its cache off. The one gateway is the spend cap (see
  [No identity at the Worker](#no-identity-at-the-worker)). Each call sends
  `collectLog: false` and `skipCache: true`; the request value has priority over the
  gateway setting. The gateway's own Logs and Cache settings are off too. The gateway id
  `default` is not allowed, because Cloudflare makes that gateway with logs on. The fence
  test fails on any other gateway use: another id source, a cache TTL or key, metadata,
  `cf-aig-` headers, logging on or cache on. The gateway's analytics keep counts, tokens,
  cost and errors per model, without content.
- The Worker returns the model's answer and forgets the request. No KV, D1, R2, Durable
  Object or Queue binding on this Worker. A fence test checks the Worker's
  `wrangler.jsonc` for these bindings (see [Build plan](#build-plan)).

### What we can't hide

- **Network address.** Cloudflare's edge sees the phone's IP address on every request, as
  it already does for hasalad and the website. The Worker uses it only for the rate limit,
  in memory. The policy says so plainly.
- **Timing.** Merchant suggestions are meant to run only while the app is open: in the
  foreground sweep and in the background stage, never in a background refresh or a push
  wake (the tier already forbids `refresh` and push wakes, and the background stage starts
  nothing while the app is in the background). One gap remains (found 2026-10-24): when iOS
  starts the process in the background, for a silent push or a background task, the account
  opens and its launch run runs the foreground sweep (`ModelSuggestionStage.runs(.launch)`).
  Nothing checks `applicationState`, so up to 40 names can go out then, within the day cap.
  Until a code change gates `.launch` on the app state, the privacy policy, Security and
  Support say "mostly while the app is open" and name this case. Requests from one sweep
  go out with a small random delay between them, so a sweep is not one burst. They are still close in time, and the
  policy does not claim otherwise. The background stage can send many requests from one
  connection in a few minutes, and requests that close in time can be seen together at the edge, by
  address and time. The shuffled order blunts what their sequence says about someone's
  spending. The policy says this in "What we can't hide".
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
- Order (decision D1): with Merchant suggestions on, Clef first, then Apple's model for
  Latin subjects that Clef couldn't answer. With it off, a Release build runs no model,
  as before this feature (the beta doesn't use Apple's model on its own). A Debug build runs Apple's model alone, for development.
  Neither model is asked about a merchant whose payments the person sorted themselves (a
  pick on a refund or other money in, or a split payment, doesn't count): the person's
  last pick is the suggestion
  ([sorting-rework.md](sorting-rework.md#your-last-pick-beats-the-ai)).
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

### Sort automatically (owner decision, 2026-10-20)

A second opt-in, under Merchant suggestions. With it on, a Clef answer that clears a
stricter gate **files** the row instead of only suggesting it.

- Gate: the chosen probability is ≥ 0.8 and leads the second by ≥ 0.4. In the spike
  this answered 81 of 114 names (71%) with 81 right (100%). An answer that clears only
  the 0.6 / 0.2 gate stays a suggestion in review.
- Clef only. Apple's model gives no probabilities to grade, so its answers stay
  suggestions (`ModelTier.autoConfirm = false` is unchanged). A cloud model declares that
  it can grade by conforming to `GradedCategoryModel`.
- The op is `txn_categorized {category, needs_review: false, source: model("cf-clef/1")}`.
  The row counts in totals at once.
- The row shows "Sorted by Cloudflare AI". Changing its category by hand makes it a user
  decision, as today.
- It can be on only while Merchant suggestions is on. Turning Merchant suggestions off
  turns it off too.
- Risk: a wrong auto-sort changes a budget without a review step. The stricter gate, the
  label and the per-device switch are the mitigations. Watch for wrong auto-sorts in the
  beta, and raise the gate if testers report them.

### Sorting what's waiting (owner decisions, 2026-10-20, 2026-10-21 and 2026-10-23)

On 2026-10-20 the owner decided that a bulk sort was offered only in setup, "never as a
bulk button later", to keep the cost bounded. On 2026-10-21 the owner reversed that: a
person could start a sort from Review, from Profile, or in setup. On 2026-10-23 the owner
rejected the run card and its offers, and decided the rule that holds now: **with Merchant
suggestions on, Hasala works through every waiting merchant name by itself while the app
is open**, a silent background stage, the way recurring payments are found. Each request
still carries one name, and the per-device day cap holds. There is no run card, no "Sort N
merchants" offer, no paused or result card, no Check suggestions sheet, and no **Sort now**
or **Later** in Profile. People who turned Merchant suggestions on in an earlier build get no
30-day notice for this change: the owner settled that on 2026-10-24 with the beta clause (see
[Privacy policy changes](#privacy-policy-changes)). The TestFlight notes of the build that
ships the stage say what changed.

**The one-time ask.** With Merchant suggestions off, a card at the top of Review asks
**Sort the rest with Cloudflare AI?** (`Features/Review/CloudSortAsk.swift`). It shows
only when items wait to be sorted, the build has the Worker's URL (`BuildSurface`), this
iPhone hasn't answered it (`MerchantSuggestionsSetting.reviewAskAnswered`: Turn on, Not
now, or Merchant suggestions turned on or off in Profile) and the account isn't the review
account. It is asked once on each iPhone. An iPhone that finished setup before the ask
moved to Review counts as answered (`MerchantSuggestionsSetting.migrateReviewAsk`, once per
install): the setup screen asked it already.

- The card says what is sent (the merchant name, with an example), what is not sent, that
  only very sure answers are filed, and where to turn it off. **What Cloudflare sees**
  opens the full sheet: the built-in category names, each name once, what Cloudflare sees
  (the same text as the Profile sheet), what gets filed, and that both switches can be
  changed in Profile. **Turn on** and **Not now** are two pill buttons of the same size, on
  the card and on the sheet.
- **Turn on** sets both switches (`MerchantSuggestionsSetting.turnOnBoth`, the owner's
  default), and the background stage takes over. **Not now** leaves both off, and the ask
  never comes back. Nothing else asks or offers while Merchant suggestions is off.
- The ask and the importing card share the slot above the queue; the ask comes first.

**When it runs.** `BacklogSorter.ensure()` starts a run when Merchant suggestions is on, no
run is running or paused, the app is in the foreground, and at least one waiting name may
be asked (`ModelSuggestionStage.backlogWaiting`: Clef is available, and a name that rules
and the dictionary don't place is not cached, not on a row that may not leave the phone and
not settled earlier in this session). It is called:

- when the account opens (`AccountRuntime.open`);
- when the app comes back to the foreground (`BootController.foreground`);
- when an import commits rows or ends (`ImportFollower`);
- after each run of the coordinator commits (its `committed` stage, so a sync that brings
  new rows starts one);
- when Merchant suggestions is turned on, in Profile or from the ask
  (`MerchantSuggestionsSetting.turnedOn`, next to `turnedOff`).

The open and the coordinator's run don't wait for the check: each calls `ensure()` in a
task of its own. One check runs at a time; calls that arrive while it runs share one more
check after it.

The stage is held while the account is stopped (`BacklogSorter.allowRuns`). It starts held
when the account opens. `AccountRuntime` releases it when the launch check (`LaunchProbe`)
passes, or stops on anything but a freeze, a halt, **Update Hasala** or a stop that closes
the account (offline, for example), and after each sync that ends without a stop. It holds
it again when the launch check finds the account frozen or this build too old, and when a
run of the coordinator stops on a freeze, a halt, **Update Hasala** or a stop that closes
the account. While it is held, `ensure()` and the resume start nothing (a call to
`ensure(retry: true)` still arms the open's retry), and a run that is going stops where it
is and keeps its phase. The release resumes a run that is running or paused under the
pause's own rules, and the next `ensure()` starts a new one.

For a run that is running or paused, `ensure()` only resumes it under the pause's own
rules (below); it never restarts a paused run. A run that ended after three failed passes,
after a refusal, or because Clef was not available is tried again at the next open, or when
the person turns the switch on again, never in a loop. This holds also for a run that the
open resumed: when it ends this way, the open's retry is used up. Turning Merchant
suggestions off stops a run at once (`turnedOff`, `BacklogSorter.switchedOff`, which does
nothing when the switch reads on again by then). It never runs in a
background refresh or a push wake: `ensure()` starts nothing while the app is in the
background, and a run that is already going holds until the next foreground.

**One engine.** `BacklogSort` (HasalaCore) plans and runs each pass; `BacklogSorter` (the
app) holds the run. Its state is a device-local record in the device's own database, next
to `fm_cache` (`backlog_run`): the run's phase, its pause reason and until-time, the day
ledger, the time of the last pass, and the rows a run on this device filed. It never syncs.
The names a session has settled are kept in memory and forgotten at the next open. Each
pass first drops an answer kept in memory whose category is no longer on the list Clef is
offered (for example a category deleted or turned off since). The name is then planned
again under the current list (the cache, else Clef), so a run never files a row into a
category that is gone. The record still writes the fields the run card build needs to
read a run (an empty id, zeros and an empty manifest), so after a downgrade that build
keeps the day ledger and the rows filed here.

**What it asks.**

- Rules and the dictionary still go first. It reads the same model queue as the
  foreground sweep (`Sweep.plan`), with the same eligibility (a debit with no category,
  source not user or held, and no pick of the person's for its merchant group and
  direction, `SweepRow.picked`) and the same card-template allowlist (`cloudTemplates`). A
  name is not sent when it shares a subject with a row that may not leave the phone.
- Clef only. It never runs Apple's model. While a run is running, or paused for a 429 or
  a 503, the foreground sweep waits (`backlogActive`). While the run is paused on the day
  cap, the sweep runs Apple's model only, so it can answer names Clef was not asked about
  that day. When the day has fewer requests left than the sweep has names, Clef is asked
  about as many as are left and Apple's model about the rest. Once the run ends, the
  foreground sweep runs Clef and then Apple's model, as before.
- One request per distinct canonical subject, asked in a random (shuffled) order, not by
  date. Answers are reused for rows that load later with the same subject.
- Category answers are cached in `fm_cache` for 30 days, as `unknown` answers already
  were. A later run, or another account on the same phone, doesn't ask a name twice.

**Caps and numbers.**

| What | Value |
| --- | --- |
| Calls at once | 3 |
| Names per pass | 12 |
| Pass spacing | 30 s from the start of the last pass, kept when new rows wake the run and across a relaunch (the record keeps the last pass time); at most 24 a minute, under `PER_IP` 30 per 60 s |
| Names per run | No cap. A run goes on until nothing waits, a pause, or the day cap |
| Names per device per day | 400, over a rolling 24 h, shared with the foreground sweep |
| Tries per name | 3 in a session; a 429 or 503 doesn't use up a try |
| 429 | waits of 1, 3 and 10 minutes, then the run pauses for 10 minutes and resumes on a foreground after that |
| 503 (spend limit, or the model gone) | the run pauses for 15 minutes, and resumes on a foreground after that |
| Offline | the run pauses, and resumes on its own when the phone is back online |
| In the background | the run pauses, and resumes on the next foreground |
| Day cap reached | the run pauses, and resumes on a foreground once the rolling window has room |
| 3 failed passes in a row (the database or the outbox failed) | the run ends; it is tried again at the next open |

A 503 or 429 pauses the run, and the run resumes by itself. The run is foreground only (no
`BGContinuedProcessingTask`), so "never in a background refresh or a push wake" still
holds. A run survives the app being killed: the next launch continues from the saved
record, and waits out the rest of the 30 s spacing first. Filed rows are no longer
eligible, and cached names are not asked again. Turning Sort automatically off lets the
run go on, but nothing more is filed without review.

**One day ledger.** Every Clef request counts toward the 400 a day: the run's, and the
foreground sweep's (up to 40 per foreground). A request counts when it is sent, also when
the pass fails afterwards (a cache write, the re-read, the outbox or the re-projection),
and a pass that enqueued some of its blobs before a failure keeps those rows among the rows
filed here. The foreground sweep asks Clef for at most what is left of the day. While a run
is paused on the day cap, the foreground sweep doesn't ask Clef at all; Apple's on-device
model still runs. A record from a build with the run card keeps its day ledger and the rows
filed here; a run it had paused at the old per-run cap, or that the person stopped, reads as
ended, and the next `ensure()` starts a new one.

**Authoring.** As before: `txn_categorized {source: model "cf-clef/1"}`. The run re-reads
the rows before it authors and authors only rows still eligible at the same version. A row
the person edited meanwhile is left alone. The foreground sweep and the run share one
gate. What files and what only suggests doesn't change: with Sort automatically on, an
answer at or above 0.8 / 0.4 files the row when its mail gates passed; everything else at
or above 0.6 / 0.2 is a suggestion.

**What the screens show.** Review shows no sorting card. The status the app reads
(`CloudSortStatus`) has only the phase and the number of rows Profile can send back. The
deck holds no row back while a run is active (one card per payment, 2026-10-23): it keeps
the cards it opened with, and a card the run files meanwhile is skipped when its turn
comes. The top card stays until the person moves on, so nothing moves under the finger
([sorting-rework.md](sorting-rework.md#one-payment-per-card)).

**Sending back.** Profile › Cloud suggestions shows **Send Cloudflare's sorting back to
Review** while a row that a run on this device filed is still as the run left it, and asks
first ("Send 104 payments back to Review?"). The device keeps the rows it filed, with the
version it left each at, next to the run record. Sending back re-reads each row and authors
`txn_categorized {category: <same>, needs_review: true, source: model "cf-clef/1"}` only
for rows still at that version (`BacklogSort.sendBack`), so they go back to Review with
Clef's category as a suggestion. An edit on another device moves the version, and the row
is skipped. Rows another device's runs filed, and rows the foreground sweep filed with Sort
automatically on, are not sent back; they stay filed. Sending back doesn't stop the
background stage, and the rows it sent back are not asked about again, because each still
has a category.

**The run adds no op kind.** The run and sending back author only `txn_categorized`, and
there is no Worker or fence change. The sorting rework's **Not this** (#182, removed from
the app in the sorting rebuild; [sorting-rework.md](sorting-rework.md#old-rejections))
added one op kind, `merchant_category_rejected`, with its own fold map and replay goldens.
The app writes no new rejections, and the ones already in the log still apply. Rejections
are applied on the phone after the answer: a rejected answer reads as unknown for that
stage, so Apple's model is asked next, and a cached Cloudflare answer that was rejected is
never sent again (the phone keeps that answer in its own record, keyed by the name and the
model tag only, past the usual 30 days and across changes to the category list, until the
rejection is undone). The request, the `allowed` list and the cache key are unchanged.

**What leaves the phone is unchanged:** one canonical merchant string and the built-in
categories per request, from card-payment alerts only. Working through a backlog changes
how many requests are sent and when, not what each one carries (see
[One subject per request](#one-subject-per-request)).

## The switches

- Profile › **Cloud suggestions**, with two switches: **Merchant suggestions** and, under
  it, **Sort automatically**, which can be on only while Merchant suggestions is on. Both
  off by default, on every device separately (they're device settings, like Hide amounts,
  and never sync). The privacy policy's "two switches" are these. Alert reading help was
  dropped and has no switch. Review's ask is the one other place that turns Merchant
  suggestions and Sort automatically on (see
  [Sorting what's waiting](#sorting-whats-waiting-owner-decisions-2026-10-20-2026-10-21-and-2026-10-23)).
- Turning one on shows one screen first: what is sent, an example of a request, that
  Cloudflare answers and keeps nothing, that the IP address is visible to Cloudflare, and
  that turning it off stops it at once. The switch turns on only from that screen's
  button.
- Suggestions from Clef show "Suggested by Cloudflare AI" in the review sheet; Apple's say
  "Suggested on this iPhone". A person can always tell which is which. The person's own
  last pick says "Your last pick", and it comes before either model's answer.
- Release builds show the section only when the Worker's URL is in the build
  (`BuildSurface`), so a build without it shows nothing.

## Cost

At the beta's scale this costs almost nothing, and the AI Gateway spend limit bounds it
(see [No identity at the Worker](#no-identity-at-the-worker)).

- Clef: 403 input tokens per subject (median in the spike) × $0.24 per million = about
  $0.0001 per new merchant. 100 people × 200 new merchants a month ≈ 20,000 requests ≈
  $2 a month.
- Clairic: 1,036 input tokens per alert (median; 791 of them are the field schema) ×
  $0.10 per million = $0.0001 per alert, and only for alerts a person chooses to send.
- Working through a backlog: about $0.05 to $0.10 per 1,000 names, so a backlog of about 150 names
  costs about 1 to 1.5 US cents. The per-device cap of 400 names a day is at most about
  4 US cents.
- The AI Gateway spend limit of $1 a day covers about 10,000 to 20,000 names a day across
  all phones, about 70 to 130 backlogs of 150 names. Above it, the Worker answers 503 and
  runs pause until the gateway's window resets. If 100 testers each hit the daily cap, that
  would be about $4, so the limit would trip and the runs would wait; it fails closed.
- The whole spike (120 subjects twice, 96 alerts) cost less than one US cent.
- The account-wide stop is the AI Gateway spend limit ($1 a day), not a request count. Above
  it the Worker answers 503 `model_unavailable` until the window resets.

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
   statements are about Workers AI in general. The owner accepted the page as it is
   (2026-10-20); no written confirmation is asked for.
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
| D1 | Clef for every subject, or only where Apple's model can't answer? | **Decided (changed 2026-10-20):** with the switch on, Clef first for every subject that rules and the dictionary don't place; Apple's model is the fallback (Clef unavailable, rate limited, failed, or `unknown`). With the switch off, no model in Release (unchanged beta behaviour) and Apple's model alone in Debug. Reason: Apple's model gives no probabilities, so a row it answered first could never be sorted automatically, and Clef reads Arabic. Cost: every unplaced merchant name goes to Cloudflare, not only the ones Apple's model can't answer, except merchants the person already sorted themselves (their last pick is the suggestion; [sorting-rework.md](sorting-rework.md#your-last-pick-beats-the-ai)). |
| D2 | Offer custom category names to Clef? | **Decided:** not in v1. Revisit with a per-category "may be sent" mark. |
| D3 | Abuse control: per-IP rate limit only, or Privacy Pass tokens issued by hasalad? | **Decided:** rate limit for the beta. Privacy Pass is unlinkable and stronger, but it needs blind RSA (RFC 9474), which CryptoKit doesn't offer, and a third-party crypto library would trip the export-compliance guard (`inspect-ipa.sh` I9, `docs/decisions/export-compliance.md`). |
| D4 | Allow "Don't ask again" for Alert reading help? | Dropped with Clairic. |
| D5 | Ship a preview model (Clairic) in the QA beta? | **Decided:** no. Clairic was tried for mail reading on synthetic mail and dropped (`template-free-reading.md`). |
| D6 | Amend the 2026-10-11 decisions in CLAUDE.md? | **Decided, done for Merchant suggestions only:** "The server is blind" stays for hasalad; add that opt-in cloud suggestions may send a merchant string, or a redacted alert the person approved, to Cloudflare Workers AI through an identity-free Worker that keeps nothing. "Categorization occurs on the device" gains the cloud step after Apple's model. |

## Privacy policy changes

**2026-10-24: the legal pages were rewritten for an experimental beta (Sorting rebuild 9).**
`docs/legal/privacy.md` is now the record, and the text below is the 2026-10-20 plan, kept
for reference. What the rewrite records for Merchant suggestions:

- "Changes to this policy", with its 30 days' notice for a material change, became "Changes
  in the beta": features and the policy can change at short notice; a change takes effect
  when it is posted; when a change affects how data is used, the app or the TestFlight notes
  say what changed; a change that needs consent is asked for in the app first; and a new
  optional cloud feature is off until the person turns it on. The background stage needs no
  30-day notice for people who had Merchant suggestions on before it shipped; the TestFlight
  notes say what changed (the owner, 2026-10-24).
- The Cloud suggestions section describes the rebuilt sorting: one card per payment, the
  person's last pick (not sent to Cloudflare), Always use and its reach, New category (a
  custom name, never sent), the background stage within the per-device day cap, and the
  one-time ask. It now also says that the subject is sent in lower case, that only the
  built-in Need and Want categories that are on are offered, that names come only from
  payments out of the account and from bank alerts (never from a payment added by hand),
  that each request carries the app's version (`Hasala-Client`), that the phone keeps
  each answer for up to 30 days (`fm_cache`), and that an answer set aside after Not this
  stays on that phone until the account's data leaves it (`fm_kept`, no expiry). Only a
  sweep that queues the merchant again drops it, so a rejection the person lifts with their
  own pick keeps it. It says the sweep runs "mostly while the app is open", because of the
  launch-run gap in [What we can't hide](#what-we-cant-hide).
- "What stays on your iPhone" gains Search, which can use Apple's on-device model.
- Terms: provided as is, without warranty; the beta can change, pause or end at any time,
  and accounts and data may be reset or deleted then, with notice in the app or by email
  where possible. The 7-day and 30-day notice promises are gone.

Clairic was dropped, so drop every Alert reading help part from the text below (the
second bullet of the new section, the alert words in the short version, Limited Use and
the provider row).

Do these when the feature ships to testers. The feature is opt-in and off by default, so
"Changes to this policy" (since 2026-10-24, "Changes in the beta") lets the text take effect
on the day it ships; tell testers in TestFlight's What to Test. Set `lastUpdated` to the ship
date.

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
> Cloud suggestions are off unless you turn them on, on each iPhone, under
> Profile › Cloud suggestions. There are two, and you can turn each on or off at any time.
>
> **Merchant suggestions.** When Hasala can't sort a payment with your rules or its
> merchant list, it asks Cloudflare's AI service to suggest a category. Apple's on-device
> model is used when Cloudflare can't help. It sends the merchant name as it appears in the alert, for example
> "CAFE EXAMPLE JBR", and Hasala's built-in category names. It doesn't send the amount,
> the date, your card, your bank, your own category names or anything about your account.
> Each merchant is sent on its own. The suggestion is marked "Suggested by Cloudflare AI",
> and it doesn't count in your totals until you confirm it.
>
> **Sort automatically.** If you also turn this on, Hasala files a payment in the
> suggested category by itself when Cloudflare's AI service is very sure. Those payments
> count in your totals straight away and are marked "Sorted by Cloudflare AI". You can
> change any of them. It sends nothing more than Merchant suggestions does.
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
   Still open from it: a run of Apple's model on the same merchant set for D1.
2. **Redaction.** `Redact` in HasalaCore: a pure function with synthetic vectors for each
   bank's format, including Arabic names and greetings, and the sanity checks.
3. **The Worker** in `infra/assist/` (or `web/`'s sibling): two routes, the AI binding,
   rate limit, global cap, version refusal, no storage bindings. A fence test that fails
   on any KV, D1, R2, Durable Object, Queue, Logpush or observability setting in its
   `wrangler.jsonc`, and on any AI Gateway use except the spend-cap gateway with logging
   and cache off. Deployed by the owner.
4. **Merchant suggestions.** `HasalaCloud` target with `CloudCategoryModel`, the order of
   D1, the switch and its screen, the "Suggested by Cloudflare AI" label, the check 6 fix.
5. **Alert reading help.** The review-sheet button, preview, send and pre-fill, with the
   money conversion from span text.
6. **Policy and decisions.** The privacy-policy and security-page text above, the CLAUDE.md
   decision amendment (D6), and the note to testers in TestFlight.
