/**
 * Build-time settings, baked into the static pages. PUBLIC_API_BASE is the
 * API's base *including* /api, so PUBLIC_API_BASE + "/v1/waitlist" is
 * https://api.hasala.app/api/v1/waitlist (/api/v1/ is the only prefix the
 * API's edge admits).
 */
export const API_BASE = (import.meta.env.PUBLIC_API_BASE || 'https://api.hasala.app/api').replace(/\/+$/, '');
export const TURNSTILE_SITEKEY: string = import.meta.env.PUBLIC_TURNSTILE_SITEKEY || '';
