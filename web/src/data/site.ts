/**
 * One place for the facts the site states about Hasala. The landing page,
 * the JSON-LD, /llms.txt and /llms-full.txt all read from here, so a claim
 * changes in one place. Keep every line true to the product as shipped.
 */

export const SITE = {
  name: 'Hasala',
  arabicName: 'حصّالة',
  appStoreName: 'Hasala Budgeting',
  url: 'https://hasala.app',
  tagline: "Know what's left. Keep it to yourself.",
  description:
    'Hasala is a private budgeting app for iPhone in the UAE. It reads your bank alert emails on your iPhone, sorts every dirham there, sets bills aside, and syncs your budget end-to-end encrypted. Invite-only beta on TestFlight.',
  shortDescription: 'A private budget for life in the UAE. Every dirham in its place, and only you can read your budget.',
  supportEmail: 'support@hasala.app',
  privacyEmail: 'privacy@hasala.app',
  securityEmail: 'security@hasala.app',
  mailFrom: 'no-reply@hasala.app',
  themeColor: '#E6EEFF',
  ogImage: '/og-image.png',
  ogImageAlt:
    "Hasala: Know what's left. Keep it to yourself. A gold dirham coin dropping into a slot on a blue background. Private beta, iPhone, UAE.",
  testFlightAppStore: 'https://apps.apple.com/app/testflight/id899247664',
  requirements: ['iPhone with iOS 26 or later', 'A Gmail address that gets your bank alerts', 'English for now. Expect a few rough edges'],
} as const;

export const BANKS = [
  { value: 'dib', name: 'Dubai Islamic Bank', short: 'DIB' },
  { value: 'enbd', name: 'Emirates NBD', short: 'ENBD' },
] as const;

/**
 * Banks people can ask for in the "Bank with someone else?" tile. The values
 * are the server's catalog slugs (spec 07 §2.2, §18.6); any other bank is
 * "Another bank" with its name typed in. The names are the catalog's own, so
 * one carried into the invite form as "Another bank" matches its aliases.
 */
export const OTHER_BANKS = [
  { value: 'adcb', name: 'ADCB' },
  { value: 'emirates-islamic', name: 'Emirates Islamic' },
  { value: 'fab', name: 'First Abu Dhabi Bank' },
  { value: 'liv', name: 'Liv' },
  { value: 'mashreq', name: 'Mashreq' },
  { value: 'rakbank', name: 'RAKBANK' },
  { value: 'wio', name: 'Wio' },
] as const;

export const NAV = [
  { href: '/#how-it-works', label: 'How it works', id: 'how-it-works' },
  { href: '/#privacy', label: 'Privacy', id: 'privacy' },
  { href: '/#banks', label: 'Banks', id: 'banks' },
  { href: '/#faq', label: 'FAQ', id: 'faq' },
] as const;

export const FOOTER = [
  {
    title: 'Hasala',
    links: [
      { href: '/#how-it-works', label: 'How it works' },
      { href: '/#privacy', label: 'How privacy works' },
      { href: '/#banks', label: 'Banks' },
      { href: '/#invite', label: 'Request an invite' },
    ],
  },
  {
    title: 'Help',
    links: [
      { href: '/support', label: 'Support' },
      { href: '/security', label: 'Security' },
      { href: 'mailto:support@hasala.app', label: 'Contact' },
    ],
  },
  {
    title: 'Legal',
    links: [
      { href: '/privacy', label: 'Privacy Policy' },
      { href: '/terms', label: 'Terms of Service' },
    ],
  },
] as const;

/** Who can see what. Mirrors the privacy section and the privacy policy. */
export const VISIBILITY = [
  { who: 'You', sees: 'Everything, on your own devices', never: null },
  {
    who: 'Hasala, our server',
    sees: "Your email address and name, that your account exists, the public parts of your sign-in methods (your passkey's public key, or a hash of a password it never sees), your devices' push tokens, when you sync and how much sealed data you keep, and a keyed hash of your Gmail address with when new mail arrives",
    never: 'Your emails, amounts, merchants, categories, budget or plan',
  },
  {
    who: 'Cloudflare, our network provider',
    sees: 'Your requests on their way to our server, once transport encryption ends: IP address, times, sizes and the still‑sealed data. It also sends our emails to you',
    never: "What's inside the sealed data",
  },
  {
    who: 'Google',
    sees: "Your email, as it already does, and that you've given Hasala read‑only access",
    never: 'Your budget, or anything Hasala works out',
  },
  {
    who: 'Apple',
    sees: "Your email address, because it handles your TestFlight invitation, and that you've installed Hasala. If you use a passkey, it syncs in iCloud Keychain, end‑to‑end encrypted by Apple",
    never: 'Your transactions or your plan',
  },
] as const;

export const FAQ = [
  {
    q: 'Do you need my bank login?',
    a: "Never. Hasala reads the alert emails your bank already sends you. It can't move money, and it will never ask for a banking password or card number.",
  },
  {
    q: 'What exactly can Hasala read in my Gmail?',
    a: "You give Hasala read‑only access. Your iPhone asks Gmail only for messages from your bank's alert senders and reads those on the phone, so the rest of your inbox, subject lines and senders included, is never downloaded. Hasala can't send, change or delete mail, and nothing is sent to an AI service.",
  },
  {
    q: 'What if I lose my phone?',
    a: "Your budget is sealed with a key only your devices hold. On a new iPhone you unlock it with your passkey, which syncs in iCloud Keychain, or with your 12‑word recovery phrase. A password signs you in but never unlocks your data. Keep the 12 words somewhere safe: we can't reset them for you.",
  },
  {
    q: 'Is it free?',
    a: 'Yes. Hasala is free during the beta.',
  },
  {
    q: 'Why only iPhone, and only English?',
    a: "Hasala does its work on the phone itself, and sorting uses Apple's on‑device model, which reads English merchant names. Starting with one platform and one language lets us get every bank alert right before we promise more.",
  },
  {
    q: 'How do I delete my account and data?',
    a: 'In Hasala, open Profile, then Delete your account. That removes your account and the sealed data our server keeps. To leave the waitlist instead, use the link in any email we sent you, or write to support@hasala.app.',
  },
  {
    q: 'How does the TestFlight beta work?',
    a: "TestFlight is Apple's free app for trying beta apps. Ask for an invite here, then tap Confirm my email in the email we send. When there's room, we email your invite from no-reply@hasala.app. Install TestFlight, accept Apple's TestFlight invitation from its email or the link in your invite, install Hasala, then open it and enter your invite code. Apple handles the invitation, so it sees your email address and that you installed Hasala; other testers never see you. New versions reach you in TestFlight after Apple's beta review, which usually takes about a day. You need an iPhone with iOS 26 or later and a Gmail address that gets your bank alerts.",
  },
] as const;
