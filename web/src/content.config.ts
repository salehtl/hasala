import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';
import { z } from 'astro/zod';

/**
 * Legal and help pages. The Markdown lives outside the web package, in
 * docs/legal/ at the repo root, and is written by the people who own the
 * wording. The site only renders it: privacy.md -> /privacy, terms.md ->
 * /terms, security.md -> /security, support.md -> /support.
 *
 * The schema is lenient on purpose so a new field in the Markdown never
 * breaks the build; unknown keys pass through.
 */
const legal = defineCollection({
  loader: glob({ pattern: '*.md', base: '../docs/legal' }),
  schema: z
    .object({
      title: z.string(),
      description: z.string().optional(),
      standfirst: z.string().optional(),
      /** "In plain words": a string for the document, or one per section (keyed by heading slug). */
      plainWords: z.union([z.string(), z.record(z.string(), z.string())]).optional(),
      status: z.string().default('draft'),
      /** Shown in the draft banner while status is "draft". */
      draftNote: z.string().optional(),
      version: z.union([z.string(), z.number()]).optional(),
      updated: z.coerce.date().optional(),
      lastUpdated: z.coerce.date().optional(),
      effective: z.coerce.date().optional(),
      contact: z.string().optional(),
    })
    .loose(),
});

export const collections = { legal };
