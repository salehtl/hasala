/**
 * Build-time settings, baked into the static pages. PUBLIC_API_BASE is the
 * API's base *including* /api, so PUBLIC_API_BASE + "/v1/waitlist" is
 * https://api.hasala.app/api/v1/waitlist (/api/v1/ is the only prefix the
 * API's edge admits).
 */
export const API_BASE = (import.meta.env.PUBLIC_API_BASE || 'https://api.hasala.app/api').replace(/\/+$/, '');

/**
 * How the "Request an invite" form sends what people enter (including the
 * bank they'd like added, as "Another bank"). "email" (the default, until
 * the API is live): nothing is posted and Turnstile is never loaded;
 * submitting opens a pre-filled email to SITE.supportEmail in the visitor's
 * own email app, and the no-JS fallback is /joined, which says to email us.
 * "api": the form posts to API_BASE as before. astro.config.mjs reads the same variable (for the CSP) and fails
 * the build on any other value.
 */
export const WAITLIST_MODE: 'email' | 'api' = import.meta.env.PUBLIC_WAITLIST_MODE === 'api' ? 'api' : 'email';

/** Turnstile runs only in "api" mode: in "email" mode there is nothing to protect. */
export const TURNSTILE_SITEKEY: string = WAITLIST_MODE === 'api' ? import.meta.env.PUBLIC_TURNSTILE_SITEKEY || '' : '';
