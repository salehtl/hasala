import { BANKS, FAQ, MAIL, SITE, VISIBILITY, faqText } from './site';

const plain = (s: string) => s.replace(/‑/g, '-').replace(/[’]/g, "'");

/** /llms.txt, following the llmstxt.org layout: a title, a summary, then links. */
export function llmsTxt(): string {
  return plain(`# Hasala

> ${SITE.description}

Hasala (Arabic: ${SITE.arabicName}, "piggy bank") has the App Store name "${SITE.appStoreName}" and shows as "Hasala" on the home screen. It is not on the App Store yet: it is in an invite-only beta through TestFlight, in English only, for people in the United Arab Emirates. It is free during the beta.

Key facts:

- What it is for: knowing where your money goes, privately. Hasala shows what you spent, on what, and what's left this month, and starts you on a simple plan.
- Platform: iPhone only, iOS 26 or later. No Android app, no web app.
- Where transactions come from: your bank's alert emails in your own email account (${MAIL} today), read-only. Your iPhone asks your email account only for messages from your bank's alert senders, so the rest of your inbox is never downloaded; the iPhone checks that each email really came from your bank, and sets aside any that only looks like it did. Outlook means personal Microsoft accounts (outlook.com, hotmail.com, live.com); work and school accounts are not supported. One mailbox at a time. There is no email forwarding and no bank login, and Hasala can't move money.
- Banks today: ${BANKS.slice(0, -1).map((b) => b.name).join(', ')} and ${BANKS[BANKS.length - 1].name}. Other banks: people tell us which bank they use when they request an invite, and we use that to decide which bank to add next.
- Categorization happens on the iPhone: your own rules first, then a built-in list of UAE merchants, then Apple's on-device model (English merchant names). You confirm the rest. Nothing is sent to an AI service.
- Privacy: your transactions, budget and plan are encrypted on the iPhone before they sync. Hasala's server stores them but cannot read them. The app contains no ads, analytics or tracking tools. The website, hasala.app, counts visits with Cloudflare Web Analytics (never on invite, freeze or waitlist links), which sets no cookies, doesn't fingerprint or follow visitors across sites, and reports only totals, never linked to a person or a Hasala account.
- Sign-in: verified email and a display name; Face ID (passkey, recommended) or email and password. A password never unlocks your data: your passkey or your 12-word recovery phrase does. Hasala cannot reset the recovery phrase.
- Price: free during the beta. English only, light mode only, for now.
- Source code: source-available under the Functional Source License (FSL-1.1-ALv2); each version becomes Apache-2.0 two years after release. The name Hasala and the Slot mark are trademarks not covered by the licence: https://github.com/salehtl/hasala

## Pages

- [Home](${SITE.url}/): what Hasala is, how it works in three steps, privacy in three points, the banks, and the invite form
- [How it works](${SITE.url}/how-it-works): connecting your email, supported banks and alerts, how sorting works, reviewing new transactions, signing in
- [Budgeting](${SITE.url}/budgeting): what's left this month and the 50/30/20 starting plan
- [How privacy works](${SITE.url}/how-privacy-works): where your data goes, who can see what, a new or lost phone
- [FAQ](${SITE.url}/faq)
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
  const faq = FAQ.map((f) => `### ${f.q}\n\n${faqText(f)}`).join('\n\n');
  const docs = legal.length
    ? legal.map((d) => `## ${d.title}\n\nSource: ${d.url}\n\n${d.body.trim()}`).join('\n\n')
    : '## Legal pages\n\nThe Privacy Policy, Terms of Service, Security and Support pages are drafts and not published yet. The privacy model above is how Hasala works today.';
  return plain(`${llmsTxt()}
## How it works

1. Connect your email. Hasala looks only at your bank's alert emails, on your iPhone, with read-only access. It can't send, change or delete any mail.
2. Check the categories. Each alert becomes a transaction. Hasala sorts most of them into categories: your rules first, then a UAE merchant list, then Apple's on-device model. You confirm the rest: transactions Hasala can't sort on its own wait in a short deck, where you tap Use to take its guess, or swipe to Want, Need, Save or Transfer and then pick the category. Hasala remembers the merchant.
3. See where it went. Hasala shows what you spent, on what, and what's left this month. It also starts you on a simple plan.

Budgeting: the main figure is what you've spent on needs and wants this month, out of what your plan allows for them (for example AED 10,288.34 spent of 19,000), with a bar for how fast you're spending it and how much is left (AED 8,711.66). Bills this month are listed with each bill's amount and whether it is paid. The starting plan is 50/30/20 (Needs, Wants, Savings), and you can change it. Lock-screen notifications are generic by default. Emails come from ${SITE.mailFrom}.

## Who can see what

${who}

Cloudflare is the network provider in front of Hasala's server: it ends transport encryption, so it sees requests and the still-encrypted data, but it cannot read the encrypted data. Hasala's server also keeps a keyed hash of the email address you connect and the timing of new mail, only to wake your phone. For Outlook, Microsoft's new-mail notices carry a random code instead of the address; the server keeps only a hash of that code and discards the rest of each notice unread.

## FAQ

${faq}

${docs}
`);
}
