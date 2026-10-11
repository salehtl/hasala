---
title: "Security"
description: "How Hasala protects your data, what its design can and can't defend against, and how to report a security problem to security@hasala.app."
lastUpdated: 2026-10-11
status: "final"
plainWords: "Hasala reads your bank alerts and seals your money data on your iPhone, so our server stores only data it can't open. Your recovery phrase and passkey are what unlock it. If you find a security problem, email security@hasala.app. We won't take legal action against good-faith research that follows this policy."
---

## How Hasala keeps your data safe

This is a plain summary of Hasala's security design during the beta. It describes what the design protects, and also what it doesn't.

### Bank emails are read on your iPhone

Hasala connects to your Gmail with read-only access, from your iPhone. Your iPhone asks Gmail only for messages from your banks' alert addresses, so the rest of your inbox is never downloaded. If Gmail's search also returns an email that only looks like it's from your bank, Hasala reads just its sender details on your iPhone and then sets it aside. The access token lives in your iPhone's Keychain and is never sent to our server. Raw bank emails are not stored in your Hasala data and are never sent to us.

### Sorting happens on your iPhone

Hasala sorts transactions in this order:

1. your own rules;
2. a built-in list of UAE merchants;
3. Apple's on-device model, for merchant names written in English; and
4. if it's still unsure, your review.

Today, nothing is sent to an AI service. Any future AI-powered feature will be optional, off by default and explained before you turn it on.

### Your data is sealed before it syncs

Your transactions, amounts, merchants, categories, budgets, bills and rules are encrypted on your iPhone before they leave it. Our server can't read them. In other words, they're end-to-end encrypted: each change is sealed on your iPhone with authenticated encryption, and only your devices hold the keys.

- The server checks that every upload is sealed and refuses anything that isn't.
- Each change is chained to the one before it. Your devices can tell if a sealed change was altered, moved or inserted by someone without your keys. If that happens, they set it aside and warn you.
- The keys are created on your iPhone and kept in its Keychain, on that device only. They aren't included in iCloud or computer backups. Our server keeps only sealed copies, which your passkey or your recovery phrase opens.

Some data is not sealed. Our server can read your email address and name, and the account details listed in our [Privacy Policy](/privacy#what-we-collect-and-why).

### Signing in and unlocking are separate

- **Signing in** proves who you are to our server. You can use Face ID with a passkey (recommended) or your email and password.
- **Unlocking** opens your sealed data on a device. Only two things can do that: your passkey, or your 12-word recovery phrase.

A password never unlocks data. If you sign in with a password on a new iPhone, Hasala asks for your 12 words to unlock your data.

Your recovery phrase is made on your iPhone. Our server keeps a sealed copy it can't open, so that if you have a passkey you can view your 12 words again in Hasala, after Face ID. We email you each time they're shown. If you sign in with a password only, they can't be shown again. A password reset needs your 12 words or an iPhone that's already signed in. We can't reset your recovery phrase, and we can't unlock your data for you.

### Sensitive actions need a fresh check

Some actions need you to confirm it's you again, and they are tied to that exact action. These are connecting Gmail, adding or removing a passkey or device, viewing or changing your recovery phrase, signing out everywhere, and deleting your account. With a passkey, the check is Face ID. If you sign in with a password only, it's your password, entered on an iPhone already added to your account, which also checks your Face ID or passcode; a password alone, or a code from your email alone, is never enough. When a device or passkey is added or removed, your other iPhones show a security notification.

### Freezing your account

When someone signs in to your account on a new device, uses your recovery phrase, or views your recovery phrase in the app, we email you. If it wasn't you, the **Freeze my account** link in that email signs everyone out. No one can then use your account with a password, reset the password or use the recovery phrase until you confirm it's you with a passkey, or with your password on one of your iPhones. You can also freeze your account yourself in the app, under Profile › Sign-in & security. Freezing deletes nothing, and the freeze page never asks for a password, a code or your 12 words.

### Push signals carry no content

Our server wakes Hasala on your iPhone with a silent, empty signal through Apple. Notifications are written on your iPhone. By default they don't show amounts or merchants on the Lock Screen.

### The server and its network

- During the beta, our server is a computer run by the developer. It accepts no direct connections from the internet. Cloudflare is the network provider in front of it and forwards requests to it through an outbound-only tunnel.
- Encryption in transit ends at Cloudflare. Cloudflare can see requests and the sealed data, but it can't open the sealed data.
- The server's logs don't record email addresses, IP addresses, tokens or request contents.
- The database accepts only local connections. The service runs with the minimum permissions it needs.
- Backups are encrypted, and the keys to open them are not kept on the server. Backups are kept for 30 days.
- Administration happens only over a private, authenticated connection. Our admin tool for the waitlist and invites is reachable only from our own devices over a private network, never from the internet.

## What the design doesn't protect against

No design is perfect. These are the limits we know about and accept during the beta.

- **Metadata.** Our server and Cloudflare can see when you sync, roughly how much data you store, your IP address, and when something changes in your Gmail. Because your iPhone uploads soon after a bank alert arrives, they can also tell roughly when, and how often, you get bank alerts. They can't see what the mail says or what your transactions are.
- **Your Gmail address.** Google sends it to our server each time something changes in your Gmail. We keep only a keyed hash of it, but the server sees it briefly.
- **Your recovery phrase is your account.** Anyone who has your 12 words and can sign in, or can get a code from your email, can read your data and add devices. Making a new phrase stops the old words from working with our server (our encrypted backups keep the old recovery data for up to 30 days), but it can't take back what someone already got with them. If you think someone has seen your words, the fix is to create a new account.
- **Your Apple Account.** Your passkey syncs through iCloud Keychain. Someone who can sign in to your Apple Account and knows one of your device passcodes can get into Hasala as you. Keep two-factor authentication on.
- **An unlocked iPhone.** Anyone who can unlock your iPhone can open Hasala. Face ID lock hides Hasala until you unlock it. It doesn't change how your data is encrypted.
- **A compromised server.** A server we no longer control can't read your sealed data. But it could stop or delay sync, or send fake notification text. That is why Hasala will never ask for your recovery phrase, your password or a code in a notification, an email, a phone call or on a website.
- **Your password.** If you use one, your iPhone sends our server a scrambled form of it, never the password itself. Our server and Cloudflare see that scrambled form when you sign in. Someone holding it could sign in as you, though never unlock your data, or try to guess your password from it, which is slow by design. A passkey avoids this, which is why we recommend one.
- **The beta server itself.** The beta runs on hardware operated by the developer. A small number of trusted people have administrative access to it; because your financial data is end-to-end encrypted on your iPhone, they can't read it. What's stored there is sealed data plus the account details in our [Privacy Policy](/privacy#what-we-collect-and-why), which they can see. Encryption of the server's disks at rest is being added before the public launch.

## Reporting a vulnerability

If you think you've found a security problem in Hasala, please tell us. We appreciate it.

### How to report

Email **security@hasala.app** with:

- what you found and where;
- steps to reproduce it, or a proof of concept;
- what an attacker could do with it; and
- how you'd like to be credited, if at all.

If your report contains something sensitive, such as a working exploit, you can say so in a first email without the details, and we'll agree with you how to send them.

Please don't put details of an unfixed vulnerability in TestFlight feedback, public issues or social media.

### What to expect

- We'll confirm we received your report.
- We'll keep you updated while we investigate and fix it.
- We'll fix serious issues as quickly as we can and agree a disclosure date with you.
- With your permission, we'll credit you once the issue is fixed.

There is no paid bug bounty during the beta.

## Scope

### In scope

- The Hasala iPhone app (TestFlight beta builds).
- Our API at api.hasala.app.
- The website at hasala.app, including the invite links and the files that let the app sign in with passkeys.
- Hasala's source code at [github.com/salehtl/hasala](https://github.com/salehtl/hasala).
- Design problems, such as a way for our server, Cloudflare or another party to read or change sealed data, or to sign in without your passkey, password or recovery phrase.

### Out of scope

- Services run by Cloudflare, Google or Apple. Please report problems with those to them.
- Attacks that need physical access to an unlocked iPhone, or a jailbroken iPhone, unless they break a protection we describe above.
- Limits already listed in [What the design doesn't protect against](#what-the-design-doesnt-protect-against), unless you find a way to make them worse.
- Denial of service, load testing or spam.
- Social engineering or phishing of testers, the developer or providers.
- Physical attacks on our server or its location.
- Missing security headers, email-authentication settings or best-practice issues with no clear way to exploit them.
- Reports produced only by automated scanners, without a working proof.

## Safe harbour

If you act in good faith and follow this policy, we will:

- consider your research authorised;
- not take legal action against you, or report you to law enforcement, for it; and
- work with you to understand and fix the problem.

Acting in good faith means that you:

- only test against your own account, or accounts you have permission to use;
- don't access, change or delete other people's data. If you reach someone else's data by accident, stop, don't keep it, and tell us;
- don't disrupt the service or degrade it for others;
- don't use or share what you find beyond what's needed to show the problem; and
- give us reasonable time to fix the issue before telling anyone else.

This safe harbour covers only claims we control. It can't bind Cloudflare, Google, Apple or any authority.

## Contact

- Security reports: security@hasala.app
- Privacy questions: see our [Privacy Policy](/privacy#contact)
