/**
 * Build-time settings, baked into the static pages. PUBLIC_API_BASE is the
 * API's base *including* /api, so PUBLIC_API_BASE + "/v1/waitlist" is
 * https://api.hasala.app/api/v1/waitlist (spec 07 §18.6: /api/v1/ is the
 * only prefix the tunnel and the WAF admit).
 */
export const API_BASE = (import.meta.env.PUBLIC_API_BASE || 'https://api.hasala.app/api').replace(/\/+$/, '');
export const TURNSTILE_SITEKEY: string = import.meta.env.PUBLIC_TURNSTILE_SITEKEY || '';
