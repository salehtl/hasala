import { BANKS, FAQ, SITE, VISIBILITY } from './site';

const plain = (s: string) => s.replace(/‑/g, '-').replace(/[’]/g, "'");

/** /llms.txt, following the llmstxt.org layout: a title, a summary, then links. */
export function llmsTxt(): string {
  return plain(`# Hasala

> ${SITE.description}

Hasala (Arabic: ${SITE.arabicName}, "piggy bank") has the App Store name "${SITE.appStoreName}" and shows as "Hasala" on the home screen. It is not on the App Store yet: it is in an invite-only beta through TestFlight, in English only, for people in the United Arab Emirates. It is free during the beta.

Key facts:

- Platform: iPhone only, iOS 26 or later. No Android app, no web app.
- Where transactions come from: the bank alert emails in your own Gmail, read-only. Your iPhone asks Gmail only for messages from your bank's alert senders, so the rest of your inbox is never downloaded; if Gmail's search also returns an email that only looks like it is from your bank, the iPhone reads just its sender details and sets it aside. There is no email forwarding and no bank login.
- Banks at launch: ${BANKS.map((b) => b.name).join(' and ')}. Other banks are added by demand.
- Categorization happens on the iPhone: your own rules first, then a built-in list of UAE merchants, then Apple's on-device model (English merchant names), then you review. Nothing is sent to an AI service.
- Privacy: your transactions, budget and plan are end-to-end encrypted on the iPhone before they sync. Hasala's server stores sealed data it cannot open.
- Sign-in: verified email and a display name; Face ID (passkey, recommended) or email and password. A password never unlocks your data: your passkey or your 12-word recovery phrase does. Hasala cannot reset the recovery phrase.
- Price: free during the beta.
- Source code: source-available under the Functional Source License (FSL-1.1-ALv2); each version becomes Apache-2.0 two years after release. The name Hasala and the Slot mark are trademarks not covered by the licence: https://github.com/salehtl/hasala

## Pages

- [Home](${SITE.url}/): what Hasala does, how privacy works, banks, FAQ, and the invite form
- [How privacy works](${SITE.url}/#privacy): who can see what
- [Privacy Policy](${SITE.url}/privacy)
- [Terms of Service](${SITE.url}/terms)
- [Security and disclosure](${SITE.url}/security)
- [Support](${SITE.url}/support)
- [Third-party licences](${SITE.url}/licenses): software the website ships to your browser
- [Request an invite](${SITE.url}/#invite)

## Optional

- [Full text for language models](${SITE.url}/llms-full.txt): everything above plus the FAQ, the "who can see what" table and the legal pages
- Contact: ${SITE.supportEmail} (support), ${SITE.privacyEmail} (privacy), ${SITE.securityEmail} (security)
`);
}

export function llmsFullTxt(legal: { title: string; url: string; body: string }[]): string {
  const who = VISIBILITY.map((v) => `- ${v.who}. Can see: ${v.sees}.${v.never ? ` Cannot see: ${v.never}.` : ''}`).join('\n');
  const faq = FAQ.map((f) => `### ${f.q}\n\n${f.a}`).join('\n\n');
  const docs = legal.length
    ? legal.map((d) => `## ${d.title}\n\nSource: ${d.url}\n\n${d.body.trim()}`).join('\n\n')
    : '## Legal pages\n\nThe Privacy Policy, Terms of Service, Security and Support pages are drafts and not published yet. The privacy model above is how Hasala works today.';
  return plain(`${llmsTxt()}
## How it works

1. Connect Gmail. Sign in with Face ID or a password, then give Hasala read-only access. Your iPhone asks Gmail only for your bank's alerts; your other mail stays in Gmail. Setup takes a few minutes; there is no bank login and nothing to upload.
2. Sorted on your iPhone. Every alert becomes a transaction, categorized on the phone. Correct one once and Hasala remembers the merchant.
3. Sealed, then synced. Your transactions, budget and plan are encrypted on the iPhone with a key only your devices hold before they sync.

Features: one number for what's left for everyday spending this month, with a pace bar; bills set aside first; a swipe deck to sort new transactions into Need, Want, Save or Transfer; a 50/30/20 plan (Needs, Wants, Savings) you can change; recurring bills found automatically, with a nudge on price changes and a heads-up when one is late. Lock-screen notifications are generic by default. Emails come from ${SITE.mailFrom}.

## Who can see what

${who}

Cloudflare is the network provider in front of Hasala's server: it ends transport encryption, so it sees requests and the still-sealed data, but it cannot open the sealed data. Hasala's server also keeps a keyed hash of your Gmail address and the timing of new mail, only to wake your phone.

## FAQ

${faq}

${docs}
`);
}
