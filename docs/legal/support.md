---
title: "Help and Support"
description: "Answers for Hasala beta testers: connecting Gmail or Outlook, setting up bank texts, missing bank alerts, moving to a new iPhone, forgotten passwords, deleting your account and leaving the beta."
lastUpdated: 2026-10-29
status: "final"
plainWords: "Most problems are fixed by checking that your Gmail or Outlook is still connected and that your bank sends email alerts, or, if you use bank texts, that your automation in Shortcuts is still there. To move to a new iPhone, sign in with Face ID, or use your 12 words. If you can't get in at all, your 12 words and a code we email you are the way back. You can delete your account in the app at any time."
---

Hasala is an experimental beta: features change often, things can break, and data can be lost or reset (see [An experimental beta](/terms#an-experimental-beta)). This page is help for the beta, not a promise about how Hasala works. A screen, a button or a step may not look exactly as described here.

## Common questions

### What is Hasala?

Hasala (حصّالة, "piggy bank") is a private budgeting app for iPhone in the UAE. It reads your bank alert emails from your Gmail or Outlook, or your bank's texts, on your iPhone and turns them into transactions. It then helps you plan your month, track bills and see where your money goes. Its App Store name is "Hasala Budgeting", but it isn't on the App Store yet: the beta runs on TestFlight. On your home screen it's just "Hasala".

### How do I join the beta?

Hasala is invite-only for now. Ask for an invite at [hasala.app](/#invite), then tap **Confirm my email** in the email we send you. Invites go out in small batches. When yours is ready, we email you the steps: install TestFlight, accept Apple's TestFlight invitation from its email or the link in your invite, install Hasala, then open it and enter your invite code. Apple handles the TestFlight invitation, so it sees your email address and that you installed Hasala. TestFlight doesn't show testers to each other. New versions reach you in TestFlight after Apple's beta review, which usually takes about a day.

To leave the waitlist, open the **Leave the list** link in any email we sent you, then press the **Leave the list** button on the page that opens. Pressing it deletes your address straight away. Only opening the link does nothing. If your mail app shows an **Unsubscribe** button on one of these emails, pressing it does the same.

### Which banks work?

At the time of writing, Hasala reads alert emails from Dubai Islamic Bank (DIB), Emirates NBD and Abu Dhabi Islamic Bank (ADIB), and bank texts from DIB and Emirates NBD. Payment texts from other banks wait for you in **Review**, where you can check the details. If your bank isn't listed, tell us which one you use: on [hasala.app](/#banks), in the app during setup, or by email. We use those requests to decide which bank to add next.

### Does Hasala need my bank password?

No. Hasala never connects to your bank and never asks for your bank details. It reads the alert emails your bank already sends to your Gmail or Outlook, with read-only access, or the texts your bank already sends to your iPhone.

### Can Hasala read my other emails?

Your iPhone asks your mailbox only for messages from your banks' alert addresses, so the rest of your inbox is never downloaded. Your iPhone checks each message before it uses it. If Hasala can't be confident that a message really came from your bank, for example because it's in Spam, Junk Email or an Outlook folder other than your Inbox, it waits in Review for you to check. How Hasala decides may change as we learn how each bank sends its mail. No email is ever sent to our server. Hasala can't send, delete or change your email. See [Gmail and Google user data](/privacy#gmail-and-google-user-data) and [Outlook and Microsoft account data](/privacy#outlook-and-microsoft-account-data) for the details.

### Can you see my transactions?

No. Your transactions, amounts, merchants, categories, budgets, bills and rules are encrypted on your iPhone before they leave it. Our server can't read them. Our server can see your email address and name and some account details, which our [Privacy Policy](/privacy#what-we-collect-and-why) lists in full.

### How does Hasala sort my spending?

On your iPhone, in this order:

1. your own rules;
2. a built-in list of UAE merchants;
3. the category you last picked yourself for that merchant's payments, as a suggestion (refunds have their own pick, and a payment you split isn't a pick);
4. only if you turn on Cloud suggestions, and only for a merchant you haven't sorted yourself: one merchant name sent to our suggestion service (see [Cloud suggestions](/privacy#cloud-suggestions)), and, when Cloudflare can't help, Apple's on-device model for merchant names written in Latin letters.

With Cloud suggestions off, which is the default, the beta doesn't run Apple's model to sort: anything your rules and the built-in list don't cover waits for you in **Review**. Suggestions, and Hasala's own sorting, can be wrong. Unless you also turn on **Sort automatically**, a suggestion doesn't file a payment by itself.

### How do I sort a payment in Review?

Open **Review** and tap **Start**. Each card is one payment.

- If the card has a suggestion, tap **Use** to take it.
- Otherwise, swipe the card, or tap one of the pills under it, to choose Need, Want, Save or Transfer. Then tap a category in the list. That sorts the card.
- Tap **Skip for now** to leave a payment for later.

After you sort a card, the next card is often another payment from the same merchant, so you can sort them one after another.

### Why does a card say "Your last pick"?

You sorted another payment from that merchant yourself, so Hasala suggests the category you picked most recently. Tap **Use** to take it, or pick another. It's only a suggestion: the payment waits in Review until you choose. Hasala doesn't send a merchant you've sorted yourself to Cloudflare.

### What does "Always use it" do?

It makes Hasala sort a merchant for you. Turn on **Always use it for** the merchant in the category list, then tap the category. Hasala then:

- sorts this payment;
- makes a rule for that merchant, so its new payments are sorted when they arrive; and
- re-files the merchant's other payments, in every month, except the ones you sorted yourself. It leaves a few alone, such as split payments and transfers.

A line at the bottom of the screen says how many payments it changed, with **Undo**. Undo puts every payment back and removes the rule. For a week, **Sorted for you** on Home lists what the rule filed, with **Undo all** and **Stop this rule**. You can also pause a rule in **Profile › Categories and rules**, which sends its payments back to Review. You'll find the same switch in Activity and on a transaction's own page. It's off unless you turn it on.

An earlier build had a **Not this** button. If you used it, Hasala still remembers what you told it.

### Can I add a category while I sort?

Yes. In the list for Need, Want or Save, tap **New category** at the end, type a name and tap **Save**. Hasala makes the category and sorts the card into it. The new category counts as the kind you swiped. You can have up to 20 categories of your own. Their names are sealed like the rest of your data, and they're never sent to Cloudflare.

### Does Hasala sort in the background with Cloudflare AI?

Only if you turn on **Merchant suggestions**, in **Profile › Cloud suggestions**, or with **Turn on** when Review asks you. Then Hasala asks Cloudflare's AI about the merchants waiting in Review by itself, one name per request, within a daily limit on each iPhone. It asks only while Hasala is open on screen. When you leave the app, no new request starts, though requests already sent can finish, and no request starts when iOS wakes Hasala in the background, for example to sync. It shows no card or count while it works. With **Sort automatically** on too, it files a payment only when the answer is very sure, and those payments are marked "Sorted by Cloudflare AI".

To turn it off, switch off **Merchant suggestions** in **Profile › Cloud suggestions**. It stops at once. **Send Cloudflare's sorting back to Review**, in the same place, puts the payments it filed on that iPhone back in Review. The switches are set on each iPhone.

### Something changed, or my data looks different. Why?

Hasala is an experimental beta, so a new build can change how payments are sorted or shown. Now and then we may also need to reset the beta, and then data can be lost. Where we can, we tell you in the app or by email first. To keep a copy of your own, export your data from time to time, from **Profile › Settings › Export your data (CSV)**. If something looks wrong, tell us (see [Contact us](#contact-us)).

### Which email accounts work?

Gmail, and personal Microsoft accounts: outlook.com, hotmail.com and live.com addresses. Work and school Microsoft accounts (Microsoft 365 through an employer or a university) aren't supported. Hasala reads one mailbox at a time, so use the one your bank sends its alerts to.

### How do I connect Outlook?

During setup, at **Choose your email**, choose **Outlook**. Sign in with your Microsoft account and accept the permissions Microsoft shows you. Hasala asks only to read your mail, and keeps access without making you sign in each time. If you've already finished setup, go to **Profile › Bank alerts** and tap **Add a mailbox**.

Connecting Outlook replaces a Gmail connection, and connecting Gmail replaces an Outlook one. Hasala asks you to confirm first. Transactions it has already brought in stay.

If Hasala says your Microsoft account has no Outlook mailbox, the account uses an address from another provider and Microsoft doesn't hold mail for it. Connect the mailbox your bank sends alerts to instead.

### Why does Google say it hasn't verified Hasala?

During the beta, Google shows a warning when you connect Gmail, because its review of Hasala's Gmail access isn't complete. To continue, you can usually tap **Advanced** on that screen, then the link to go to Hasala. You can remove Hasala's access at any time.

### Does Hasala work with SMS alerts or email forwarding?

SMS alerts, yes: see [Bank texts](#bank-texts). Email forwarding isn't offered.

### Is Hasala available in Arabic, or on Android?

Not yet. The beta is English only and iPhone only.

### How much does it cost?

Hasala is free during the beta.

### Does Hasala send notifications?

Not in the beta yet. Hasala doesn't put notifications on your Lock Screen, and there is no notification setting in Profile. The bell on Home lists, inside the app, what needs a look. When Lock Screen notifications arrive, we plan for them to be generic by default, without amounts or merchants unless you choose that.

### Where is Hasala's source code?

At [github.com/salehtl/hasala](https://github.com/salehtl/hasala). It's source-available under the Functional Source License (FSL-1.1-ALv2): you can read, run and change it, but not use it in a commercial product or service that competes with Hasala. Each version becomes available under the Apache License 2.0 two years after it's released. The name Hasala and the Slot mark are trademarks and aren't covered by the licence. See [LICENSE.md](https://github.com/salehtl/hasala/blob/main/LICENSE.md) for the exact terms.

## Bank texts

Instead of connecting an email account, Hasala can read the texts (SMS) your bank sends to your iPhone. Your account uses one or the other, on all your iPhones: bank email or bank texts. Texts are read on your iPhone and never sent to our server or anyone else (see [Bank texts](/privacy#bank-texts) in our Privacy Policy).

### How do I set up bank texts?

During setup, at **How do your banks reach you?**, choose texts, then pick your banks. If you've already finished setup, or skipped this part, go to **Profile › Bank alerts**. Hasala then guides you through one automation in Apple's **Shortcuts** app. Hasala can't make it for you. In Shortcuts:

1. Tap **Automation** at the bottom, then **+**, then choose **Message**.
2. Leave **Sender** empty. Tap **Message Contains** and type just a full stop (**.**), so it runs for every text that has one. Choose **Run Immediately**, then tap **Next**.
3. Tap **New Blank Automation**, then **Add Action**.
4. Search for **Hasala** and choose **Add bank text**. Check that it shows **Message** in blue (if it doesn't, tap the blue word and choose **Message**), then tap **Done**. If Hasala's action isn't in the list, open Hasala once, then search again.

Back in Hasala, tap **I made it, send a test**, then, within 10 minutes, send a text that says "Hasala test." to your own number in Messages, with the full stop, so that the automation runs for it. Hasala tells you when it arrives, and doesn't keep the text. You can also tap **Skip, confirm with my next bank text**, and Hasala confirms the automation with your next bank text. The steps and the test stay in **Profile › Bank alerts** (**Show me how** and **Test it again**) if you want them later. **Show me how** shows the same steps with a sketch of the Shortcuts app.

The automation only sees texts that arrive after you make it. To bring in an older bank text, paste it (see below).

### Why does the automation look for a full stop?

Shortcuts runs a message automation only for a sender you choose or for texts that contain a phrase you type. Bank senders aren't contacts, and bank texts often don't share a word, so a word like "AED" would miss payments without any sign. But bank payment texts usually have a full stop in their amount (for example 12.50), and all of DIB's do, so the automation runs for every text that contains a full stop and hands it to Hasala. A text with no full stop at all, such as a short reply from a friend, never reaches Hasala. If a bank text has none, for example an amount with no decimals, paste it (see below). Hasala looks at each text it gets on your iPhone. It keeps only texts that look like payments. Every other text, such as a one-time code, a declined payment, a promotion or a chat with a person, is dropped at once and never stored. A message that looks like a payment, even one from a person, waits in **Review**, where you can archive it. Archiving hides it; it stays in your Hasala data until you delete your account.

### Why does a bank text wait in Review?

A text's sender name can be faked. So a bank text adds a payment by itself only when Hasala's rules for that bank read it, it came from the bank's sender name, and it's for a card you've already confirmed as yours in Hasala. Hasala knows the sender only if Shortcuts passes it to Hasala's action. The steps above don't set this up, and we haven't yet checked whether Shortcuts does it by itself. If it doesn't, every bank text waits in Review. The first payment on each card waits in **Review**; once you confirm it (pick its category, or mark it as a transfer or a refund), Hasala knows the card is yours, and later payments on that card can add themselves, if Shortcuts passes the sender. If you undo that, Hasala forgets the card again. A card you've marked as not yours never adds a payment by itself. Payments with no card in the text always wait in Review: most salaries, refunds and transfers, and DIB debit-card purchases, whose texts don't name the card. So do payment texts from other banks and texts iOS didn't give a sender for. If something in Review isn't a payment of yours, archive it there. Hasala can't delete a single transaction: an archived one is hidden but stays in your Hasala data, and you can restore it, until you delete your account. If Hasala couldn't read the amount in a bank text, Review tells you so: find that text in Messages and paste it, and Hasala offers to replace the unread payment with it.

### How do I paste a bank text?

In Messages, touch and hold the bank's text and tap **Copy**. In Hasala, tap **Paste a bank text** in **Review** or in **Profile › Bank alerts**. A pasted text always waits in Review for you to check. If Hasala already has a payment that may be the same one, from a text or an email (same bank, or no bank on one of them, same amount, currency and direction, the same card or no card on one of them, and within a day of the text's date, or within the last 7 days if the text has no date), Hasala shows you that payment and asks before adding the text again. Pasting is offered only while your account uses bank texts; if it reads bank email, switch first (see below). An iPhone that hasn't yet heard from our server which one your account uses, for example right after you install Hasala, offers paste too, and a text pasted then waits in Review.

### How do I stop bank texts?

Open the **Shortcuts** app, tap **Automation**, then swipe left on the Hasala automation and tap **Delete**. Hasala then gets no more texts. Transactions it has already brought in stay.

### How do I switch between bank texts and email?

Go to **Profile › Bank alerts** and switch the source. Hasala asks you to confirm first. Transactions it has already brought in stay.

- **From texts to email:** tap **Use bank email instead**, then **Connect email**, and connect Gmail or Outlook. Hasala brings in your bank emails as for any new mailbox, older ones included, so that a payment no text brought in isn't lost. An email that may be the same payment as one a text already brought in waits in **Review** beside that payment, so that you can archive the copy or keep both. Hasala treats them as possibly the same when they are within a day (24 hours) of each other, in the same direction, from the same bank (or the text names no bank), for the same card or with no card on one of them, and for the same amount or in two different currencies. A bank text whose amount Hasala couldn't read can match any email of that bank and card in that day. If the email and the text differ more than that, for example by a fee, the payment can still show twice; archive one. From then on, Hasala adds nothing from texts the automation hands it on any of your iPhones, so delete the automation in Shortcuts on each of them (see above). Until you do, **Profile › Bank alerts** shows how many texts that look like payments it ignored. If another iPhone of yours brought in a bank text before it heard about the switch, the payment may show twice; archive one.
- **From email to texts:** tap **Use bank texts instead**. Hasala disconnects your mailbox and reads texts from then on, then shows you how to make the automation as above. Do this on the iPhone that reads your email; on another iPhone, Hasala asks you to disconnect the mailbox on the iPhone that reads it first (or to remove Hasala in your Google or Microsoft account's permissions), then switch.
- **If you disconnect your email** in **Profile › Bank alerts** and connect none, your account uses bank texts again, and Hasala adds texts that your automation hands it, if it is still there. If this iPhone has seen the automation run, Hasala tells you so when you disconnect. If you connect an email account again later, Hasala checks the emails against the payments your texts brought in, as in a switch from texts to email.

### Bank texts not showing up?

1. In **Profile › Bank alerts**, check when the automation last ran.
2. In Shortcuts, check that the automation is still there, that **Message Contains** is a full stop (**.**) with no sender, that **Run Immediately** is on, and that its action is Hasala's **Add bank text**.
3. If the bank's text has no full stop, the automation doesn't run for it. Paste it in **Review**.
4. If your iPhone restarted, Hasala can't store anything from a text until you unlock it for the first time. The next time you open Hasala after you unlock, it tells you how many texts that look like payments arrived while it couldn't store them. If iOS doesn't say who sent a text, a person's text that looks like a payment can be counted too. The texts stay in Messages, so paste the bank's ones.
5. Look in **Review**. Only DIB and Emirates NBD texts are read fully at the time of writing. Payment texts from other banks, and the first payment on each card, wait there (see [Why does a bank text wait in Review?](#why-does-a-bank-text-wait-in-review)).
6. If you're still stuck, email us (see [Contact us](#contact-us)). Tell us which bank it is and what **Profile › Bank alerts** says. Please don't send the text itself or a screenshot of it.

## Missing transactions or alerts

If transactions from bank email aren't showing up, work through these checks in order. For bank texts, see [Bank texts not showing up?](#bank-texts-not-showing-up).

### 1. Check that your email is still connected

Open **Profile › Bank alerts**. (**Profile › Settings › Mailboxes** opens the same page.)

- If it says **Sign in again** and your mailbox is Gmail, tap it and sign in again. Google access can end if you change your Google password, remove Hasala in your Google Account, or untick the Gmail permission on Google's screen.
- If it says **Sign in again** and your mailbox is Outlook, tap it and sign in with your Microsoft account again. Microsoft access can end if you remove Hasala at [account.live.com/consent/Manage](https://account.live.com/consent/Manage), and sometimes after you change your Microsoft password or don't use Hasala for a long time.
- If it says **Read on your other iPhone**, a different iPhone is reading your alerts. Only one iPhone reads your email at a time, and this iPhone shows no button to take the reading back. The iPhone that last connected the mailbox is the one that reads it.
- If it shows an error, tap **Try again**. If the error keeps coming back, contact us and say what the page shows (see step 6).

### 2. Check that your bank sends email alerts

Hasala can only see alerts your bank emails to you. In your bank's app or online banking:

- turn on **email** alerts for card purchases, transfers and account activity, not only SMS; and
- make sure the alerts go to the **same email address** you connected to Hasala.

Open Gmail or Outlook and confirm the alerts are arriving there, directly from your bank. Hasala looks for them across your mailbox, archived mail included, but not in Gmail's Trash or Outlook's Deleted Items. Alerts it can't be confident about, for example ones in Spam, Junk Email or an Outlook folder other than your Inbox, go to **Review** for you to check. Alerts forwarded from another email address may not be found, and any that are go to **Review** too.

### 3. Check your bank is supported

At the time of writing, Hasala reads alerts from DIB, Emirates NBD and ADIB. Alerts from other banks are not read yet. If your bank changed the address its alerts come from, tell us so we can update Hasala.

### 4. Let Hasala run in the background

Hasala checks for new alerts in the background, but iOS decides when. To help it:

- turn on **Settings › General › Background App Refresh**, both overall and for Hasala;
- don't force-quit Hasala from the app switcher; and
- note that Low Power Mode can delay background checks.

Opening Hasala usually checks for new alerts straight away.

### 5. Look in Review

Hasala is built not to drop an alert it couldn't read fully. Such an alert goes to **Review**, where you can fill in the missing details.

### 6. Still missing?

If Hasala notices a bank has gone quiet, **Profile › Bank alerts** says "Bank alerts went quiet". If you're still stuck, email us. Tell us the app version (at the bottom of Profile), your iOS version and iPhone model, which bank and mailbox (Gmail or Outlook) it is, and what the Bank alerts page says. Please don't include amounts, merchants, account numbers or screenshots that show them.

## Moving to a new iPhone

Your sealed data is kept on our server, so you can move to a new iPhone without losing it. Hasala's local database is not included in iCloud or computer backups. Your new iPhone downloads your data again and unlocks it.

### If you use Face ID (a passkey)

1. Sign in to the same Apple Account on your new iPhone, with iCloud Keychain (Passwords) turned on.
2. Install Hasala from TestFlight and open it.
3. Sign in with Face ID. Your passkey unlocks your data.
4. Connect your email again on this iPhone, or, if you use bank texts, make the automation again in Shortcuts on this iPhone (see [Bank texts](#bank-texts)). For email: during setup, at **Choose your email**, or later in **Profile › Bank alerts** with **Add a mailbox**, choose Gmail or Outlook and sign in. If your old iPhone is still reading your mailbox, Hasala asks **Read your email on this iPhone?** Tap **Read it here**. The old iPhone then stops reading, and your past transactions stay.
5. Your old iPhone stays on your list of devices. The beta app can't remove devices yet. If you lose or sell it, email us.

Some passkey managers other than iCloud Keychain can't unlock Hasala on a new device. If yours can't, Hasala asks for your 12-word recovery phrase instead.

### If you sign in with email and password

Sign in, then enter your 12-word recovery phrase when Hasala asks. A password signs you in but doesn't unlock your data.

### If you've lost every passkey

On the sign-in screen, choose **Can't get in at all?** and use your 12-word recovery phrase with a code we email you. Hasala makes a new passkey on this iPhone, and we email you that your recovery phrase was used.

### Restoring from an iPhone backup

Restoring a backup doesn't restore Hasala's data directly. Open Hasala and it downloads and unlocks your data again. Changes you made just before the backup that hadn't synced yet may be lost.

## Forgot your password

Password reset is not in the beta. If you can't sign in, choose **Can't get in at all?** on the sign-in screen. Use your 12-word recovery phrase with a code we email you, and Hasala makes a new passkey on that iPhone.

If you have a passkey, you don't need your password: sign in with Face ID.

If you have none of these (no recovery phrase and no passkey), we can't reset your password or recover your data. This isn't a policy choice. We don't hold the keys to your data.

### Lost your recovery phrase?

If you sign in with a passkey, you can view your 12 words again in **Profile › Sign-in & security › Recovery phrase › View recovery phrase**, after Face ID. We email you each time they're shown. Accounts that sign in with a password only can't show them again.

Replacing your recovery phrase is not in the beta app yet. If you think someone has seen your words, a new phrase wouldn't undo that anyway; see our [Security](/security) page. We can't reset your recovery phrase, or show it to you outside the app.

Hasala will never ask for your recovery phrase, your password or a code in an email, a notification, a phone call or on a website. Only type them into the Hasala app.

## Delete your account

Deleting your account is permanent and can't be undone. If you want to keep your data, export it first from **Profile › Settings › Export your data (CSV)**.

1. Open Hasala and go to **Profile › Delete your account**.
2. Read the summary and confirm it's you.
3. Our server erases your account, sealed data, keys, sign-in methods and devices straight away.
4. Hasala erases its data on this iPhone and disconnects your email. Your other iPhones erase theirs the next time they connect.

Afterwards:

- Encrypted backups that still contain your data expire within 30 days.
- Your passkey stays in your passkey manager. To remove it, open the **Passwords** app, find Hasala and delete it.
- You can check that Hasala no longer has Gmail access in your Google Account's security settings (at the time of writing, under **Security › Your connections to third-party apps and services**).
- If you connected Outlook, remove Hasala's permission at [account.live.com/consent/Manage](https://account.live.com/consent/Manage). At the time of writing, Microsoft doesn't let an app remove its own permission, so Hasala can't do this for you.
- If you used bank texts, delete the automation in the **Shortcuts** app.
- Delete the Hasala app.

If you can't open the app any more and want your account deleted, email privacy@hasala.app from your account's email address. We'll reply to that address and ask you to confirm before we delete anything.

## Leave the beta

1. If you won't be coming back, **delete your account** first (see above). Deleting the app alone doesn't delete your account.
2. In the **TestFlight** app, open Hasala and tap **Stop Testing**.
3. Delete the Hasala app from your iPhone.

## Other things you can do

- **Sign out.** You'll need your passkey or password to sign back in. Your data stays on this iPhone.
- **Sign out everywhere.** This ends every session on every device. Your devices keep their data, and you can sign in again.

## Contact us

- Help and feedback: support@hasala.app. You can also send feedback, with screenshots, from the TestFlight app. Check screenshots before you send them, because they may show your amounts.
- Privacy questions and requests: privacy@hasala.app
- Security problems: security@hasala.app. See our [Security](/security) page.

Hasala is a small, independent project. We answer as soon as we can, but replies can take a few days, and support during the beta is best effort.

Please never send us your recovery phrase or your password. We'll never ask for them. If we ask for a sample bank alert to add support for your bank, remove your card and account numbers before you send it.
