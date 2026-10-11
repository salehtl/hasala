/*
 * The Gmail mailbox connect ceremony's popup page (spec §2.1, Task 9).
 *
 * Google redirects the consent popup to `/api/v1/mailbox/oauth/callback`, which
 * 303-redirects here with either `?claim=<code>` (success) or `?error=<kind>`
 * (the ceremony is over — cancelled consent, a dead code, an unknown state).
 * This script hands that outcome to the app that opened the popup and closes.
 *
 * # Why a BroadcastChannel and not window.opener.postMessage
 *
 * The public listener serves `Cross-Origin-Opener-Policy: same-origin`, so a
 * popup returning through accounts.google.com lands in a new browsing-context
 * group with `window.opener` severed. A BroadcastChannel is origin-scoped and
 * survives that switch, so it is the ONLY link back to the opener. COOP is not
 * weakened to make this work — this is the design that needs no weakening.
 *
 * # CSP
 *
 * Loaded as an external self-origin script (`<script src>`), never inline: the
 * page is served under `script-src 'self'`, which forbids an inline script. It
 * imports nothing and talks to no other origin, so `default-src 'self'` holds.
 *
 * The channel name is a wire identity mirrored from mailboxConnect.ts's
 * MAILBOX_CHANNEL — a protected string once shipped (see CLAUDE.md). It is
 * spelled out here rather than imported because a `public/` asset is copied
 * verbatim and never bundled.
 *
 * Written referencing only free globals (location, history, BroadcastChannel,
 * close, URLSearchParams) so mailboxConnect.test.ts can drive this exact file
 * with injected fakes and prove the broadcast and the URL scrub really happen.
 */
(function () {
  var params = new URLSearchParams(location.search);
  var claim = params.get("claim");
  var error = params.get("error");

  // Broadcast first, so the opener learns the outcome even if the URL scrub or
  // the close below is interfered with. A browser without BroadcastChannel
  // leaves the opener to its GET /grant popup-closed fallback rather than
  // throwing here.
  try {
    var channel = new BroadcastChannel("ledger-v2-mailbox-connect");
    channel.postMessage({ claim: claim, error: error });
    channel.close();
  } catch (e) {
    /* no BroadcastChannel: the opener falls back to grant-polling */
  }

  // Scrub the single-use claim (and the error) out of the URL so the code does
  // not linger in session history or leave in a Referer header if this window
  // is not closed. Carry-forward A. Done whether or not close() succeeds.
  try {
    history.replaceState(null, "", location.pathname);
  } catch (e) {
    /* replaceState can throw in exotic embeds; the close below still fires */
  }

  close();
})();
