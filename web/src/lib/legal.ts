import { getCollection, type CollectionEntry } from 'astro:content';

/** The four pages rendered from docs/legal/*.md, in footer order. */
export const LEGAL_PAGES = [
  { slug: 'privacy', label: 'Privacy Policy', fallbackTitle: 'Privacy Policy', fallbackDescription: 'What stays on your iPhone, what our server keeps sealed, and the few things it can see.' },
  { slug: 'terms', label: 'Terms of Service', fallbackTitle: 'Terms of Service', fallbackDescription: 'The terms for using Hasala during the TestFlight beta.' },
  { slug: 'security', label: 'Security and disclosure', fallbackTitle: 'Security', fallbackDescription: 'How Hasala protects your data, and how to report a security issue.' },
  { slug: 'support', label: 'Support', fallbackTitle: 'Support', fallbackDescription: 'Help with Hasala: getting started, your bank alerts, your 12 words, and how to reach us.' },
] as const;
export type LegalSlug = (typeof LEGAL_PAGES)[number]['slug'];

export async function legalEntry(slug: LegalSlug): Promise<CollectionEntry<'legal'> | undefined> {
  const all = await getCollection('legal');
  return all.find((e) => e.id === slug || e.id.replace(/\.md$/, '') === slug || e.id.endsWith(`/${slug}`));
}

export async function legalForLlms() {
  const out: { title: string; url: string; body: string }[] = [];
  for (const p of LEGAL_PAGES) {
    const e = await legalEntry(p.slug);
    // Drafts (with notes for the owner still in them) stay out until published.
    if (e?.body && e.data.status !== 'draft') out.push({ title: e.data.title, url: `https://hasala.app/${p.slug}`, body: e.body });
  }
  return out;
}
