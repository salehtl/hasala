---
title: "Help and Support"
description: "Answers for Hasala beta testers: connecting Gmail or Outlook, missing bank alerts, moving to a new iPhone, forgotten passwords, deleting your account and leaving the beta."
lastUpdated: 2026-10-19
status: "final"
plainWords: "Most problems are fixed by checking that your Gmail or Outlook is still connected and that your bank sends email alerts. To move to a new iPhone, sign in with Face ID, or use your 12 words. A forgotten password needs your 12 words or an iPhone that's still signed in. You can delete your account in the app at any time."
---

## Common questions

### What is Hasala?

Hasala (حصّالة, "piggy bank") is a private budgeting app for iPhone in the UAE. It reads your bank alert emails from your Gmail or Outlook on your iPhone and turns them into transactions. It then helps you plan your month, track bills and see where your money goes. Its App Store name is "Hasala Budgeting", but it isn't on the App Store yet: the beta runs on TestFlight. On your home screen it's just "Hasala".

### How do I join the beta?

Hasala is invite-only for now. Ask for an invite at [hasala.app](/#invite), then tap **Confirm my email** in the email we send you. Invites go out in small batches. When yours is ready, we email you the steps: install TestFlight, accept Apple's TestFlight invitation from its email or the link in your invite, install Hasala, then open it and enter your invite code. Apple handles the TestFlight invitation, so it sees your email address and that you installed Hasala. Other testers never see you. New versions reach you in TestFlight after Apple's beta review, which usually takes about a day.

To leave the waitlist, use **Leave the list** in any email we sent you. It deletes your address straight away.

### Which banks work?

Hasala reads alerts from Dubai Islamic Bank (DIB), Emirates NBD and Abu Dhabi Islamic Bank (ADIB). If your bank isn't listed, tell us which one you use: on [hasala.app](/#banks), in the app during setup, or by email. We use those requests to decide which bank to add next.

### Does Hasala need my bank password?

No. Hasala never connects to your bank and never asks for your bank details. It reads the alert emails your bank already sends to your Gmail or Outlook, with read-only access.

### Can Hasala read my other emails?

Your iPhone asks your mailbox only for messages from your banks' alert addresses, so the rest of your inbox is never downloaded. Before it uses a message, your iPhone checks that it really came from your bank; one that only looks like it did is set aside. No email is ever sent to our server. Hasala can't send, delete or change your email. See [Gmail and Google user data](/privacy#gmail-and-google-user-data) and [Outlook and Microsoft account data](/privacy#outlook-and-microsoft-account-data) for the details.

### Can you see my transactions?

No. Your transactions, amounts, merchants, categories, budgets, bills and rules are encrypted on your iPhone before they leave it. Our server can't read them. Our server can see your email address and name and some account details, which our [Privacy Policy](/privacy#what-we-collect-and-why) lists in full.

### How does Hasala sort my spending?

On your iPhone, in this order: your own rules, then a built-in list of UAE merchants, then Apple's on-device model for merchant names in English. Anything it's still unsure about waits for your review. Nothing is sent to an AI service. When you sort a transaction yourself, you can tell Hasala to always do the same for that merchant.

### Which email accounts work?

Gmail, and personal Microsoft accounts: outlook.com, hotmail.com and live.com addresses. Work and school Microsoft accounts (Microsoft 365 through an employer or a university) aren't supported. Hasala reads one mailbox at a time, so use the one your bank sends its alerts to.

### How do I connect Outlook?

During setup, at **Connect your email**, choose **Outlook**. Sign in with your Microsoft account and accept the permissions Microsoft shows you. Hasala asks only to read your mail, and keeps access without making you sign in each time. If you've already finished setup, go to **Profile › Bank alerts**.

Connecting Outlook replaces a Gmail connection, and connecting Gmail replaces an Outlook one. Hasala asks you to confirm first. Transactions it has already brought in stay.

If Hasala says your Microsoft account has no Outlook mailbox, the account uses an address from another provider and Microsoft doesn't hold mail for it. Connect the mailbox your bank sends alerts to instead.

### Why does Google say it hasn't verified Hasala?

During the beta, Google shows a warning when you connect Gmail, because its review of Hasala's Gmail access isn't complete. To continue, tap **Advanced** on that screen, then the link to go to Hasala. You can remove Hasala's access at any time.

### Does Hasala work with SMS alerts or email forwarding?

No. Hasala reads alerts from Gmail or Outlook only, and email forwarding isn't offered. If your bank sends only SMS alerts, check its app or online banking for an option to also send alerts by email.

### Is Hasala available in Arabic, or on Android?

Not yet. The beta is English only and iPhone only.

### How much does it cost?

Hasala is free during the beta.

### Why don't notifications show amounts?

To protect your privacy on the Lock Screen, notifications are generic by default, for example "New transaction". You can turn on **Show amounts and merchants** in Settings › Notifications.

### Where is Hasala's source code?

At [github.com/salehtl/hasala](https://github.com/salehtl/hasala). It's source-available under the Functional Source License (FSL-1.1-ALv2): you can read, run and change it, but not use it in a commercial product or service that competes with Hasala. Each version becomes available under the Apache License 2.0 two years after it's released. The name Hasala and the Slot mark are trademarks and aren't covered by the licence. See [LICENSE.md](https://github.com/salehtl/hasala/blob/main/LICENSE.md) for the exact terms.

## Missing transactions or alerts

If transactions aren't showing up, work through these checks in order.

### 1. Check that your email is still connected

Open **Profile › Bank alerts**.

- If it says **Reconnect Gmail**, tap it and sign in again. Google access can end if you change your Google password, remove Hasala in your Google Account, or untick the Gmail permission on Google's screen.
- If it says **Reconnect Outlook**, tap it and sign in with your Microsoft account again. Microsoft access can end if you remove Hasala at [account.live.com/consent/Manage](https://account.live.com/consent/Manage), and sometimes after you change your Microsoft password or don't use Hasala for a long time.
- If it says **Read on your other iPhone**, a different iPhone is reading your alerts. Only one iPhone reads your email at a time. Tap **Read them here instead** to switch.
- If it shows an error, tap **Try again**. If the error keeps coming back, contact us and include the diagnostics (see step 6).

### 2. Check that your bank sends email alerts

Hasala can only see alerts your bank emails to you. In your bank's app or online banking:

- turn on **email** alerts for card purchases, transfers and account activity, not only SMS; and
- make sure the alerts go to the **same email address** you connected to Hasala.

Open Gmail or Outlook and confirm the alerts are arriving there, directly from your bank. In Gmail, Hasala finds them in any label, archived mail and Spam included, but not in Trash. In Outlook, it finds them in any folder, Junk Email and archived mail included. Alerts forwarded from another email address may not be found, and any that are go to **Review** for you to check.

### 3. Check your bank is supported

Hasala reads alerts from DIB, Emirates NBD and ADIB. Alerts from other banks are not read yet. If your bank changed the address its alerts come from, tell us so we can update Hasala.

### 4. Let Hasala run in the background

Hasala checks for new alerts in the background, but iOS decides when. To help it:

- turn on **Settings › General › Background App Refresh**, both overall and for Hasala;
- don't force-quit Hasala from the app switcher; and
- note that Low Power Mode can delay background checks.

Opening Hasala always checks for new alerts straight away.

### 5. Look in Review

If Hasala couldn't read an alert fully, it isn't dropped. It goes to **Review**, where you can fill in the missing details.

### 6. Still missing?

If Hasala notices a bank has gone quiet, it sends a "Bank alerts went quiet" notification. If you're still stuck, email us. Include the diagnostics from **Settings › Get help › Copy diagnostics**. Diagnostics contain only the app and iOS versions, your iPhone model, counts and status codes, never amounts, merchants or email addresses.

## Moving to a new iPhone

Your sealed data is kept on our server, so you can move to a new iPhone without losing it. Hasala's local database is not included in iCloud or computer backups. Your new iPhone downloads your data again and unlocks it.

### If you use Face ID (a passkey)

1. Sign in to the same Apple Account on your new iPhone, with iCloud Keychain (Passwords) turned on.
2. Install Hasala from TestFlight and open it.
3. Sign in with Face ID. Your passkey unlocks your data.
4. Reconnect your email. Go to **Profile › Bank alerts** and tap **Read them here instead**, so the new iPhone reads your alerts.
5. Remove your old iPhone in **Profile › Sign-in & security › Devices** if you no longer use it.

Some passkey managers other than iCloud Keychain can't unlock Hasala on a new device. If yours can't, Hasala asks for your 12-word recovery phrase instead.

### If you sign in with email and password

Sign in, then enter your 12-word recovery phrase when Hasala asks. A password signs you in but doesn't unlock your data.

### If you've lost every passkey

On the sign-in screen, choose **Can't get in at all?** and use your 12-word recovery phrase with a code we email you. Hasala makes a new passkey or password on this iPhone and lets your other devices know.

### Restoring from an iPhone backup

Restoring a backup doesn't restore Hasala's data directly. Open Hasala and it downloads and unlocks your data again. Changes you made just before the backup that hadn't synced yet may be lost.

## Forgot your password

A password reset needs one of two things:

- **your 12-word recovery phrase**; or
- **an iPhone that's already signed in to Hasala.**

On the sign-in screen, tap **Forgot password?** and follow the steps. You'll approve the reset by scanning a code with an iPhone that's still signed in. If you don't have one, choose **Can't get in at all?** instead and use your 12 words with a code we email you.

If you have a passkey, you can also just sign in with Face ID and change your password in **Profile › Sign-in & security › Password**.

If you have none of these (no recovery phrase, no passkey and no signed-in iPhone), we can't reset your password or recover your data. This isn't a policy choice. We don't hold the keys to your data.

### Lost your recovery phrase?

If you sign in with a passkey, you can view your 12 words again in **Profile › Sign-in & security › Recovery phrase › View your 12 words**, after Face ID. We email you each time they're shown. Accounts that sign in with a password only can't show them again.

If you'd rather replace them, and you still have a signed-in iPhone or a passkey, create a new recovery phrase in **Profile › Sign-in & security › Recovery phrase › Make new words**. Write the new words down, and throw away any words you wrote down before. Your old words stop working with Hasala. If you think someone has seen your words, a new phrase won't undo that; see our [Security](/security) page. We can't reset your recovery phrase, or show it to you outside the app.

Hasala will never ask for your recovery phrase, your password or a code in an email, a notification, a phone call or on a website. Only type them into the Hasala app.

## Delete your account

Deleting your account is permanent and can't be undone. If you want to keep your data, export it first from **Settings › Export your data**.

1. Open Hasala and go to **Profile › Delete your account**.
2. Read the summary and confirm it's you.
3. Hasala disconnects your email, then our server erases your account, sealed data, keys, sign-in methods and devices straight away.
4. Hasala erases its data on this iPhone. Your other iPhones erase theirs the next time they connect.

Afterwards:

- Encrypted backups that still contain your data expire within 30 days.
- Your passkey stays in your passkey manager. To remove it, open the **Passwords** app, find Hasala and delete it.
- You can check that Hasala no longer has Gmail access in your Google Account under **Security › Your connections to third-party apps and services**.
- If you connected Outlook, remove Hasala's permission at [account.live.com/consent/Manage](https://account.live.com/consent/Manage). Microsoft doesn't let an app remove its own permission, so Hasala can't do this for you.
- Delete the Hasala app.

If you can't open the app any more and want your account deleted, email privacy@hasala.app from your account's email address. We'll reply to that address and ask you to confirm before we delete anything.

## Leave the beta

1. If you won't be coming back, **delete your account** first (see above). Deleting the app alone doesn't delete your account.
2. In the **TestFlight** app, open Hasala and tap **Stop Testing**.
3. Delete the Hasala app from your iPhone.

## Other things you can do

- **Sign out.** You'll need your passkey or password to sign back in. Your data stays on this iPhone.
- **Remove this iPhone.** This signs out, removes the iPhone from your devices and erases Hasala's data on it. Use it before you give away or sell an iPhone.
- **Sign out everywhere.** This ends every session on every device. Your devices keep their data, and you can sign in again.

## Contact us

- Help and feedback: support@hasala.app. You can also send feedback, with screenshots, from the TestFlight app. Check screenshots before you send them, because they may show your amounts.
- Privacy questions and requests: privacy@hasala.app
- Security problems: security@hasala.app. See our [Security](/security) page.

Hasala is a small, independent project, so replies can take a few days.

Please never send us your recovery phrase or your password. We'll never ask for them. If we ask for a sample bank alert to add support for your bank, remove your card and account numbers before you send it.
