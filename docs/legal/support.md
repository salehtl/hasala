---
title: "Help and Support"
description: "Answers for Hasala beta testers: connecting Gmail or Outlook, missing bank alerts, moving to a new iPhone, forgotten passwords, deleting your account and leaving the beta."
lastUpdated: 2026-10-21
status: "final"
plainWords: "Most problems are fixed by checking that your Gmail or Outlook is still connected and that your bank sends email alerts. To move to a new iPhone, sign in with Face ID, or use your 12 words. If you can't get in at all, your 12 words and a code we email you are the way back. You can delete your account in the app at any time."
---

This page is help for the beta, not a promise about how Hasala works. The app changes often, so a screen, a button or a step may not look exactly as described here.

## Common questions

### What is Hasala?

Hasala (حصّالة, "piggy bank") is a private budgeting app for iPhone in the UAE. It reads your bank alert emails from your Gmail or Outlook on your iPhone and turns them into transactions. It then helps you plan your month, track bills and see where your money goes. Its App Store name is "Hasala Budgeting", but it isn't on the App Store yet: the beta runs on TestFlight. On your home screen it's just "Hasala".

### How do I join the beta?

Hasala is invite-only for now. Ask for an invite at [hasala.app](/#invite), then tap **Confirm my email** in the email we send you. Invites go out in small batches. When yours is ready, we email you the steps: install TestFlight, accept Apple's TestFlight invitation from its email or the link in your invite, install Hasala, then open it and enter your invite code. Apple handles the TestFlight invitation, so it sees your email address and that you installed Hasala. TestFlight doesn't show testers to each other. New versions reach you in TestFlight after Apple's beta review, which usually takes about a day.

To leave the waitlist, open the **Leave the list** link in any email we sent you, then press the **Leave the list** button on the page that opens. Pressing it deletes your address straight away. Only opening the link does nothing.

### Which banks work?

At the time of writing, Hasala reads alerts from Dubai Islamic Bank (DIB), Emirates NBD and Abu Dhabi Islamic Bank (ADIB). If your bank isn't listed, tell us which one you use: on [hasala.app](/#banks), in the app during setup, or by email. We use those requests to decide which bank to add next.

### Does Hasala need my bank password?

No. Hasala never connects to your bank and never asks for your bank details. It reads the alert emails your bank already sends to your Gmail or Outlook, with read-only access.

### Can Hasala read my other emails?

Your iPhone asks your mailbox only for messages from your banks' alert addresses, so the rest of your inbox is never downloaded. Your iPhone checks each message before it uses it. If Hasala can't be confident that a message really came from your bank, for example because it's in Spam, Junk Email or an Outlook folder other than your Inbox, it waits in Review for you to check. How Hasala decides may change as we learn how each bank sends its mail. No email is ever sent to our server. Hasala can't send, delete or change your email. See [Gmail and Google user data](/privacy#gmail-and-google-user-data) and [Outlook and Microsoft account data](/privacy#outlook-and-microsoft-account-data) for the details.

### Can you see my transactions?

No. Your transactions, amounts, merchants, categories, budgets, bills and rules are encrypted on your iPhone before they leave it. Our server can't read them. Our server can see your email address and name and some account details, which our [Privacy Policy](/privacy#what-we-collect-and-why) lists in full.

### How does Hasala sort my spending?

On your iPhone, in this order: your own rules, then a built-in list of UAE merchants, then, only if you turn on Cloud suggestions, one merchant name sent to our suggestion service (see [Cloud suggestions](/privacy#cloud-suggestions)), and after that Apple's on-device model for merchant names written in Latin letters. With Cloud suggestions off, which is the default, the beta doesn't run Apple's model: anything your rules and the built-in list don't cover waits for your review. Suggestions, and Hasala's own sorting, can be wrong. Unless you also turn on Sort automatically, a suggestion doesn't file a transaction by itself. When you sort a transaction yourself, you can tell Hasala to always do the same for that merchant.

### Which email accounts work?

Gmail, and personal Microsoft accounts: outlook.com, hotmail.com and live.com addresses. Work and school Microsoft accounts (Microsoft 365 through an employer or a university) aren't supported. Hasala reads one mailbox at a time, so use the one your bank sends its alerts to.

### How do I connect Outlook?

During setup, at **Choose your email**, choose **Outlook**. Sign in with your Microsoft account and accept the permissions Microsoft shows you. Hasala asks only to read your mail, and keeps access without making you sign in each time. If you've already finished setup, go to **Profile › Bank alerts** and tap **Add a mailbox**.

Connecting Outlook replaces a Gmail connection, and connecting Gmail replaces an Outlook one. Hasala asks you to confirm first. Transactions it has already brought in stay.

If Hasala says your Microsoft account has no Outlook mailbox, the account uses an address from another provider and Microsoft doesn't hold mail for it. Connect the mailbox your bank sends alerts to instead.

### Why does Google say it hasn't verified Hasala?

During the beta, Google shows a warning when you connect Gmail, because its review of Hasala's Gmail access isn't complete. To continue, you can usually tap **Advanced** on that screen, then the link to go to Hasala. You can remove Hasala's access at any time.

### Does Hasala work with SMS alerts or email forwarding?

No. Hasala reads alerts from Gmail or Outlook only, and email forwarding isn't offered. If your bank sends only SMS alerts, check its app or online banking for an option to also send alerts by email.

### Is Hasala available in Arabic, or on Android?

Not yet. The beta is English only and iPhone only.

### How much does it cost?

Hasala is free during the beta.

### Does Hasala send notifications?

Not in the beta yet. Hasala doesn't put notifications on your Lock Screen, and there is no notification setting in Profile. The bell on Home lists, inside the app, what needs a look. When Lock Screen notifications arrive, we plan for them to be generic by default, without amounts or merchants unless you choose that.

### Where is Hasala's source code?

At [github.com/salehtl/hasala](https://github.com/salehtl/hasala). It's source-available under the Functional Source License (FSL-1.1-ALv2): you can read, run and change it, but not use it in a commercial product or service that competes with Hasala. Each version becomes available under the Apache License 2.0 two years after it's released. The name Hasala and the Slot mark are trademarks and aren't covered by the licence. See [LICENSE.md](https://github.com/salehtl/hasala/blob/main/LICENSE.md) for the exact terms.

## Missing transactions or alerts

If transactions aren't showing up, work through these checks in order.

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
4. Connect your email again on this iPhone. During setup, at **Choose your email**, or later in **Profile › Bank alerts** with **Add a mailbox**, choose Gmail or Outlook and sign in. If your old iPhone is still reading your mailbox, Hasala asks **Read your email on this iPhone?** Tap **Read it here**. The old iPhone then stops reading, and your past transactions stay.
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
