// @ts-check
import { defineConfig, fontProviders } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import { unified } from '@astrojs/markdown-remark';
import { loadEnv } from 'vite';
import { readdirSync, readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import remarkOwnerNotes from './src/lib/remark-owner-notes.mjs';
import { INLINE_SCRIPTS } from './src/lib/inline-scripts.mjs';
import cspUnion from './src/lib/csp-union.mjs';

// PUBLIC_* values are baked into the static build. .env files are read the
// same way Astro reads them, so the CSP below always matches the page code.
const env = loadEnv(process.env.NODE_ENV ?? 'production', process.cwd(), 'PUBLIC_');
const API_BASE = (env.PUBLIC_API_BASE || 'https://api.hasala.app/api').replace(/\/+$/, '');
const API_ORIGIN = new URL(API_BASE).origin;
const TURNSTILE = Boolean(env.PUBLIC_TURNSTILE_SITEKEY);
const TURNSTILE_ORIGIN = 'https://challenges.cloudflare.com';

// Pages that are not for search engines (they only make sense from an email
// or a form post) stay out of the sitemap; they also carry noindex.
const NOT_IN_SITEMAP = ['/i', '/freeze', '/joined', '/waitlist/confirm', '/waitlist/leave', '/404'];
// Legal pages stay out of the sitemap (and carry noindex) while they are drafts.
try {
  for (const f of readdirSync(new URL('../docs/legal/', import.meta.url))) {
    if (!f.endsWith('.md')) continue;
    const head = readFileSync(new URL(`../docs/legal/${f}`, import.meta.url), 'utf8').split(/^---$/m)[1] ?? '';
    const status = /^status:\s*["']?([\w-]+)/m.exec(head)?.[1] ?? 'draft';
    if (status === 'draft') NOT_IN_SITEMAP.push(`/${f.replace(/\.md$/, '')}`);
  }
} catch {
  // No docs/legal yet: the pages render an empty state and stay out too.
  NOT_IN_SITEMAP.push('/privacy', '/terms', '/security', '/support');
}

export default defineConfig({
  site: 'https://hasala.app',
  output: 'static',
  trailingSlash: 'never',
  build: {
    // /privacy -> privacy.html; Workers Static Assets serves it at /privacy.
    format: 'file',
    // One request less on first paint; every page is small enough.
    inlineStylesheets: 'always',
  },
  compressHTML: true,
  // Shorter selectors than the default attribute strategy; the CSS is inlined.
  scopedStyleStrategy: 'class',
  // The legal Markdown has no code blocks; Shiki's inline styles would also
  // need 'unsafe-inline' under the CSP.
  markdown: { syntaxHighlight: false, processor: unified({ remarkPlugins: [remarkOwnerNotes] }) },
  prefetch: false,
  devToolbar: { enabled: false },
  integrations: [
    sitemap({
      filter: (page) => !NOT_IN_SITEMAP.some((p) => new URL(page).pathname.replace(/\/$/, '') === p),
    }),
    // After the build: every page gets the same CSP, which <ClientRouter /> needs.
    cspUnion(),
  ],
  fonts: [
    {
      name: 'Inter',
      cssVariable: '--font-inter',
      provider: fontProviders.local(),
      fallbacks: ['system-ui', 'sans-serif'],
      display: 'swap',
      options: {
        variants: [
          {
            // Latin subset of the Inter variable font (opsz 14–32, wght 100–900), vendored
            // from @fontsource-variable/inter 5.3.0. OFL: Inter-OFL.txt.
            src: ['./src/assets/fonts/inter-latin-opsz-wght.woff2'],
            weight: '100 900',
            style: 'normal',
          },
        ],
      },
    },
  ],
  security: {
    csp: {
      algorithm: 'SHA-256',
      directives: [
        "default-src 'self'",
        "img-src 'self' data:",
        "font-src 'self'",
        `connect-src 'self' ${API_ORIGIN}${TURNSTILE ? ` ${TURNSTILE_ORIGIN}` : ''}`,
        `form-action 'self' ${API_ORIGIN}`,
        `frame-src ${TURNSTILE ? TURNSTILE_ORIGIN : "'none'"}`,
        "manifest-src 'self'",
        "worker-src 'none'",
        "object-src 'none'",
        "base-uri 'self'",
        'upgrade-insecure-requests',
      ],
      scriptDirective: {
        resources: ["'self'", ...(TURNSTILE ? [TURNSTILE_ORIGIN] : [])],
        // The two <head> scripts in src/lib/inline-scripts.mjs; Astro hashes only bundled ones.
        hashes: INLINE_SCRIPTS.map((s) => /** @type {`sha256-${string}`} */ (`sha256-${createHash('sha256').update(s).digest('base64')}`)),
      },
      styleDirective: {
        resources: ["'self'"],
      },
    },
  },
});
