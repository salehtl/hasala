/**
 * The homepage FAQ (Paper 09 FAQ). The questions and fuller answers are the
 * same as /faq (FAQ in site.ts, which also feeds the FAQPage JSON-LD and
 * llms-full.txt); the homepage only swaps in Paper's own wording for the first
 * answer, which is the one drawn open.
 */
import { FAQ, curly, type FaqItem } from './site';

const OPEN_FIRST: Record<string, string> = {
  'bank-login':
    "No. Hasala only reads the emails your bank already sends you. It can't move money, and it will never ask for your bank password or card number.",
};

const MOBILE_Q: Record<string, string> = { email: 'What can Hasala read in my email?' };
const MOBILE_A: Record<string, string> = {
  'bank-login': "No. Hasala only reads the emails your bank already sends. It can't move money and won't ask for your bank password.",
};

export type HomeFaq = { id: string; q: string; qMobile?: string; mobileFirst?: string; paragraphs: string[]; steps: string[]; more: FaqItem['more'] };

export const HOME_FAQ: readonly HomeFaq[] = FAQ.map((f) => ({
  id: f.id,
  q: f.q,
  qMobile: MOBILE_Q[f.id],
  mobileFirst: MOBILE_A[f.id] ? curly(MOBILE_A[f.id]) : undefined,
  paragraphs: (OPEN_FIRST[f.id] ? [OPEN_FIRST[f.id]] : [f.short, f.a, f.after].filter((p): p is string => !!p)).map(curly),
  steps: (f.steps ?? []).map(curly),
  more: f.more,
}));
