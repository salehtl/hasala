# Outlook trust checks: the owner's runbook (WP0)

This runbook runs checks C1–C7 of [outlook-mailbox.md](outlook-mailbox.md#trust-needs-real-bank-alerts-plus-synthetic-spoof-probes)
on real mail. Their results decide whether `OutlookProvider.outlookTrustProven` can become
true. Until then, every Outlook message goes to review.

You do every step on your own Mac and phone. The real `.eml` files stay in
`~/hasala-private/`. They never go into this repository, an issue, a pull request or a
chat. The tools print one redacted line per message: no subject, body, amount, address
local part, message id or date. Paste back only that output.

## 0. Set up the folders

```sh
mkdir -p ~/hasala-private/outlook-trust/{genuine/junk,genuine/forwarded,copied,spoof}
chmod -R go-rwx ~/hasala-private
```

| Folder | What goes in it | Checker mode |
|---|---|---|
| `genuine/` | alerts the bank sent straight to the Outlook test address | `--expect pass` |
| `genuine/junk/` | a genuine alert that was in Junk Email | read with `genuine/` (C5) |
| `genuine/forwarded/` | a genuine alert that Gmail forwarded automatically | read with `genuine/` (C5) |
| `copied/` | alerts you copied or forwarded by hand into the mailbox | `--expect untrusted` |
| `spoof/` | the C3 spoof probe | `--expect untrusted` |

The checker refuses a folder inside a Hasala checkout.

## 1. Get genuinely inbound alerts

A genuine alert must come from the bank's servers to Outlook.com. A message you forward or
copy by hand does not count: it goes to `copied/`, and it should show `no_eop` or another
reason that is not `pass`.

Use one or both ways:

1. **Change the bank's alert address for a short time.** In the bank's online banking, set
   the alert email to the Outlook test address. Wait for an alert that comes anyway (a
   sign-in notice, a statement notice, or a purchase you were making anyway). Then set the
   alert email back to your usual address. Do this for each bank you want to cover.
2. **Auto-forward from Gmail.** In Gmail, open Settings › See all settings › Forwarding and
   POP/IMAP › Add a forwarding address, and enter the Outlook test address. Gmail sends a
   confirmation code to Outlook. Confirm it. Then make a filter (Settings › Filters and
   blocked addresses › Create a new filter) with `From` set to the bank's sender domain(s),
   and the action "Forward it to" the Outlook address. Gmail forwards only new mail. Remove
   the filter and the forwarding address when you have enough alerts. These alerts are the
   C5 forwarded case: put at least one in `genuine/forwarded/`. If you use only this way,
   all alerts are forwarded ones. Then also get at least one alert by way 1 for C1/C2.

Collect at least three genuine alerts, from every bank you can, and note which banks send
through Microsoft 365 if you know (C7).

**Junk (C5).** If an alert lands in Junk Email by itself, keep it: that is the best case.
If none does, move one genuine alert to Junk Email by hand and say so when you paste back.
The `scl=` value in its line shows which case it is (5 or more: filtered by Outlook).

## 2. Export the messages as .eml

In Outlook on the web (outlook.live.com), for each message:

1. Open the message.
2. Select **More actions** (`…`) › **Save as** (in some versions: **Download**). The browser
   saves an `.eml` file.
3. Move the file into the right folder. Give it a plain name such as `01.eml`. The checker
   does not print file names, but a subject in a file name is easy to leak elsewhere.

The checks in outlook-mailbox.md also ask for the Graph `$value` form of the message. The
Debug app's header order check (step 5) reads `$value` and prints the same redacted line,
so you can compare the two exports line by line.

## 3. Run the checker on the exports

From a checkout of this repository on the Mac (it builds HasalaCore's `CoreMail`, the same
verdict code the app ships):

```sh
scripts/outlook-trust-check.sh --expect pass --domains <bank domains, comma-separated> ~/hasala-private/outlook-trust/genuine
scripts/outlook-trust-check.sh --expect untrusted ~/hasala-private/outlook-trust/copied
```

`--domains` is optional. With it, C6 also requires each verified domain to be one of the
bank domains or a subdomain of one.

Each message gives one line, for example (synthetic):

```text
#01 from=bank.example from_fields=1 ar=1 forms=ms ms_index=0 topmost=yes authas=1[anonymous]@below authsource=1[am0pr01mb0001.eurprd01.prod.outlook.com]@below rcv0=above order=rcv0>ar:ms>as>src dmarc=pass compauth=pass reason=100 header_from=bank.example scl=- c7=none verdict=pass domain=bank.example
```

| Field | Meaning |
|---|---|
| `#01`, `[junk]`, `[forwarded]` | file index in name order, and its subfolder |
| `from` | the `From` domain only (`none` or `invalid` if there is none) |
| `ar`, `forms`, `ms_index`, `topmost` | the number of `Authentication-Results` fields, the form of each in order (`ms` Microsoft form, `id` authserv-id form), the index of the first Microsoft-form one, and whether it is the topmost A-R |
| `authas`, `authsource` | count, values and position (above/below the Microsoft-form A-R) of `X-MS-Exchange-Organization-AuthAs` and `-AuthSource`; an AuthSource that does not end in `.prod.outlook.com` prints as `other` |
| `rcv0`, `order` | position of the newest `Received`, and the order of the newest `Received` (`rcv0`), the A-Rs (`ar:ms`, `ar:id`), AuthAs (`as`) and AuthSource (`src`) |
| `dmarc`, `compauth`, `reason`, `header_from` | from the first Microsoft-form A-R |
| `scl` | `X-MS-Exchange-Organization-SCL` (spam confidence level) |
| `c7` | a second Microsoft-form A-R: `none`, `from-domain` (it names the `From` domain, as a bank tenant's would) or `other` |
| `verdict`, `domain` | `AuthResults.outlookVerdict` and the verified domain |

The summary maps the folder to the checks, each `PASS`, `FAIL` or `NEEDS-DATA`, with the
expectation from outlook-mailbox.md. With `--expect pass`: C1, C2, C5, C6 and C7. With
`--expect untrusted`: C3 and the untrusted half of C6. The exit status is 1 when a check
fails.

## 4. Send the C3 spoof probe

You need an SMTP account that can send as a domain you own, and `swaks`
(`nix shell nixpkgs#swaks` or `brew install swaks`). The script only prints the command:

```sh
scripts/outlook-spoof-probe.sh --server smtp.<your provider>:587 --auth-user <your SMTP login> \
  --from-domain <a domain you own> --to <the Outlook test address>
```

Read the printed command, then run it yourself. swaks asks for the SMTP password. The
message is from `hasala-probe@<your domain>`. Its subject and body say that it is a
synthetic test and not a bank alert. It adds exactly the headers that C3 lists: a forged
Microsoft-form A-R for `bank.example`, a forged `mx.google.com` A-R, and forged
`X-MS-Exchange-Organization-AuthAs: Internal` and `-AuthSource: relay.evil.example`.

Find the probe in the test mailbox (look in Junk Email too). Export it as in step 2 into
`spoof/`, then:

```sh
scripts/outlook-trust-check.sh --expect untrusted ~/hasala-private/outlook-trust/spoof
```

C3 passes when no probe is `pass`. The line also shows which forged headers survived:
`forms=` shows the A-Rs that are left, and `authas=` / `authsource=` show `internal` /
`other` when the forged ones were kept. If a probe is `pass`, the C3 line names the
verified domain: if that is your own domain and `forms=ms` (one A-R), Outlook removed every
forged header and authenticated your domain. Record that in the results. The rule then
needs a decision, so do not turn the gate on.

Delete the probe from the mailbox when it is exported.

## 5. Run the header order check (C4) in the Debug app

1. Run a **Debug** build of Hasala on your iPhone from Xcode. A TestFlight or Release build
   does not have this tool.
2. Connect the Outlook test mailbox (Profile › Bank alerts › Microsoft) and choose the
   banks, so that the trusted senders are set.
3. Open Profile › Bank alerts › the Outlook mailbox › **Header order check (Debug)**.
4. Choose how many messages to read (1 to 20 alerts from the trusted senders of the last
   90 days, in the order Graph lists them), then **Run**. For each message the tool reads `$value` and `internetMessageHeaders`, and
   prints the same redacted line as the checker, plus `order_match` (the order of the
   newest `Received`, the A-Rs, AuthAs and AuthSource is the same in both) and `rcv0`
   (`same` when both have the same newest `Received`).
5. **Share report** sends only the report text through the share sheet (for example to
   Notes on your Mac). It never contains the messages.

For one or two of the same alerts, also open Outlook on the web › `…` › View › **View
message source**, and check by eye that the newest `Received` is on top and the A-R,
AuthAs and AuthSource are in the order the line shows. Write down only "same" or
"differs".

## 6. What to paste back

Paste into the conversation (or straight into the "Results (WP0)" section of
outlook-mailbox.md):

1. The full output of each checker run: `genuine`, `copied` and `spoof`.
2. The C4 report text from the Debug app, and "same" or "differs" for View message source.
3. Which banks the genuine alerts came from (domains only), which way each arrived (alert
   address change or Gmail filter), and whether the Junk alert was filtered by Outlook or
   moved by hand.
4. Anything the tools could not read (`unreadable` lines), with the reason if you know it.

Do not paste a message, a header block, a subject, an address, an amount or a date.

## 7. The .eml files afterwards

Keep them in `~/hasala-private/` or delete them. If they should become test fixtures, they
may go **only** into the private repository `salehtl/hasala-fixtures`, never into this one.
Follow CLAUDE.md "Secrets and real mail":

1. Add them to your checkout of `salehtl/hasala-fixtures` at the path the test that reads
   them expects, and commit there.
2. In this repository, run `scripts/private-fixtures-lock.sh write` with
   `HASALA_PRIVATE_FIXTURES` set to that checkout, and commit `private-fixtures.lock`.
3. Run `scripts/check.sh` with `HASALA_PRIVATE_FIXTURES` set, and check that the new tests
   ran and did not skip.

The spoof probe is synthetic, but it carries your domain and test address. Treat it like
the real ones.
