---
title: "Privacy Policy"
description: "How Hasala handles your data: what stays on your iPhone, what our server can and can't see, how access to your Gmail or Outlook works, and your rights under UAE law."
lastUpdated: 2026-10-24
status: "final"
plainWords: "Hasala is an experimental beta, so the app and this policy change often. Hasala reads your bank alerts from your Gmail or Outlook on your iPhone and encrypts your transactions there before they sync. Our server stores sealed data it can't open. It does see your email address, your name and some account details, which we list here. We don't sell data or show ads. Nothing goes to an AI service unless you turn on Cloud suggestions, and even then we send only what's listed here, without your name or account."
---

## An experimental beta

Hasala is an experimental beta. It is available by invite only, through Apple's TestFlight. It is not a finished product.

- Features change often, sometimes without notice.
- Things can break, and your data can be lost or reset.
- Don't rely on Hasala as your only record of your money. Your bank's statements are the record.

This policy describes the beta as it works today, and it changes when the app does (see [Changes in the beta](#changes-in-the-beta)). Our [Terms](/terms) say more about what the beta means for you.

## Who we are

Hasala (حصّالة) is a private budgeting app for iPhone, made for people in the United Arab Emirates. It is available as an invite-only beta through Apple's TestFlight.

Hasala is run by **Saleh Lootah**, an individual based in the United Arab Emirates. He is the controller of the personal data this policy describes. Hasala is not a company. In this policy, "Hasala", "we" and "us" mean him, as the operator of the app and of hasala.app.

We can be reached by email only; the addresses are under [Contact](#contact).

This policy covers the Hasala iPhone app (App Store name "Hasala Budgeting"), the website at hasala.app, and the emails we send from no-reply@hasala.app (replies to them go to support@hasala.app). Where it names a screen, a button or a setting in the app, that is to help you find it; names and places in the app may change.

## The short version

- **Your bank emails are read on your iPhone.** Hasala connects to your Gmail or Outlook mailbox with read-only access. Your iPhone fetches only messages from your banks' alert addresses. The emails themselves are never sent to our server.
- **Your money data is sealed on your iPhone before it syncs.** Your transactions, amounts, merchants, categories, budgets, bills and rules are encrypted on your iPhone before they leave it. Our server can't read them.
- **Our server still sees some things.** It sees your email address and name, that your account exists, details about your sign-in methods and devices, when you sync and how much sealed data you store, and a keyed hash of your Gmail or Outlook address with the timing of changes in your mailbox. From that timing it can tell roughly when, and how often, you get bank alerts, though not what they say. We list all of it below.
- **No ads, no data sales. AI services only if you ask.** Hasala sorts transactions on your iPhone. If you turn on Cloud suggestions (off by default), Hasala sends merchant names to Cloudflare's AI service for suggested categories, one name at a time, while the app is open. A name isn't sent with your name, your account or anything that links it to you, and it isn't kept. Data from your Gmail or Outlook is never used to train AI models (see [Cloud suggestions](#cloud-suggestions), [Limited Use](#limited-use) and [Outlook and Microsoft account data](#outlook-and-microsoft-account-data), below).

## What stays on your iPhone

Some things never leave your iPhone. Others leave only in sealed form.

### Never leaves your iPhone

- **Your bank alert emails.** Your iPhone downloads them from Gmail or Outlook, reads them and keeps the details it needs: amount, merchant, date, card, and the Gmail or Outlook message ID so it can find the email again. The email itself isn't stored in your Hasala data and isn't sent to us.
- **Your Gmail or Outlook access tokens.** The tokens that let Hasala read your mailbox are kept in your iPhone's Keychain, on this iPhone only. Our server never receives them.
- **Your settings for this iPhone.** Examples are App lock, Show amounts and merchants, Cloud suggestions and Profile picture from Gravatar.
- **What you ask Search.** If Apple Intelligence is on, Search can use Apple's on-device model to understand a question, such as "coffee last month". The model runs on your iPhone, and the question isn't sent anywhere. Your recent searches are kept only while the app is running.

### Leaves your iPhone only in sealed form

- **Your money data.** Your transactions, budget and plan sync between your devices through our server. Before anything in them leaves your iPhone, it is encrypted with keys only your devices hold. This covers transactions, amounts, merchants, categories, notes, budgets, bills, accounts, goals, projects and rules. Our server stores this sealed data and passes it to your other devices. It cannot open it.
- **Your encryption keys.** The keys that open your data are created on your iPhone and kept in its Keychain, on this iPhone only. They aren't included in iCloud or computer backups. Our server keeps only sealed copies of them, which your passkey or your recovery phrase opens, so that a new iPhone can unlock your data.
- **Your 12-word recovery phrase.** It is created on your iPhone. Our server keeps a sealed copy it can't open, so that you can view the words again in Hasala with your passkey. We email you each time they're shown. If you sign in with a password only, they can't be shown again, so keep the copy you wrote down.

### How your iPhone stores it

Hasala's local database on your iPhone is protected by iOS data protection. It can't be read after a restart until you unlock your iPhone for the first time. It is excluded from iCloud and computer backups. If you restore a backup to a new iPhone, Hasala downloads your sealed data again and unlocks it with your passkey or your recovery phrase.

Anyone who can unlock your iPhone can open Hasala and see your data. App lock, in Profile › Sign-in & security, hides Hasala until you unlock it with Face ID, Touch ID or your passcode. It doesn't change how your data is encrypted.

## What we collect and why

This is everything our server receives or stores about you, and why.

### Your account

| What | Why |
| --- | --- |
| Your email address (verified when you sign up) | To identify your account, let you sign in with a password if you choose one, and send you account emails such as verification and security notices. |
| Your display name, which you can change in Profile › Name | To show your name in the app and to greet you in emails we send you. |
| A random account ID, a second random ID that your passkeys carry, when your account was created, and its status (active or suspended, and when it was suspended). A deleted account is erased, not marked. | To run your account. |
| When your address was verified, whether emails to it stopped being delivered, and when we asked you to verify it again | To keep account emails reaching you. |
| Whether your account is frozen, when, by whom (you or us), and the time of the sign-in or other event that led to it | To protect your account. |
| Whether the account is one we set up for Apple's beta app review | So a reviewer's account can load sample data. |

### How you sign in

| What | Why |
| --- | --- |
| For each passkey: its ID, its public key, the type of authenticator, how it connects, a counter it reports, whether it can be and is backed up, a hash of the statement it gave when it was added, and when it was added and last used | To check that it's you when you sign in with Face ID. A passkey's private part stays in your passkey manager; we never receive it. |
| If you set a password: a scrambled form of it, never the password itself. Your iPhone scrambles your password with a deliberately slow, salted function before sending it, and our server stores only a further salted hash of that scrambled form. | To let you sign in with email and password. |
| If you set a password: how many wrong tries were made recently, and any pause on password sign-in after too many | To stop someone guessing your password. |
| Sealed copies of your account keys: one that only your 12-word recovery phrase can open, one for each passkey that only that passkey can open, plus related public keys | So a new iPhone can unlock your data with your passkey, and so you can get back into your account with your recovery phrase if you lose every device and passkey. |
| A sealed copy of your recovery phrase, which our server can't open, and the time you first viewed your 12 words (or that you haven't yet) | So you can view your 12 words again in Hasala after confirming with your passkey. We email you each time they're shown. If you signed up with a passkey and haven't viewed your words yet, the time lets Hasala remind you on any of your iPhones. It never holds the words. |
| Sign-in sessions: a one-way hash of each session token, how it started, when it was created and last used, and when and why it ended | To keep you signed in, and let you sign out on every device. |
| Security actions and when they happened, such as "Gmail connected at 10:02" or "passkey added" | To protect your account and email you security alerts. |

A password never unlocks your data. Only a passkey or your 12-word recovery phrase can do that.

Some records last only minutes:

| What | How long |
| --- | --- |
| While you sign up: your email address, your name and a keyed hash of the address | Up to 30 minutes, until your account is created or the sign-up runs out. |
| Each code we email you: a keyed code made from it (never the code itself) and a keyed hash of the address | The code works for 10 minutes. The record is deleted an hour after that. |
| If you change your email address: the new address, a keyed hash of it and, if you use a password, its scrambled form for the new address | Up to 10 minutes, until the change is done or runs out. |
| Other sign-in, recovery and reset steps in progress: a keyed hash of your address and one-time values | Up to 10 minutes. |

### Your devices

| What | Why |
| --- | --- |
| A random ID for each iPhone you add, the public parts of its signing key and its approval key, and when it was added or removed | So your devices can trust each other's changes, and so a lost iPhone can be removed from your account. |
| A log of each iPhone's keys: the public keys, when each iPhone was added or removed, the signatures that approved it and, for a removed iPhone, a fingerprint of its last change, not its content. It is kept for as long as your account exists. | So your devices can check that every change came from an iPhone that was on your account at the time. |
| Each iPhone's push token from Apple | To send a silent signal that wakes Hasala on your iPhone when there is new mail or a change to sync. |

### Sync

| What | Why |
| --- | --- |
| Your sealed data | To sync your transactions, budget and plan between your devices. |
| When each device syncs, a rough size for each upload, and how much sealed data you store | To keep sync in order, apply storage limits and stop abuse. |
| Upload refusals: on a day our server refuses uploads from your account, the reason (such as a storage limit) and how many | To spot accounts that hit a limit, so nothing is lost without anyone knowing. Kept for 90 days. |

Your iPhone uploads new transactions soon after a bank alert arrives. So our server, and Cloudflare in front of it, can tell roughly when, and how often, you get bank alerts. They can't tell what the alerts say.

### Gmail connection

| What | Why |
| --- | --- |
| A keyed hash of your Gmail address (a code made from it with a secret key) | So that when Google tells us your mailbox has changed, we know which iPhone to wake. |
| The timing of changes in your Gmail, such as new mail arriving or mail being read, archived or deleted | To wake Hasala on your iPhone so it can check for new bank alerts. This happens for every change, not only bank alerts. |
| When your Gmail notification setup next needs renewing | To remind your iPhone to renew it so alerts keep arriving. |

Your Gmail address reaches our server in two moments. The first is when you connect Gmail. The second is each time Google notifies us that something in your Gmail has changed. Our server uses the address to find the right account and then discards it. It stores only the keyed hash and never writes the address to its logs. If you also use that address as your Hasala email address, our server already has it, in plain text, as your account address. Because the hash is made from your address, someone holding our secret key could check whether a guessed address matches it.

### Outlook connection

| What | Why |
| --- | --- |
| A keyed hash of your Outlook address (a code made from it with a secret key) | To record which mailbox is connected without keeping the address itself. |
| A hash of a random code made for your Outlook connection | So that when Microsoft tells us something new arrived in your Inbox, we know which iPhone to wake. |
| The timing of new messages in your Outlook Inbox | To wake Hasala on your iPhone so it can check for new bank alerts. This happens for every new message, not only bank alerts. |
| When your Outlook notification setup next needs renewing | To remind your iPhone to renew it so alerts keep arriving. |

Your Outlook address reaches our server only once, when you connect Outlook: it is in the proof of sign-in from Microsoft that your iPhone sends us. Our server uses it to find the right account and to make the keyed hash, then discards it, and never writes it to its logs. If you also use that address as your Hasala email address, our server already has it, in plain text, as your account address.

When you connect Outlook, our server makes a random code and gives it to your iPhone, which keeps it in its Keychain and passes it to Microsoft. Our server keeps only a hash of the code and never writes the code to its logs. Each time a new message arrives in your Inbox, Microsoft sends our server a notice with that code, so it can tell which iPhone to wake. The notice doesn't contain your address. It does contain an ID for the new message; our server discards that part without reading, storing or logging it.

### Your IP address

Our server sees the IP address of each request, passed on by Cloudflare. It uses it briefly in memory to limit abuse, for example too many sign-in attempts. It does not write IP addresses to its logs or database.

### Invites

| What | Why |
| --- | --- |
| A one-way hash of your invite code and of the key in your invite link, a keyed hash of the email address we sent the invite to, and when the invite was created, sent, used, or expired | To make sure only invited people can create an account, and that an invite link opened from your email confirms your address. |
| A short note we write when we create the invite, such as the first name of the person it's for | To keep track of who we invited. |

30 days after an invite is used, expires or is withdrawn, we forget the note, the keyed hash of the address and the link key. An unused invite is then deleted. A used invite stays linked to your account as "invite used" until you delete your account; when you do, the link to your account goes too.

**Your invite.** When we invite you, we add your email address to Hasala's beta on Apple's TestFlight, and Apple emails you an invitation to install it. We don't give Apple your name. Apple's terms apply to your use of TestFlight. TestFlight tells us whether you accepted the invitation and when you install and open the beta. It also sends us crash reports, which show where the app failed and aren't meant to include your transactions, and any feedback you send through it. TestFlight doesn't show testers to each other.

**If you'd rather Apple didn't get your address.** Tell us at support@hasala.app before we invite you, and we'll send you TestFlight's public join link instead. We usually switch that link on only while someone is waiting for it, and we limit how many people can use it. You then join TestFlight with your own Apple Account, and we give Apple nothing about you; TestFlight doesn't show us who you are. You still need your Hasala invite to create an account.

When you create your Hasala account, we delete your address from the waitlist; your account keeps its own address and the name you give it. If you leave the list or delete your account, we remove you from the TestFlight beta. If you joined with the public link, we can't tell you apart from other link testers, so we close your invite or account instead.

### Bank requests

If you tell us in the app which bank you use and it isn't supported yet, we link the request to your account so we can tell you when your bank works with Hasala. The app shows how the request is going, and we aim to email you when your bank works. It's deleted with your account.

If you connected your email, you can also ask Hasala to look in your mail for banks we're adding. Your iPhone then asks Gmail or Outlook only whether there are recent emails from those banks' addresses. It doesn't download or open them, and the answer stays on your iPhone. Outlook can only be asked about exact alert addresses Hasala already knows, so on Outlook this rarely finds a bank we're adding. If it finds one, it shows you the bank and the address the emails came from (for example bank.example), and only if you choose to send it does it send us that bank and that address with your request. We use the address only to add support for your bank.

On our website, you tell us your bank when you ask for an invite (see [The website](#the-website)). Our server can also count a bank that someone names without asking for an invite. That count holds only the bank's name and when it was sent, with no email address or anything else about the person. We use it to decide which banks to add, and delete it after 365 days.

### Things you send us

| What | Why |
| --- | --- |
| Emails you send to our support, privacy or security addresses | To answer you. |
| Feedback and crash reports you send through TestFlight | Apple passes these to us. If you attach a screenshot, it may show your amounts and merchants, so check it before you send. |

### The website

**Asking for an invite.** When you ask for an invite at hasala.app, we store your email address and a keyed hash of it (so we can spot a second sign-up from the same address), the bank you picked (and the bank name you typed, if you chose "Another bank"), how you reached us (for example, the website's form), how many confirmation emails we sent and when, and the dates you asked, confirmed, were invited and joined, and when your entry last changed. We email you a link to confirm the address, and you join the list only once you confirm it. If you don't confirm it within 7 days of the last confirmation email we sent, we delete it. A confirmed address stays on the list until you join Hasala or leave the list, and for 180 days after you confirmed at most. If we've sent you an invite by then, your entry stays until that invite is used, expires or is withdrawn. We use your address only to send your invite and to tell you when your bank works with Hasala, never for marketing. Every email we send has a link to leave the list. It opens a page where you confirm that you want to leave, and confirming deletes your entry straight away. If you join Hasala, we delete your address from the list straight away, the bank you told us about moves to your account and stays with it until you delete the account, and the rest of the entry is deleted 30 days later. Only we review the list, in an admin tool that is reachable only from our own devices over a private network.

**Bot checks.** Our forms can use Cloudflare Turnstile to tell people from bots. When it's switched on, Cloudflare looks at technical details from your browser, including your IP address, to decide; we receive only the answer.

**Emails we send.** We keep a record of each email we send you: what kind it was, the address, a masked form of it, such as m•••@example.com, and a keyed hash of it, when we sent it and whether it was delivered. We never keep what the email said. These records are deleted after 30 days. If you delete your account, the records linked to it are deleted straight away. Others, such as the email with your invite, lose your address straight away and keep only the masked form and the keyed hash until they're deleted. The record of the email confirming the deletion loses your address as soon as that email has gone, or after 24 hours if it couldn't be sent.

**Cookies and analytics.** The website sets no cookies. It counts visits with Cloudflare Web Analytics, which Cloudflare adds to its pages. Cloudflare says Web Analytics uses no cookies or other storage in your browser, doesn't fingerprint you and doesn't follow you across other sites. We see only totals, such as visits per page, the sites visitors came from, browser and device types, countries and how fast pages load, never linked to you or to your Hasala account. Invite, freeze and waitlist links are not counted: their addresses carry personal codes, so on those pages (hasala.app/i, /freeze and /waitlist) the website's security policy doesn't let Web Analytics run. The Hasala app itself contains no analytics or tracking tools. Elsewhere, the website's security policy lets it run only its own code and Cloudflare's analytics script, plus Cloudflare Turnstile's while bot checks are on. It remembers, in your browser and only for the open tab, that you've already seen the opening animation; that never leaves your browser.

### What we don't collect

- Your bank emails, or any other email in your Gmail or Outlook.
- Your amounts, merchants, categories, budget or plan in readable form.
- Your recovery phrase or encryption keys in readable form, or your Gmail or Outlook access tokens.
- Your contacts, location, photos or browsing activity on other sites.

The app contains no advertising, analytics or crash-reporting tools from other companies.

## How we use your data

We use your data only to:

- provide Hasala: run your account, sign you in, sync your sealed data and wake your iPhone when new mail arrives;
- keep Hasala secure: stop abuse, investigate security problems and alert you to changes on your account;
- send you emails about your account, such as verification, password, security and beta notices;
- answer your messages;
- give you Cloud suggestions, if you turn them on;
- understand how the website is used, in totals (see [Cookies and analytics](#the-website)); and
- meet our legal obligations.

We don't sell your data. We don't use it for advertising. We don't use it to decide whether you get credit or a loan. We don't use it to train AI or machine learning models.

Under the UAE Personal Data Protection Law, we rely on these grounds:

- **Providing the service you asked for.** This covers running your account, sync and push.
- **Your consent.** This covers connecting Gmail or Outlook. You give it in Hasala's email step and on Google's or Microsoft's permission screen, and you can withdraw it at any time. It also covers Cloud suggestions, which you turn on yourself and can turn off at any time.
- **Keeping the service secure.** We have a legitimate interest in stopping abuse and protecting your account and other users' accounts.
- **Understanding how the website is used.** We have a legitimate interest in counting visits to hasala.app, in totals that are never linked to you, to see which pages help people.
- **Complying with the law.**

## Gmail and Google user data

Hasala asks Google for three permissions: `openid` and `email`, which give Hasala your Gmail address so it can match the connection to your account, and `gmail.readonly`, which gives read-only access to your Gmail.

### What Hasala does with it

- Your iPhone, not our server, connects to Gmail.
- Your iPhone asks Gmail only for messages from your banks' alert addresses, so the rest of your inbox is never downloaded. If Gmail's search also returns an email that only looks like it's from your bank, Hasala reads just its sender details on your iPhone and then sets it aside.
- Your iPhone checks each message before it uses it. If Hasala can't be confident that a message really came from your bank, for example because it was forwarded or is in Spam, it waits for you in Review. How Hasala decides may change as we learn how each bank sends its mail.
- If you ask Hasala to look for a bank we're adding (see [Bank requests](#bank-requests)), your iPhone asks Gmail whether there are messages from that bank's addresses. It gets only message IDs back and downloads nothing.
- From each bank alert, your iPhone keeps the amount, merchant, date and card, plus the Gmail message ID so you can open the original email later. These become transactions, which are encrypted on your iPhone before they sync.
- Hasala can't send, delete, label or change your email.
- At the time of writing, Hasala reads alerts from Dubai Islamic Bank (DIB), Emirates NBD and Abu Dhabi Islamic Bank (ADIB).

### Limited Use

Hasala's use and transfer to any other app of information received from Google APIs will adhere to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements.

In practice, for data Hasala receives from your Gmail:

1. **Used only for features you can see.** We use it only to find your bank transactions and show them in Hasala, and to let you open the original alert.
2. **No transfers, except as allowed.** We don't transfer it to anyone, except when needed to provide those features or to comply with the law. If Hasala were part of a merger, acquisition or sale of assets, we would transfer it only with your explicit consent, asked for first. If you turn on Cloud suggestions, a merchant name is sent to Cloudflare's AI service to give you a suggestion, and isn't kept. Otherwise it isn't transferred at all. The raw emails stay on your iPhone, and the details drawn from them leave only as sealed data our server can't open.
3. **No ads.** We never use or transfer it to serve ads, including personalised, retargeted or interest-based ads.
4. **No sales, no credit decisions.** We never sell it, and we never use it to decide whether you get credit or a loan.
5. **No one reads your email.** We don't read it, and the design keeps it out of our reach. The only exception would be if you explicitly agreed to let us look at a specific email, for example to add support for your bank. Even then, you would choose the email and send it to us yourself.
6. **No AI training.** We don't use it to develop, improve or train AI or machine learning models, and [Cloudflare's terms](https://developers.cloudflare.com/workers-ai/platform/data-usage/) say its AI service doesn't either. Hasala's categorisation runs on your iPhone, with your rules, its merchant list and your own earlier picks. Only if you turn on [Cloud suggestions](#cloud-suggestions) does Hasala send a merchant name to Cloudflare's AI service, for one answer, and use Apple's on-device model when Cloudflare can't help.

### Keeping and deleting it

- **Your Gmail access token** is kept in your iPhone's Keychain, on that iPhone only, and is never sent to our server. When you disconnect Gmail, Hasala asks Google to revoke it and deletes it from the Keychain.
- **Your bank alert emails** are never stored by Hasala. Your iPhone reads each one and keeps only the details listed above.
- **Those details** (amount, merchant, date, card and Gmail message ID) are kept in Hasala's encrypted database on your iPhone, protected by iOS data protection, and on our server only in sealed form that we can't open. They stay until you delete them or your account.
- **Your Gmail address** is kept on our server only as a keyed hash, which is deleted when you disconnect Gmail or delete your account (see [Gmail connection](#gmail-connection)).
- **Disconnecting Gmail** stops Hasala reading your mail. Transactions it has already brought in stay in Hasala until you delete them.
- **Deleting your account** erases all of it from our server straight away, and from your iPhones. Encrypted backups that still hold sealed copies expire within 30 days.

### Google's verification screen

During the beta, Google shows a warning that it hasn't verified Hasala. This happens because Google's verification of apps that read Gmail is not yet complete for Hasala.

### Stopping Gmail access

You can disconnect Gmail in Hasala under Profile › Bank alerts. Hasala then asks Google to revoke its access and to stop its new-mail notifications. You can also remove Hasala's access in your Google Account's security settings (at the time of writing, under Security › Your connections to third-party apps and services). Deleting your Hasala account disconnects Gmail too.

## Outlook and Microsoft account data

Hasala works with personal Microsoft accounts, such as outlook.com, hotmail.com and live.com addresses. Work and school accounts aren't supported. You connect one mailbox at a time: connecting Outlook replaces a Gmail connection, and connecting Gmail replaces an Outlook one.

Hasala asks Microsoft for five permissions: `openid`, `email` and `profile`, which give Hasala the email address of your Microsoft account so it can match the connection to your account (`profile` gives your account's sign-in name, which Hasala uses as the address when Microsoft doesn't send one); `offline_access`, which lets Hasala keep checking for new alerts without asking you to sign in each time; and `Mail.Read`, which gives read-only access to your Outlook mail.

### What Hasala does with it

- Your iPhone, not our server, connects to Outlook.
- Your iPhone asks Outlook only for messages from your banks' alert addresses, so the rest of your mailbox is never downloaded. It leaves out anything in Deleted Items, and it checks the sender of each message Outlook lists before it reads any of them.
- If you ask Hasala to look for a bank we're adding (see [Bank requests](#bank-requests)), your iPhone asks Outlook whether there are messages from that bank's alert addresses. Outlook can only be asked about exact addresses Hasala already knows, so this rarely finds a bank we're adding. For each match, Outlook returns its message ID, sender, the time it arrived and its folder. Your iPhone downloads nothing and keeps none of it.
- Your iPhone checks each message before it uses it. If Hasala can't be confident that a message really came from your bank, for example because it's in Junk Email or another folder rather than your Inbox, it waits for you in Review. How Hasala decides may change as we learn how each bank sends its mail.
- From each bank alert, your iPhone keeps the amount, merchant, date and card, plus the Outlook message ID so you can open the original email later. These become transactions, which are encrypted on your iPhone before they sync.
- So that new alerts arrive quickly, your iPhone asks Microsoft to notify our server each time a new message arrives in your Inbox. Our server then wakes your iPhone, and your iPhone checks Outlook itself. The notices carry no content (see [Outlook connection](#outlook-connection)).
- Hasala can't send, delete, move or change your email.

### Our promises for Outlook data

We treat data from your Outlook exactly as we treat data from your Gmail under [Limited Use](#limited-use): we use it only for features you can see, we don't transfer it except as described there, we never use it for ads, sell it or use it for credit decisions, no one reads your email, and we never use it to train AI models.

### Keeping and deleting it

- **Your Outlook access tokens** are kept in your iPhone's Keychain, on that iPhone only, and are never sent to our server. The random code for Microsoft's notices is kept there too.
- **Your bank alert emails** are never stored by Hasala. Your iPhone reads each one and keeps only the details listed above.
- **Those details** (amount, merchant, date, card and Outlook message ID) are kept in the same way as details from Gmail: in Hasala's encrypted database on your iPhone, and on our server only in sealed form that we can't open. They stay until you delete them or your account.
- **Your Outlook address** is kept on our server only as a keyed hash, which is deleted when you disconnect Outlook or delete your account (see [Outlook connection](#outlook-connection)).
- **Disconnecting Outlook** stops Hasala reading your mail. Transactions it has already brought in stay in Hasala until you delete them.

### Stopping Outlook access

You can disconnect Outlook in Hasala under Profile › Bank alerts. Hasala then asks Microsoft to stop its new-mail notifications, and deletes its Outlook tokens from your iPhone. At the time of writing, Microsoft doesn't let an app withdraw its own permission, so to remove Hasala's access at Microsoft as well, go to [account.live.com/consent/Manage](https://account.live.com/consent/Manage), sign in with your Microsoft account and remove Hasala. Deleting your Hasala account disconnects Outlook too.

If your iPhone can't reach Microsoft when you disconnect, the notification setup Microsoft still holds is set to expire within 7 days. Until then, our server ignores its notices and stores nothing from them.

## Encryption in plain words

Your transactions, amounts, merchants, categories, budgets, bills and rules are encrypted on your iPhone before they leave it. Our server can't read them. This is what we mean by end-to-end encrypted: the data is sealed on your iPhone and opened only on your devices, and our server stores and passes along only the sealed copies.

The keys that open your data are created on your iPhone. Your devices hold them, and two things can unlock them on a new device:

- **your passkey**, which you use with Face ID and which syncs through iCloud Keychain; and
- **your 12-word recovery phrase.**

Some things are not sealed. Our server needs your email address, your name and the account details listed above to run your account, so it can read them.

Hasala will never ask for your recovery phrase, your password or a code in an email, a notification, a phone call or on a website. Only type them into the Hasala app.

If you lose your recovery phrase and every passkey, your account can't be recovered. Not even by us.

## Notifications

The beta doesn't show notifications yet. Hasala can ask for your permission now, from **Finish setting up** on Home, so that they work once they arrive. When they do, Hasala will write them on your iPhone. Our server only ever sends a silent signal through Apple to wake the app, and that signal carries no content.

When Hasala asks, you can turn on **Show amounts and merchants**. It's off by default. Today it applies to Hasala's Lock Screen widgets, and we plan for it to apply to notifications once they arrive. If you turn it on, amounts and merchants may appear on your Lock Screen.

## Your profile picture

Hasala shows your picture from Gravatar, a service run by Automattic, if you have one tied to your email address. To do this, your iPhone asks Gravatar for the picture by sending a hash of your email address, a code made from it, and the size it needs. Automattic can see that request and your iPhone's IP address. The request goes straight from your iPhone to Gravatar, not through our server, and we never see it. Like any web request, it also carries a few standard headers, such as a generic browser name that doesn't name Hasala, its version or your iPhone. Hasala sends no cookies with it, and keeps the picture on your iPhone for a short time, up to a day. If you have no Gravatar picture, or your iPhone is offline, Hasala shows your initials instead. A hash isn't a secret: someone who already knows your email address could make the same code and check it. This is on by default, and you can turn it off on each iPhone, under Profile › Privacy › Profile picture from Gravatar. When it's off, Hasala sends nothing to Gravatar, shows your initials, and deletes the pictures it kept on your iPhone.

## Cloud suggestions

Cloud suggestions are off unless you turn them on. You set them on each iPhone, under Profile › Cloud suggestions, or when Review asks you about them. There are two switches, **Merchant suggestions** and **Sort automatically**, and you can turn each on or off at any time.

**How Hasala sorts a payment.** All of this happens on your iPhone, and none of it sends anything off it:

- Hasala first tries your rules, then its merchant list. A payment they can't place waits for you in Review.
- Review shows one card for each payment. A swipe picks the kind of payment, such as Need or Want, and a tap picks the category. If the card has a suggestion, one tap on **Use** takes it.
- If you sorted another payment from the same merchant yourself, Hasala suggests the category you picked most recently. Money that came in from a merchant, such as a refund, has its own pick, and a payment you split isn't a pick.
- When you sort a payment with **Always use it** turned on, Hasala makes a rule for that merchant. The rule also re-files the merchant's other payments, in every month, past and future, except the ones you sorted yourself and a few it leaves alone, such as split payments and transfers.
- You can add a category while you sort, with **New category** at the end of the list. It's one of your own categories, so its name is never sent to Cloudflare.
- An earlier version of Hasala had a **Not this** button. If you used it to tell Hasala a suggestion was wrong, Hasala still remembers that for the merchant and doesn't suggest it again, unless you later sort one of that merchant's payments into it yourself. That choice is sealed and syncs to your other iPhones like your other edits. Nothing about it is sent to Cloudflare: Hasala asks the same question as before and sets the answer you rejected aside on your iPhone.

With Cloud suggestions off, no AI model sorts your payments.

**Merchant suggestions.** When your rules and the merchant list can't place a payment, and you haven't picked a category for that merchant yourself, Hasala asks Cloudflare's AI service to suggest one. If Cloudflare can't help, Hasala asks Apple's on-device model instead, which reads only names written in Latin letters. Apple's model doesn't file a payment by itself. Each request to Cloudflare carries:

- the merchant name from the alert, for example "CAFE EXAMPLE JBR" (Hasala sends it in lower case, and shortens a very long one);
- the built-in Need and Want categories you have on: their names, their IDs and the short built-in descriptions that explain each one; and
- the app's name and version, so that the service can turn away a faulty build.

It doesn't send the amount, the date, your card, your bank, the names of categories you added or renamed, or anything about your account. Hasala sends names only from payments that left your account, and only from bank alerts it read, never from a payment you added yourself. Each merchant is sent on its own. The suggestion is labelled as coming from Cloudflare's AI, and the payment stays in Review until you confirm or change it.

**Working through what's waiting.** With Merchant suggestions on, Hasala works through the merchants waiting in Review by itself. It does this only while the app is open, a few names at a time, within a daily limit on each iPhone. It doesn't do it while Hasala is in the background, and it shows no card or count while it works. It asks about each merchant name once, and keeps the answer on that iPhone for up to 30 days so that it doesn't ask again. Turning off Merchant suggestions stops it at once. In Profile › Cloud suggestions, you can send the payments it sorted on that iPhone back to Review.

**The one-time ask.** When payments wait in Review and Merchant suggestions is off, Review asks you once on each iPhone whether to turn it on. You can answer at any time. **Turn on** turns on both switches. **Not now** leaves both off, and Review doesn't ask again.

**Sort automatically.** If you also turn this on, Hasala files a payment in the suggested category by itself when Cloudflare's AI service is very sure. Those payments don't wait in Review, and they're labelled as sorted by Cloudflare's AI. Home lists what Hasala sorted on its own in the last week, and you can change any of them. If you change two payments it filed in the same category, that iPhone stops filing that category by itself and only suggests it; it keeps this count on that iPhone only, and deletes it when your account's data leaves the iPhone. It sends nothing more than Merchant suggestions does.

**What Cloudflare sees and keeps.** These requests go to a Hasala service on Cloudflare, not to our server. The service passes each one to Cloudflare's AI service through Cloudflare AI Gateway, which lets us cap what we spend. They carry no account, sign-in or device identifier. Like any request over the internet, Cloudflare sees your IP address. The service uses it only to limit how many requests one connection can send: Cloudflare's rate limiter counts requests from each IP address (for IPv6, from its network block) over a short window, about a minute. The service doesn't log or return the address. The service doesn't store or log what you send, and [Cloudflare's terms](https://developers.cloudflare.com/workers-ai/platform/data-usage/) say Cloudflare's AI service doesn't keep it or use it to train its models. We turn AI Gateway's logs and cache off, so it keeps only totals for each model, such as the number of requests, the amount of text processed, the cost and any errors, never the merchant name, the categories or the answer. As for any website it runs, Cloudflare keeps basic records of each request for its own analytics, security and billing, such as the time, the address path, the response code, the country and the model used. These records describe the request, not what it carries, so the merchant name and the category names aren't in them. We never see these requests.

**What we can't hide.** A merchant name can't be linked back to you from our request, but it still says where someone paid. When Hasala works through many waiting merchants, Cloudflare could see that the requests came from the same connection around the same time. If you'd rather nothing about your payments leaves your iPhone, leave Cloud suggestions off; everything else in Hasala works the same.

## Who else handles your data

We use a small number of service providers. None of them can open your sealed data.

| Provider | What they do | What they can see |
| --- | --- | --- |
| **Cloudflare** | Network provider in front of our server, and host of the hasala.app website, where it also counts visits for us with Cloudflare Web Analytics. Encryption in transit ends at Cloudflare, which forwards requests to our server. | The requests between the app and our server, including your IP address, your email address and name when they are sent, and the sealed data. If you use a password, it also sees the scrambled form your iPhone sends when you sign in (see our [Security](/security#what-the-design-doesnt-protect-against) page). It also sees what you send through the website's forms, such as your email address and bank, and, when you visit the website, the pages you open, your IP address and your browser and device type. Web Analytics gives us only totals from these, never linked to you. Cloudflare cannot open the sealed data. |
| **Cloudflare Email Service** | Delivers the emails we send from no-reply@hasala.app. | Your email address and the content of those emails, such as a verification code. |
| **Cloudflare R2** | Stores the off-site copy of our encrypted server backups. | Encrypted backup files only. Cloudflare doesn't hold the key to open them. |
| **Cloudflare Workers AI and AI Gateway** | If you turn on Cloud suggestions: runs the AI model that suggests a category. AI Gateway sits in front of it and caps what we spend. | The merchant name, Hasala's built-in categories, the app's version, and your IP address. No account or device identifier. [Cloudflare's terms](https://developers.cloudflare.com/workers-ai/platform/data-usage/) say the AI service answers and keeps nothing. AI Gateway keeps only totals, such as requests, text processed and cost, with its logs off. |
| **Google** | If you connect Gmail: hosts your Gmail and tells our server when your mailbox changes. | Your mail, as it already does, and that you've given Hasala read-only access. Google also sees your iPhone's IP address when it connects to Gmail. |
| **Microsoft** | If you connect Outlook: hosts your Outlook mailbox and tells our server when a new message arrives in your Inbox. | Your mail, as it already does, and that you've given Hasala read-only access. Microsoft also sees your iPhone's IP address when it connects to Outlook, and our server's notification address. |
| **Gravatar (Automattic)** | Shows your profile picture, if you have one on Gravatar. Your iPhone asks for it directly. Our server is not involved. You can turn this off in Profile, and then nothing is sent. | A code made from your email address (a SHA-256 hash), the size of the picture, your iPhone's IP address, and standard web request headers that don't name Hasala. See [Your profile picture](#your-profile-picture). |
| **Apple** | Distributes the beta through TestFlight and handles your TestFlight invitation, delivers silent push signals, and syncs your passkeys in iCloud Keychain. | When you install and open the beta, crash reports (which don't include your transactions), any feedback you send, and push timing. For an invite: your email address, unless you asked for the public join link. TestFlight doesn't show testers to each other. Apple says it encrypts iCloud Keychain so that Apple itself can't read your passkeys. Your Hasala database is excluded from iCloud backups. |

Emails you send to our @hasala.app addresses (support@, privacy@ and security@) arrive through Cloudflare Email Routing, which forwards them to our email provider (Apple iCloud Mail), where we keep them. Apart from that, we don't use any other service provider that handles your personal data. The waitlist, invites and our admin tool run on our own server. We reach the admin tool from our own devices over Tailscale, a private network that connects them to the server; Tailscale says it carries that traffic encrypted and can't read it.

### Our server

The beta runs on hardware operated by the developer. It sits behind Cloudflare and accepts no connections except through Cloudflare. A small number of trusted people have administrative access to it; because your financial data is [end-to-end encrypted](#encryption-in-plain-words) on your iPhone, they can't read it. Like our server, they can see the account details listed in [What we collect and why](#what-we-collect-and-why), such as your email address and name.

The server's disks aren't encrypted at rest yet. We plan to add this before a public launch.

### Where your data is processed

Our server is located in the United Arab Emirates. Cloudflare, Google, Microsoft, Automattic and Apple operate worldwide, so data they handle may be processed outside the UAE. When personal data leaves the UAE, we rely on the protections in the providers' own data processing terms and on the cross-border transfer rules of the UAE Personal Data Protection Law.

## How long we keep data

| Data | How long |
| --- | --- |
| Your account, sign-in methods, devices and sealed data | Until you delete your account. They are then erased from our server straight away. |
| Security actions (such as "passkey added") | 90 days, or until you delete your account if that's sooner. |
| Encrypted server backups | Made daily and kept for 30 days. After you delete your account, your encrypted data, keys and account details can remain in backups for up to 30 days. |
| Restore records | When you delete your account or leave the waitlist, and after some security changes (such as freezing or unfreezing your account, removing a device or changing your password) and the first time you view your 12 words, our server keeps a short record of random IDs and times (for a removed iPhone, also the signed record of its removal), so that restoring a backup can't undo the change. These records never hold your email address or name. They are kept for 60 days. |
| Sign-in sessions | A session ends after 30 days without use, or after 90 days at most. Its record is removed 30 days after it ends. |
| Push tokens | Removed when you sign out, remove that iPhone, or delete your account. |
| Gmail connection (keyed hash) | Until you disconnect Gmail, connect Outlook instead, remove the iPhone that reads it, or delete your account. Google may keep sending change notices for up to 7 days after that. We ignore them and store nothing from them. |
| Outlook connection (keyed hash and the hash of its notification code) | Until you disconnect Outlook, connect Gmail instead, remove the iPhone that reads it, or delete your account. A subscription Microsoft still holds expires within 7 days. We ignore its notices and store nothing from them. |
| Your old recovery data after you change your recovery phrase | Removed from our server straight away, so the old words stop working with it; may remain in encrypted backups for up to 30 days. Someone who already used the old words keeps what they got with them (see our [Security](/security) page). |
| Invite records | Unused invites expire after 14 days, unless we set a different expiry. 30 days after an invite is used, expires or is withdrawn, its note, address hash and link key are forgotten, and an unused one is deleted. A used invite stays linked to your account until you delete it. |
| Server logs | Our logs never contain your email address, IP address, tokens or sealed data. They hold technical events and error codes. They hold your random account ID when an error or a refused request involves your account, and for some security actions, such as removing a passkey. They have no fixed period: the oldest entries are removed automatically as the log storage fills up. |
| Admin records | A record of what we do in our admin tool, such as sending an invite, kept for 400 days. It refers to people only by internal IDs, never by email address or name. |
| Support emails | We keep them only as long as we need them to help you, and delete them when you ask. |
| Waitlist sign-up, not confirmed | 7 days after the last confirmation email we sent. |
| Waitlist sign-up, confirmed | Until you join, leave the list, or 180 days after you confirmed, whichever comes first. If you have an open invite then, until that invite is used, expires or is withdrawn. |
| Waitlist sign-up, after you join | Your address is deleted straight away. The rest of the entry is deleted 30 days later. |
| Bank counts from people who didn't ask for an invite (only the bank's name and the time) | 365 days, then deleted. They hold nothing about the person who sent them. |
| Bank requests from the app, with the bank's email address if you sent it | Until you delete your account. |
| Email records | 30 days. We never keep what an email said. |
| Upload refusals (the reason and the day) | 90 days. |
| Sign-up, email-code and other sign-in steps | Minutes (see [How you sign in](#how-you-sign-in)). |
| Cloud suggestions requests | Not kept. Our service answers each request and forgets it. Cloudflare's rate limit counts by IP address last about a minute, and AI Gateway keeps only totals. On your iPhone, Hasala keeps each answer for up to 30 days, so that it doesn't ask about the same name twice. |
| Data on your iPhone | Until you delete your account. Signing out keeps your data on the iPhone. Deleting the app removes it from the iPhone. |
| If we reset or end the beta | Accounts and their data are deleted from our server, as when you delete your account. Encrypted backups expire within 30 days. Where we can, we tell you in the app first, so that you can export your data. |

## Deleting your account

You can delete your account in the app under Profile › Delete your account. You'll be asked to confirm it's you. Then:

1. Our server erases your account, sealed data, keys, sign-in methods, devices and mailbox connection straight away.
2. Hasala erases its data on that iPhone. Your other iPhones erase theirs the next time they connect.
3. Hasala then stops your mailbox's new-mail notifications. For Gmail, it also asks Google to revoke its access; for Outlook, it deletes its tokens from your iPhone (see [Stopping Outlook access](#stopping-outlook-access)). Our server no longer has your mailbox connection by then, so it ignores any notice that still arrives.
4. We send you an email to confirm the deletion.

Some things remain for a while afterwards:

- encrypted backups that still contain your data, until they expire within 30 days;
- our records of emails we sent you that weren't linked to your account, such as your invite, with only a masked form and a keyed hash of your address, until they're deleted after 30 days;
- a one-way hash of each sign-in session that was still open, so your other iPhones learn the account is gone and erase their data, until 30 days after that session would have ended (120 days at most);
- the restore record of the deletion, which holds only your random account ID, for 60 days;
- admin records that refer to you by an internal ID only, for up to 400 days;
- Apple's TestFlight record of you, until we remove you from the beta (after that, Apple's own retention applies);
- Cloudflare's own records of delivering our emails, under Cloudflare's retention; and
- if you connected Outlook, Hasala's permission in your Microsoft account until you remove it at [account.live.com/consent/Manage](https://account.live.com/consent/Manage).

Your passkey stays in your passkey manager until you delete it there, for example in the Passwords app. Step-by-step instructions are on our [Support](/support) page.

If you can no longer open the app, email privacy@hasala.app from your account's email address and ask us to delete your account. To make sure the request is really yours, we'll reply to that address and ask you to confirm before we delete anything. We'll also delete your waitlist entry, if you still have one.

## Security

Security is built into how Hasala works:

- Data is sealed on your iPhone with modern authenticated encryption, and the server refuses data that isn't sealed.
- Sign-in with Face ID uses passkeys.
- Sensitive actions ask you to confirm it's you again: connecting or disconnecting your email, adding or removing a passkey, removing a device, viewing or changing your recovery phrase, setting, changing or removing your password, changing your email address, signing out everywhere, freezing or unfreezing your account, and deleting it. Some of these aren't in the beta yet. With a passkey, that's Face ID. If you sign in with a password only, it's your password, entered on an iPhone already added to your account, which also checks your Face ID or passcode. Viewing your recovery phrase, and setting or removing a password, need a passkey.
- A new iPhone joins your account only after you unlock your account on it with your passkey or your 12 words. A password alone can't add one.
- Our server accepts connections only through Cloudflare, and its logs exclude email addresses, IP addresses, tokens and sealed data.
- Backups are encrypted, and the key to open them is not kept on the server.

No system is perfectly secure. Our [Security](/security) page explains the design, its limits and how to report a problem.

## Your rights

Under the UAE Personal Data Protection Law (Federal Decree-Law No. 45 of 2021), you have the right to:

- **Access.** You can ask what personal data we hold about you, why, who we share it with and how long we keep it.
- **Portability.** You can ask for your data in a structured, machine-readable form.
- **Correction.** You can ask us to fix data that is wrong or incomplete.
- **Erasure.** You can ask us to delete your data.
- **Restriction.** You can ask us to limit how we use your data, for example while a dispute is settled.
- **Objection and withdrawal of consent.** You can ask us to stop processing your data, and you can withdraw consent, such as access to your Gmail or Outlook, at any time.
- **Automated decisions.** You can object to decisions based only on automated processing that have legal or similarly significant effects on you. Hasala makes no such decisions about you. Categorisation happens on your own iPhone, or with Cloud suggestions if you turn them on, and you can change any category.

### Because we can't open your data

Because your transactions, budget and plan are sealed, we can't read them, so we can't hand them over in readable form. You can export them yourself from the app as a CSV file, under Profile › Settings › Export your data. What we can give you on request is the account data listed in [What we collect and why](#what-we-collect-and-why).

### How to exercise your rights

Email privacy@hasala.app from the email address on your account. We'll reply as soon as we can, and within the time the law requires. We may ask you to confirm the request in the app, or by replying from that address, so that we know it's you. We don't charge for requests.

If you're not satisfied with our answer, you can complain to the UAE Data Office.

## Children

Hasala is for adults. You must be at least 18 to use it. We don't knowingly collect data from children. If you think a child has created an account, contact us, and if they're under 18 we'll delete it.

## Changes in the beta

Hasala is an experimental beta. Its features, and this policy, can change at short notice. The date at the top shows when the policy last changed. A change takes effect when we post it here.

When a change affects how your data is used, we say what changed in the app or in the TestFlight notes for the new build. If a change needs your consent, we ask for it in the app first. A new optional cloud feature is off until you turn it on: it is explained before you do, this policy describes it from the day it ships, and it affects you only once you turn it on.

If you don't agree with a change, you can stop using Hasala and delete your account at any time (see [Deleting your account](#deleting-your-account)).

## Contact

We can be reached by email only.

- Privacy questions and requests: privacy@hasala.app
- Security reports: security@hasala.app
- Everything else: support@hasala.app, or see our [Support](/support) page.
