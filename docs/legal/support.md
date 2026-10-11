---
title: "Help and Support"
description: "Answers for Hasala beta testers: missing bank alerts, moving to a new iPhone, forgotten passwords, deleting your account and leaving the beta."
lastUpdated: 2026-10-11
status: "draft"
draftNote: "Draft pending owner review. Menu paths must be checked against the shipped build. Do not publish until every [[OWNER]] marker is resolved."
plainWords: "Most problems are fixed by checking that Gmail is still connected and that your bank sends email alerts. To move to a new iPhone, sign in with Face ID, or use your 12 words. A forgotten password needs your 12 words or an iPhone that's still signed in. You can delete your account in the app at any time."
---

## Common questions

[[OWNER: Check every menu path on this page (for example Profile › Bank alerts) against the shipped build.]]

### What is Hasala?

Hasala (حصّالة, "piggy bank") is a private budgeting app for iPhone in the UAE. It reads your bank alert emails from Gmail on your iPhone and turns them into transactions. It then helps you plan your month, track bills and see where your money goes. Its App Store name is "Hasala Budgeting", but it isn't on the App Store yet: the beta runs on TestFlight. On your home screen it's just "Hasala".

### How do I join the beta?

Hasala is invite-only for now. Ask for an invite at [hasala.app](/#invite), then tap **Confirm my email** in the email we send you. Invites go out in small batches. When yours is ready, we email you the steps: install TestFlight, accept Apple's TestFlight invitation from its email or the link in your invite, install Hasala, then open it and enter your invite code. Apple handles the TestFlight invitation, so it sees your email address and that you installed Hasala. Other testers never see you. New versions reach you in TestFlight after Apple's beta review, which usually takes about a day.

To leave the waitlist, use **Leave the list** in any email we sent you. It deletes your address straight away.

### Which banks work?

At launch, Hasala reads alerts from Dubai Islamic Bank (DIB) and Emirates NBD. If your bank isn't listed, tell us which one you use: on [hasala.app](/#banks), in the app during setup, or by email. We use those requests to decide which bank to add next.

### Does Hasala need my bank password?

No. Hasala never connects to your bank and never asks for your bank details. It reads the alert emails your bank already sends to your Gmail, with read-only access.

### Can Hasala read my other emails?

Your iPhone asks Gmail only for messages from your banks' alert addresses. The rest of your inbox is never downloaded, and no email is ever sent to our server. Hasala can't send, delete or change your email. See [Gmail and Google user data](/privacy#gmail-and-google-user-data) for the details.

### Can you see my transactions?

No. Your transactions, amounts, merchants, categories, budgets, bills and rules are encrypted on your iPhone before they leave it. Our server can't read them. Our server can see your email address and name and some account details, which our [Privacy Policy](/privacy#what-we-collect-and-why) lists in full.

### How does Hasala sort my spending?

On your iPhone, in this order: your own rules, then a built-in list of UAE merchants, then Apple's on-device model for merchant names in English. Anything it's still unsure about waits for your review. Nothing is sent to an AI service. When you sort a transaction yourself, you can tell Hasala to always do the same for that merchant.

### Why does Google say it hasn't verified Hasala?

During the beta, Google shows a warning when you connect Gmail, because its review of Hasala's Gmail access isn't complete. To continue, tap **Advanced** on that screen, then the link to go to Hasala. You can remove Hasala's access at any time. [[OWNER: Update or remove this answer once Google verification is complete.]]

### Does Hasala work with SMS alerts or email forwarding?

No. Hasala reads alerts from Gmail only, and email forwarding isn't offered. If your bank sends only SMS alerts, check its app or online banking for an option to also send alerts by email.

### Is Hasala available in Arabic, or on Android?

Not yet. The beta is English only and iPhone only.

### How much does it cost?

Hasala is free during the beta.

### Why don't notifications show amounts?

To protect your privacy on the Lock Screen, notifications are generic by default, for example "New transaction". You can turn on detailed notifications in Settings › Notifications. [[OWNER: Confirm the path and the setting's name.]]

### Where is Hasala's source code?

Hasala's code is published as source-available under the FSL-1.1-ALv2 licence, at [github.com/salehtl/hasala](https://github.com/salehtl/hasala). Source-available means you can read it, but it isn't open source.

## Missing transactions or alerts

If transactions aren't showing up, work through these checks in order.

### 1. Check that Gmail is still connected

Open **Profile › Bank alerts**.

- If it says **Reconnect Gmail**, tap it and sign in again. Google access can end if you change your Google password, remove Hasala in your Google Account, or untick the Gmail permission on Google's screen.
- If it says **Read on your other iPhone**, a different iPhone is reading your alerts. Only one iPhone reads Gmail at a time. Tap **Read them here instead** to switch.
- If it shows an error, tap **Try again**. If the error keeps coming back, contact us and include the diagnostics (see step 6).

### 2. Check that your bank sends email alerts

Hasala can only see alerts your bank emails to you. In your bank's app or online banking:

- turn on **email** alerts for card purchases, transfers and account activity, not only SMS; and
- make sure the alerts go to the **same Gmail address** you connected to Hasala.

Open Gmail and confirm the alerts are arriving there, directly from your bank. [[OWNER: Say whether alerts in other labels, Spam, or forwarded from another address are read.]]

### 3. Check your bank is supported

Hasala reads alerts from DIB and Emirates NBD. Alerts from other banks are not read yet. If your bank changed the address its alerts come from, tell us so we can update Hasala.

### 4. Let Hasala run in the background

Hasala checks for new alerts in the background, but iOS decides when. To help it:

- turn on **Settings › General › Background App Refresh**, both overall and for Hasala;
- don't force-quit Hasala from the app switcher; and
- note that Low Power Mode can delay background checks.

Opening Hasala always checks for new alerts straight away.

### 5. Look in Review

If Hasala couldn't read an alert fully, it isn't dropped. It goes to **Review**, where you can fill in the missing details.

### 6. Still missing?

If Hasala notices a bank has gone quiet, it sends a "Bank alerts went quiet" notification. If you're still stuck, email us. Include **Copy diagnostics** from Profile › Bank alerts. [[OWNER: Confirm where Copy diagnostics lives.]] Diagnostics contain only counts and status codes, never amounts, merchants or email addresses.

## Moving to a new iPhone

Your sealed data is kept on our server, so you can move to a new iPhone without losing it. Hasala's local database is not included in iCloud or computer backups. Your new iPhone downloads your data again and unlocks it.

### If you use Face ID (a passkey)

1. Sign in to the same Apple Account on your new iPhone, with iCloud Keychain (Passwords) turned on.
2. Install Hasala from TestFlight and open it.
3. Sign in with Face ID. Your passkey unlocks your data.
4. Reconnect Gmail. Go to **Profile › Bank alerts** and tap **Read them here instead**, so the new iPhone reads your alerts.
5. Remove your old iPhone in **Profile › Devices** if you no longer use it. [[OWNER: Confirm the path.]]

Some passkey managers other than iCloud Keychain can't unlock Hasala on a new device. If yours can't, Hasala asks for your 12-word recovery phrase instead.

### If you sign in with email and password

Sign in, then enter your 12-word recovery phrase when Hasala asks. A password signs you in but doesn't unlock your data.

### If you've lost every passkey

Choose **Lost your passkey? Use your recovery phrase**. Hasala makes a new passkey on this iPhone and lets your other devices know.

### Restoring from an iPhone backup

Restoring a backup doesn't restore Hasala's data directly. Open Hasala and it downloads and unlocks your data again. Changes you made just before the backup that hadn't synced yet may be lost.

## Forgot your password

A password reset needs one of two things:

- **your 12-word recovery phrase**; or
- **an iPhone that's already signed in to Hasala.**

On the sign-in screen, tap **Forgot password**, then follow the steps with either one. [[OWNER: Confirm the exact flow and button names.]]

If you have a passkey, you can also just sign in with Face ID and change your password in Settings.

If you have none of these (no recovery phrase, no passkey and no signed-in iPhone), we can't reset your password or recover your data. This isn't a policy choice. We don't hold the keys to your data.

### Lost your recovery phrase?

If you still have a signed-in iPhone or a passkey, create a new recovery phrase in **Settings › Recovery phrase**. Write the new words down, and throw away any words you wrote down before. Your old words stop working with Hasala. [[OWNER: Confirm the path.]] If you think someone has seen your words, a new phrase won't undo that; see our [Security](/security) page. We can't reset or show your recovery phrase for you.

Hasala will never ask for your recovery phrase in an email, a notification or on a website. Only type it into the Hasala app.

## Delete your account

Deleting your account is permanent and can't be undone. If you want to keep your data, export it first from **Profile › Export**. [[OWNER: Confirm the path.]]

1. Open Hasala and go to **Profile › Delete your account**.
2. Read the summary and confirm it's you.
3. Hasala disconnects Gmail, then our server erases your account, sealed data, keys, sign-in methods and devices straight away.
4. Hasala erases its data on this iPhone. Your other iPhones erase theirs the next time they connect.

Afterwards:

- Encrypted backups that still contain your data expire within 30 days.
- Your passkey stays in your passkey manager. To remove it, open the **Passwords** app, find Hasala and delete it.
- You can check that Hasala no longer has Gmail access in your Google Account under **Security › Your connections to third-party apps and services**.
- Delete the Hasala app.

If you can't open the app any more and want your account deleted, email us from your account's email address. [[OWNER: Confirm this process and how requests are verified.]]

## Leave the beta

1. If you won't be coming back, **delete your account** first (see above). Deleting the app alone doesn't delete your account.
2. In the **TestFlight** app, open Hasala and tap **Stop Testing**.
3. Delete the Hasala app from your iPhone.

## Other things you can do

- **Sign out.** You'll need your passkey or password to sign back in. Your data stays on this iPhone.
- **Remove this iPhone.** This signs out, removes the iPhone from your devices and erases Hasala's data on it. Use it before you give away or sell an iPhone.
- **Sign out everywhere.** This ends every session on every device. Your devices keep their data, and you can sign in again.

## Contact us

- Help and feedback: [[OWNER: support@hasala.app]]. You can also send feedback, with screenshots, from the TestFlight app. Check screenshots before you send them, because they may show your amounts.
- Privacy questions and requests: [[OWNER: privacy@hasala.app]]
- Security problems: security@hasala.app. See our [Security](/security) page.

We're a small team, so replies can take a few days. [[OWNER: State the expected response time.]]

Please never send us your recovery phrase or your password. We'll never ask for them. If we ask for a sample bank alert to add support for your bank, remove your card and account numbers before you send it.
