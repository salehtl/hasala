---
title: "Privacy Policy"
description: "How Hasala handles your data: what stays on your iPhone, what our server can and can't see, how Gmail access works, and your rights under UAE law."
lastUpdated: 2026-10-11
status: "draft"
draftNote: "Draft pending owner review. This is not legal advice and has not been reviewed by a lawyer. Do not publish until every [[OWNER]] marker is resolved."
plainWords: "Hasala reads your bank alerts from Gmail on your iPhone and encrypts your transactions there before they sync. Our server stores sealed data it can't open. It does see your email address, your name and some account details, which we list here. We don't sell data, show ads or send anything to an AI service."
---

## Who we are

Hasala (حصّالة) is a private budgeting app for iPhone, made for people in the United Arab Emirates. It is available as an invite-only beta through Apple's TestFlight. In this policy, "Hasala", "we" and "us" mean the operator of the app and of hasala.app:

[OPERATOR LEGAL NAME, ADDRESS]

[[OWNER: Give the legal entity or individual that operates Hasala, its registered address and, if it has one, its trade licence number and issuing authority (or free zone). If the operator sits in DIFC or ADGM, a different data protection law applies and this policy must be rewritten for it.]]

This policy covers the Hasala iPhone app (App Store name "Hasala Budgeting"), the website at hasala.app, and the emails we send from no-reply@hasala.app. It describes the beta as it works today.

## The short version

- **Your bank emails are read on your iPhone.** Hasala connects to your Gmail with read-only access. Your iPhone fetches only messages from your banks' alert addresses. The emails themselves are never sent to our server.
- **Your money data is sealed on your iPhone before it syncs.** Your transactions, amounts, merchants, categories, budgets, bills and rules are encrypted on your iPhone before they leave it. Our server can't read them.
- **Our server still sees some things.** It sees your email address and name, that your account exists, details about your sign-in methods and devices, when you sync and how much sealed data you store, and a keyed hash of your Gmail address with the timing of new mail. We list all of it below.
- **No ads, no data sales, no AI services.** Hasala sorts transactions on your iPhone. Today, nothing is sent to an AI service. If we ever offer an optional, AI-powered feature, it will be off by default, explained before you turn it on, and you can turn it off at any time. Data from your Gmail will never be used to train AI models (see Google API data, below).

## What stays on your iPhone

Some things never leave your iPhone. Others leave only in sealed form.

### Never leaves your iPhone

- **Your bank alert emails.** Your iPhone downloads them from Gmail, reads them and keeps the details it needs: amount, merchant, date, card, and the Gmail message ID so it can find the email again. The email itself isn't stored in your Hasala data and isn't sent to us.
- **Your Gmail access token.** The token that lets Hasala read your Gmail is kept in your iPhone's Keychain, on this iPhone only. Our server never receives it.
- **Your encryption keys.** The keys that open your data are kept in the Keychain on this iPhone only. They aren't included in iCloud or computer backups.
- **Your 12-word recovery phrase.** It is created on your iPhone and shown to you once. Hasala doesn't store it anywhere, and it is never sent to us.
- **Your settings for this iPhone.** Examples are notification level, Hide amounts and Face ID lock.

### Leaves your iPhone only in sealed form

Your transactions, budget and plan sync between your devices through our server. Before anything in them leaves your iPhone, it is encrypted with keys only your devices hold. This covers transactions, amounts, merchants, categories, notes, budgets, bills, accounts, goals, projects and rules. Our server stores this sealed data and passes it to your other devices. It cannot open it.

### How your iPhone stores it

Hasala's local database on your iPhone is protected by iOS data protection. It can't be read after a restart until you unlock your iPhone for the first time. It is excluded from iCloud and computer backups. If you restore a backup to a new iPhone, Hasala downloads your sealed data again and unlocks it with your passkey or your recovery phrase.

Anyone who can unlock your iPhone can open Hasala and see your data. Face ID lock hides Hasala until you unlock it. It doesn't change how your data is encrypted.

## What we collect and why

This is everything our server receives or stores about you, and why.

### Your account

| What | Why |
| --- | --- |
| Your email address (verified when you sign up) | To identify your account, let you sign in with a password if you choose one, and send you account emails such as verification and security notices. |
| Your display name | To show your name in the app and in emails we send you. |
| A random account ID, when your account was created, and its status (active, suspended or deleted) | To run your account. |

### How you sign in

| What | Why |
| --- | --- |
| For each passkey: its ID, its public key, the type of authenticator, whether it is backed up, and when it was last used | To check that it's you when you sign in with Face ID. A passkey's private part stays in your passkey manager; we never receive it. |
| If you set a password: information our server uses to check it, never the password in readable form | To let you sign in with email and password. [[OWNER: Confirm the password storage scheme (for example Argon2id or OPAQUE) and adjust this row.]] |
| Your sealed recovery data: an encrypted copy of your account keys that only your 12-word recovery phrase can open, plus related public keys | So you can get back into your account with your recovery phrase if you lose every device and passkey. |
| Sign-in sessions: a one-way hash of each session token, and when it was created, last used and ended | To keep you signed in, and let you sign out on every device. |
| Security actions and when they happened, such as "Gmail connected at 10:02" or "passkey added" | To protect your account and show you security alerts on your other devices. |

A password never unlocks your data. Only a passkey or your 12-word recovery phrase can do that.

### Your devices

| What | Why |
| --- | --- |
| A random ID for each iPhone you add, and when it was added or removed | So your devices can trust each other's changes, and so you can remove a lost iPhone. |
| Each iPhone's push token from Apple | To send a silent signal that wakes Hasala on your iPhone when there is new mail or a change to sync. |

### Sync

| What | Why |
| --- | --- |
| Your sealed data | To sync your transactions, budget and plan between your devices. |
| When each device syncs, a rough size for each upload, and how much sealed data you store | To keep sync in order, apply storage limits and stop abuse. |

### Gmail connection

| What | Why |
| --- | --- |
| A keyed hash of your Gmail address (a code made from it with a secret key) | So that when Google tells us new mail has arrived, we know which iPhone to wake. |
| The timing of new mail in your Gmail | To wake Hasala on your iPhone so it can check for new bank alerts. This happens for every new email, not only bank alerts. |
| When your Gmail notification setup next needs renewing | To remind your iPhone to renew it so alerts keep arriving. |

Your Gmail address reaches our server in two moments. The first is when you connect Gmail. The second is each time Google notifies us that new mail has arrived. Our server uses the address to find the right account and then discards it. It stores only the keyed hash and never writes the address to its logs. Because the hash is made from your address, someone holding our secret key could check whether a guessed address matches it.

### Your IP address

Our server sees the IP address of each request, passed on by Cloudflare. It uses it briefly in memory to limit abuse, for example too many sign-in attempts. It does not write IP addresses to its logs or database.

### Invites

| What | Why |
| --- | --- |
| A one-way hash of your invite code and of the key in your invite link, a keyed hash of the email address we sent the invite to, and when the invite was created, sent, used, or expired | To make sure only invited people can create an account, and that an invite link opened from your email confirms your address. |
| A short note we write when we create the invite, such as the first name of the person it's for | To keep track of who we invited. |

30 days after an invite is used, expires or is withdrawn, we forget the note, the keyed hash of the address and the link key. An unused invite is then deleted. A used invite stays linked to your account as "invite used" until you delete your account; when you do, the link to your account goes too.

**Your invite.** When we invite you, we add you as a tester in Apple's TestFlight, by email or with an invitation link, so you can install the beta. Apple handles the TestFlight invitation: it sees your email address and that you installed Hasala, and Apple's terms apply to TestFlight. Testers never see each other. When you create your Hasala account, we delete your address from the waitlist; your account keeps its own.

### Bank requests

If you tell us in the app which bank you use and it isn't supported yet, we link the request to your account so we can tell you when your bank works with Hasala. It's deleted with your account.

If you tell us your bank on our website without asking for an invite, we count it. We don't store your email address, your IP address or anything else that identifies you with it.

### Things you send us

| What | Why |
| --- | --- |
| Emails you send to our support, privacy or security addresses | To answer you. |
| Feedback and crash reports you send through TestFlight | Apple passes these to us. If you attach a screenshot, it may show your amounts and merchants, so check it before you send. |

### The website

**Asking for an invite.** When you ask for an invite at hasala.app, we store your email address, the bank you picked (and the bank name you typed, if you chose "Another bank"), and when you asked. We email you a link to confirm the address. If you don't confirm it within 7 days, we delete it. We use your address only to send your invite and to tell you when your bank works with Hasala, never for marketing. Every email we send has a link to leave the list, which deletes your address straight away. Only we review the list, in an admin tool that is reachable only from our own devices over a private network.

**Telling us your bank.** See [Bank requests](#bank-requests) above: a bank you tell us about on the website is only counted.

**Bot checks.** Our forms may use Cloudflare Turnstile to tell people from bots. Cloudflare looks at technical details from your browser, including your IP address, to decide; we receive only the answer. [[OWNER: Keep this paragraph only while Turnstile is switched on for the website's forms; delete it otherwise.]]

**Emails we send.** We keep a record of each email we send you: what kind it was, the address, when we sent it and whether it was delivered. We never keep what the email said. These records are deleted after 30 days.

**Cookies and analytics.** The website sets no cookies and runs no analytics. It remembers, in your browser and only for the open tab, that you've already seen the opening animation; that never leaves your browser. [[OWNER: Confirm that no analytics (for example Cloudflare Web Analytics) is switched on for hasala.app.]]

### What we don't collect

- Your bank emails, or any other email in your Gmail.
- Your amounts, merchants, categories, budget or plan in readable form.
- Your recovery phrase, encryption keys or Gmail access token.
- Your contacts, location, photos or browsing activity.

The app contains no advertising, analytics or crash-reporting tools from other companies.

## How we use your data

We use your data only to:

- provide Hasala: run your account, sign you in, sync your sealed data and wake your iPhone when new mail arrives;
- keep Hasala secure: stop abuse, investigate security problems and alert you to changes on your account;
- send you emails about your account, such as verification, password, security and beta notices;
- answer your messages; and
- meet our legal obligations.

We don't sell your data. We don't use it for advertising. We don't use it to decide whether you get credit or a loan. We don't use it to train AI or machine learning models.

Under the UAE Personal Data Protection Law, we rely on these grounds:

- **Providing the service you asked for.** This covers running your account, sync and push.
- **Your consent.** This covers connecting Gmail. You give it in Google's permission screen, and you can withdraw it at any time.
- **Complying with the law, and protecting Hasala and its users.**

[[OWNER: Have counsel confirm these grounds against Articles 4 and 5 of Federal Decree-Law No. 45 of 2021 and any executive regulations in force.]]

## Gmail and Google user data

Hasala asks Google for read-only access to your Gmail (the `gmail.readonly` permission), plus your Gmail address so it can match the connection to your account.

### What Hasala does with it

- Your iPhone, not our server, connects to Gmail.
- Your iPhone asks Gmail only for messages from your banks' alert addresses. The rest of your inbox, including the senders and subjects of other emails, is never downloaded.
- From each bank alert, your iPhone keeps the amount, merchant, date and card, plus the Gmail message ID so you can open the original email later. These become transactions, which are encrypted on your iPhone before they sync.
- Hasala can't send, delete, label or change your email.
- At launch, Hasala reads alerts from Dubai Islamic Bank (DIB) and Emirates NBD.

### Limited Use

Hasala's use and transfer to any other app of information received from Google APIs will adhere to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements.

In practice, for data Hasala receives from your Gmail:

1. **Used only for features you can see.** We use it only to find your bank transactions and show them in Hasala, and to let you open the original alert.
2. **No transfers, except as allowed.** We don't transfer it to anyone, except when needed to provide those features, to comply with the law, or as part of a merger, acquisition or sale of assets, and then only with your explicit consent first. In practice it isn't transferred at all. The raw emails stay on your iPhone, and the details drawn from them leave only as sealed data our server can't open.
3. **No ads.** We never use or transfer it to serve ads, including personalised, retargeted or interest-based ads.
4. **No sales, no credit decisions.** We never sell it, and we never use it to decide whether you get credit or a loan.
5. **No one reads your email.** Our team doesn't read it, and the design keeps it out of our reach. The only exception would be if you explicitly agreed to let us look at a specific email, for example to add support for your bank. Even then, you would choose the email and send it to us yourself.
6. **No AI training.** We don't use it to develop, improve or train AI or machine learning models. Hasala's categorisation runs on your iPhone using Apple's on-device model, and nothing from your Gmail is sent to an AI service.

[[OWNER: Confirm the merger and acquisition clause matches the operator's intentions.]]

### Google's verification screen

During the beta, Google shows a warning that it hasn't verified Hasala. This happens because Google's verification of apps that read Gmail is not yet complete for Hasala. [[OWNER: Update this paragraph if Hasala completes Google's OAuth verification and security assessment.]]

### Stopping Gmail access

You can disconnect Gmail in Hasala under Profile › Bank alerts. Hasala then revokes its access at Google and stops Google's new-mail notifications. You can also remove Hasala's access in your Google Account under Security › Your connections to third-party apps and services. Deleting your Hasala account disconnects Gmail too.

## Encryption in plain words

Your transactions, amounts, merchants, categories, budgets, bills and rules are encrypted on your iPhone before they leave it. Our server can't read them. This is what we mean by end-to-end encrypted: the data is sealed on your iPhone and opened only on your devices, and our server stores and passes along only the sealed copies.

The keys that open your data are created on your iPhone. Your devices hold them, and two things can unlock them on a new device:

- **your passkey**, which you use with Face ID and which syncs through iCloud Keychain; and
- **your 12-word recovery phrase.**

Some things are not sealed. Our server needs your email address, your name and the account details listed above to run your account, so it can read them.

Hasala will never ask for your recovery phrase in an email, a notification or on a website. Only type it into the Hasala app.

If you lose your recovery phrase and every passkey, your account can't be recovered. Not even by us.

## Notifications

Hasala writes its notifications on your iPhone. Our server only sends a silent signal through Apple to wake the app. It never sends what a notification says.

By default, notifications don't show amounts or merchants. For example, you'll see "New transaction" and "Tap to see it in Hasala". You can turn on detailed notifications in Settings. If you do, amounts and merchants may appear on your Lock Screen.

## Who else handles your data

We use a small number of service providers. None of them can open your sealed data.

| Provider | What they do | What they can see |
| --- | --- | --- |
| **Cloudflare** | Network provider in front of our server, and host of the hasala.app website. Encryption in transit ends at Cloudflare, which forwards requests to our server. | The requests between the app and our server, including your IP address, your email address and name when they are sent, and the sealed data. It also sees what you type into the website's forms, such as your email address and bank. Cloudflare cannot open the sealed data. |
| **Cloudflare Email Service** | Delivers the emails we send from no-reply@hasala.app. | Your email address and the content of those emails, such as a verification code. |
| **Cloudflare R2** | Stores an off-site copy of our encrypted server backups. | Encrypted backup files only. Cloudflare doesn't hold the key to open them. |
| **Google** | Hosts your Gmail and tells our server when new mail arrives. | Your mail, as it already does, and that you've given Hasala read-only access. Google also sees your iPhone's IP address when it connects to Gmail. |
| **Apple** | Distributes the beta through TestFlight and handles your TestFlight invitation, delivers silent push signals, and syncs your passkeys in iCloud Keychain. | That you installed the beta, push timing, and any feedback or crash reports you choose to send. For an invite: your email address. Testers never see each other. Apple encrypts iCloud Keychain so that Apple itself can't read your passkeys. Your Hasala database is excluded from iCloud backups. |

[[OWNER: Confirm that the R2 off-site backup copy is in use. Confirm whether Cloudflare hosts the hasala.app website. Confirm whether any other provider (for example a waitlist store or an admin tool) processes personal data.]]

### Our server

During the beta, our server is a computer run by the developer. It sits behind Cloudflare and accepts no connections except through Cloudflare. Two people have administrator access to it. [[OWNER: Confirm the number of administrators and name the server's country (for example "in the UAE").]]

### Where your data is processed

Our server is located in [[OWNER: country]]. Cloudflare, Google and Apple operate worldwide, so data they handle may be processed outside the UAE. When personal data leaves the UAE, we rely on the protections in the providers' own data processing terms and on the cross-border transfer rules of the UAE Personal Data Protection Law. [[OWNER: Have counsel confirm the transfer basis under Articles 22 and 23.]]

## How long we keep data

| Data | How long |
| --- | --- |
| Your account, sign-in methods, devices and sealed data | Until you delete your account. They are then erased from our server straight away. |
| Encrypted server backups | Made daily and kept for 30 days. After you delete your account, your encrypted data, keys and account details can remain in backups for up to 30 days. |
| Sign-in sessions | A session ends after 30 days without use, or after 90 days at most. Its record is removed 30 days after it ends. |
| Push tokens | Removed when you sign out, remove that iPhone, or delete your account. |
| Gmail connection (keyed hash) | Until you disconnect Gmail, remove the iPhone that reads it, or delete your account. Google may keep sending new-mail notices for up to 7 days after that. We ignore them and store nothing from them. |
| Your old recovery data after you change your recovery phrase | Removed from our server straight away, so the old words stop working with it; may remain in encrypted backups for up to 30 days. Someone who already used the old words keeps what they got with them (see our [Security](/security) page). |
| Invite records | Unused invites expire after 14 days, unless we set a different expiry. 30 days after an invite is used, expires or is withdrawn, its note, address hash and link key are forgotten, and an unused one is deleted. A used invite stays linked to your account until you delete it. |
| Server logs | Our logs never contain your email address, IP address, tokens or sealed data. They hold only technical events and error codes. They are kept for [[OWNER: period, per the host's log retention]]. |
| Support emails | [[OWNER: period]] |
| Waitlist sign-up, not confirmed | 7 days. |
| Waitlist sign-up, confirmed | Until you join, leave the list, or 12 months, whichever comes first. [[OWNER: Confirm 12 months, and set the server's waitlist retention to match (spec 07 Q8; its default is 180 days).]] |
| Website bank votes | Kept. They contain nothing that identifies you. |
| Bank requests from the app | Until you delete your account. |
| Email records | 30 days. We never keep what an email said. |
| Data on your iPhone | Until you delete your account or use Remove this iPhone. Signing out keeps your data on the iPhone. Deleting the app removes it from the iPhone. |

## Deleting your account

You can delete your account in the app under Profile › Delete your account. You'll be asked to confirm it's you. Then:

1. Hasala stops Gmail notifications and revokes its Gmail access.
2. Our server erases your account, sealed data, keys, sign-in methods, devices and Gmail connection straight away.
3. Hasala erases its data on that iPhone. Your other iPhones erase theirs the next time they connect.
4. Encrypted backups that still contain your data expire within 30 days.

Your passkey stays in your passkey manager until you delete it there, for example in the Passwords app. Step-by-step instructions are on our [Support](/support) page.

[[OWNER: Decide whether to accept deletion requests by email from people who can no longer open the app, and how to verify them.]]

## Security

Security is built into how Hasala works:

- Data is sealed on your iPhone with modern authenticated encryption, and the server refuses data that isn't sealed.
- Sign-in with Face ID uses passkeys.
- Sensitive actions, such as connecting Gmail, adding a device or deleting your account, ask you to confirm it's you again. [[OWNER: Confirm how this works for accounts that sign in with a password only.]]
- Our server accepts connections only through Cloudflare, and its logs exclude personal data.
- Backups are encrypted, and the key to open them is not kept on the server.

No system is perfectly secure. Our [Security](/security) page explains the design, its limits and how to report a problem.

## Your rights

Under the UAE Personal Data Protection Law (Federal Decree-Law No. 45 of 2021), you have the right to:

- **Access.** You can ask what personal data we hold about you, why, who we share it with and how long we keep it.
- **Portability.** You can ask for your data in a structured, machine-readable form.
- **Correction.** You can ask us to fix data that is wrong or incomplete.
- **Erasure.** You can ask us to delete your data.
- **Restriction.** You can ask us to limit how we use your data, for example while a dispute is settled.
- **Objection and withdrawal of consent.** You can ask us to stop processing your data, and you can withdraw consent, such as Gmail access, at any time.
- **Automated decisions.** You can object to decisions based only on automated processing that have legal or similarly significant effects on you. Hasala makes no such decisions about you. Categorisation is a suggestion on your own iPhone, and you can change it.

### Because we can't open your data

Because your transactions, budget and plan are sealed, we can't read them, so we can't hand them over in readable form. You can export them yourself from the app as a CSV file. [[OWNER: Confirm the in-app export path, for example Profile › Export.]] What we can give you on request is the account data listed in [What we collect and why](#what-we-collect-and-why).

### How to exercise your rights

Email [[OWNER: privacy@hasala.app]] from the email address on your account. We'll reply within 30 days. [[OWNER: Confirm the response time against the PDPL executive regulations.]] We may ask you to confirm the request in the app so that we know it's you. We don't charge for requests.

If you're not satisfied with our answer, you can complain to the UAE Data Office.

[[OWNER: Have counsel confirm whether the PDPL executive regulations are in force, whether Hasala must appoint a data protection officer or register with the UAE Data Office, and whether any rights listed here need adjusting.]]

## Children

Hasala is for adults. You must be at least [[OWNER: 18 or 21]] to use it. We don't knowingly collect data from children. If you think a child has created an account, contact us and we'll delete it.

## Changes to this policy

We'll update this policy when Hasala changes. The date at the top shows when it last changed. If a change affects how we use your data, we'll tell you in the app or by email before it takes effect. [[OWNER: Decide the notice period, for example 14 days.]]

## Contact

- Privacy questions and requests: [[OWNER: privacy@hasala.app]]
- Security reports: security@hasala.app
- Everything else: see our [Support](/support) page.

Postal address: [OPERATOR LEGAL NAME, ADDRESS]
