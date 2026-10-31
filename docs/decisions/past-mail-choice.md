# Past email on connect (decision record)

**Status: PROPOSED, for the owner to confirm in review (2026-10-31).** The owner asked for
the choice. The default and the rules below are the recommendation of the pull request.
Every example is synthetic.

## What the app did before

The behaviour is the same for Gmail and Outlook, because the scan is in `MailboxEngine`:

- A first connect always scans the past. The window comes from
  `MailboxEngine.backfillDays`: 90 days, or 365 days when the newest mail row of the account
  is more than 88 days old (`gapDays = age + 2`, which fills a long gap after a disconnect).
- The person did not choose. The app has no window picker, although the engine accepts 30.
- A new bank or sender imports the same window, from when it is added (`importLocked`).
- A second iPhone that takes the link over scans the window again. Op dedup makes this safe.

## The decision

A connect asks one question in a system alert, **Import your past email?**, after the person
taps the provider's button and before the sign-in. It has two answers and Cancel:

| Answer | What happens |
| --- | --- |
| **Import past email** (the first answer) | As before: the scan over the window above. |
| **Only new email** | No scan. The lane goes straight to `active`, and reads only mail from the connect onward. |

The alert runs from setup's bank step (the button and the "Use Outlook" chooser) and from the
provider screen in Profile (Add a mailbox, and the path from bank texts to email), through
`ProviderConnectQuestions`. The rules are the same for Gmail and Outlook.

**Why an alert and not a card on the screen.** A first build put two rows on the screen. They
were below the fold while the connect button stayed in the dock, so a person could connect
without seeing them, and the chooser starts the connect with no screen in between. An alert
cannot be missed, and it is the same kind of question as "Change your email?".

**Why import is the first answer.** A budget app with an empty Home on the first day does not
show its value, and this is what testers have today. All reading is on the iPhone, and the
person always answers, so neither answer is silent. Nothing is lost in either direction:
skipping can be undone later, and a disconnect can remove what an import brought in.

## How it works

`mailbox_state` gets one nullable column, `read_from_ms` (migration `mailbox_read_from`). It
stays on the device. No op is written, the server learns nothing, and no raw mail is kept.

- `read_from_ms` set means that the past was skipped. It is the floor of the normal listing:
  `since = max(watermark - overlap, floor)`. Without the floor, the 2-day overlap of the
  normal cycle would import the two days before the connect.
- `backfill_days` keeps the window that the scan would have used, for the later import.
- A new bank or sender on a skipped account starts at the floor, not 90 days back. After the
  later import, it gets the full window again.

## The cases

| Case | What happens |
| --- | --- |
| **Existing account, already linked** | Nothing changes. The column is null, nobody is asked, and a scan in progress goes on. |
| **Existing account, connects later** | It is asked, as a new account is. |
| **Reconnect** (sign in again, same address) | It is not asked, because no scan starts. The lane resumes from its watermark, and fills the gap since it stopped. A skip stays a skip. |
| **Sign in again with another address** | The screen has no question there, so the new mailbox follows the old: it skips if the old one skipped, else it scans. |
| **Disconnect, then connect** | The state is cleared, so it is asked again. **Only new email** then means from that moment: the time between is not read. |
| **Other provider** (a confirmed switch) | It is asked. The new mailbox is a first connect. |
| **Second iPhone, not connected** | Nothing. Its rows come from the op log. |
| **Second iPhone, takes the link over** | It is not asked. It reads only new email and catches up. Bank alerts offers the import. See below. |

**Why a takeover reads only new email.** It already has the "Read your email on this iPhone?"
alert. The choice is device-local, so the new iPhone
does not know what the old one chose. Only new email is right in both cases: if the old
iPhone imported, those rows arrive through the op log, and if it skipped, the person does
not get what they declined. It reads from the newest mail row minus the 2-day overlap, so
mail that arrived after the old iPhone stopped is not lost. It does this only when the
account has rows from that same mailbox (the grant id). Else it starts now.

## Importing later

Yes. **Profile › Bank alerts › the mailbox** shows **Import past email** while the lane is
active and the past is skipped. It needs no sign-in or step-up, because it uses the same
read-only grant. `MailboxEngine.importPastMail` clears the floor and records one pending
import per trusted sender in one commit, from `floor - backfill_days`. A cut run finishes on
a later cycle. Message accounting and op dedup prevent duplicates. The offer goes away after
one tap, and the import of a mailbox cannot be started twice.

An import cannot be turned into a skip: use **Disconnect** and remove its transactions.

## Other effects

- `firstScanFinished` is false while the past is skipped, so Finish setup does not say that
  no alerts were found when the person asked Hasala not to look.
- A person who moves from bank texts to email and picks **Only new email** does not get the
  mail of payments that no text brought in. The default import still fills them.

## Design

The alert is a system alert, so it needs no drawing, only the owner's approval of its words.
The **Past email isn't imported** card on `MailboxDetailPage` is new and has no Paper design.
It uses existing parts (the card and the tertiary pill). Paper is the source of truth, so the
owner has to draw it or accept this.
