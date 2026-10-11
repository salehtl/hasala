/// <reference lib="webworker" />

/**
 * ledger's service worker.
 *
 * # Why this file exists at all
 *
 * `vite-plugin-pwa` was on `generateSW`, which writes the whole worker from
 * config and cannot carry a hand-written line. A `push` listener is a
 * hand-written line, so the plugin is on `injectManifest` now: the worker below
 * is the real source, and the build's only contribution is substituting
 * `self.__WB_MANIFEST` with the precache list.
 *
 * Everything `generateSW` used to do is therefore done explicitly here —
 * precaching, the navigation fallback to `/index.html`, cleaning up caches from
 * older revisions, and the `SKIP_WAITING` message that `registerType: "prompt"`
 * sends when the user taps Refresh on `PwaUpdatePrompt`'s toast. If any of
 * those is deleted, the app stops working offline; they are not decoration.
 *
 * # The notification text is decided in this bundle, not by the server
 *
 * See `lib/pushNotification.ts`. The push payload is read for nothing.
 *
 * # Typechecking
 *
 * A service worker's globals (`ServiceWorkerGlobalScope`, `ExtendableEvent`,
 * `PushEvent`) live in TypeScript's `webworker` lib, which conflicts with `DOM`
 * — they declare many of the same names differently. So this file is excluded
 * from `tsconfig.json` and checked by `tsconfig.sw.json` instead, and
 * `bun run build` runs both. Do not add it back to the main project's include.
 */

import { cleanupOutdatedCaches, createHandlerBoundToURL, precacheAndRoute } from "workbox-precaching";
import { NavigationRoute, registerRoute } from "workbox-routing";

import { notificationFor, PUSH_TAG } from "./lib/pushNotification";

declare const self: ServiceWorkerGlobalScope;

// The precache manifest, substituted at build time. globPatterns and
// globIgnores in vite.config.ts decide what lands in it — app code, latin
// fonts, and sql.js's wasm, which the browser SqlDriver cannot open a database
// without on a cold offline boot.
precacheAndRoute(self.__WB_MANIFEST);

// Drop precaches from previous revisions. Without it a long-lived install
// accumulates every version of every asset it has ever seen.
cleanupOutdatedCaches();

// Every navigation is served the app shell: this is a single-page app, so
// "/transactions" is not a document the server has, it is a route the bundle
// resolves. `denylist` keeps the API and the plugin's own files out — a
// navigation to /api/v1/... answered with index.html would turn a network
// failure into a silently wrong 200.
//
// `/mailbox-callback.html` is on the denylist for the stronger version of the
// same reason: it is a REAL document, not a client-side route, and it is the
// only thing that carries the Gmail ceremony's claim code back from the consent
// popup (`web/public/mailbox-callback.js`). Answered with the app shell it would
// look fine — a page renders, the window sits there — while the claim is never
// broadcast and every connect attempt dies in its popup-closed fallback. It is
// matched with an anchored pattern that also admits the query string the
// callback always carries.
//
// `/seed/` is on the denylist for the same reason again: `web/harness/play.sh`
// mounts the generated seed CSV beside the app, at `$ORIGIN/seed/`, so a phone
// can download it in Safari. That request is a navigation, not a fetch, so
// without this entry a registered worker answers it with the app shell — the
// page renders and looks fine, but the CSV never downloads and Settings ›
// Import a statement has nothing to import.
registerRoute(
  new NavigationRoute(createHandlerBoundToURL("/index.html"), {
    denylist: [/^\/api\//, /^\/manifest/, /^\/sw\.js$/, /^\/workbox-/, /^\/mailbox-callback\.html/, /^\/seed\//],
  }),
);

/**
 * `registerType: "prompt"` means a new worker waits rather than taking over
 * silently, and `PwaUpdatePrompt` offers a toast. Tapping Refresh calls
 * `updateServiceWorker(true)`, which posts this message. Without the listener
 * the toast's button does nothing and the app never updates.
 */
self.addEventListener("message", (event) => {
  if ((event.data as { type?: string } | undefined)?.type === "SKIP_WAITING") {
    void self.skipWaiting();
  }
});

/**
 * A push arrived. Show a constant.
 *
 * `event.data` is deliberately not read for its contents — see
 * `lib/pushNotification.ts` for why the text is decided in this bundle.
 *
 * `waitUntil` is not optional: without it the browser may terminate the worker
 * before `showNotification` resolves, and a `userVisibleOnly` subscription that
 * receives a push and shows nothing is one the browser eventually revokes.
 */
self.addEventListener("push", (event) => {
  const { title, options } = notificationFor(event.data);
  event.waitUntil(self.registration.showNotification(title, options));
});

/**
 * Tapping the notification.
 *
 * An already-open ledger window is focused rather than a second one opened —
 * two copies of a local-first app in one browser is two sync engines over one
 * database. Only if there is none does this open one.
 */
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const path = (event.notification.data as { path?: string } | undefined)?.path ?? "/";
  event.waitUntil(
    (async () => {
      const clients = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
      for (const client of clients) {
        if (new URL(client.url).origin === self.location.origin) {
          await client.focus();
          return;
        }
      }
      await self.clients.openWindow(path);
    })(),
  );
});

/**
 * The push service told the browser this subscription is finished — usually
 * because it rotated the endpoint. Nothing here re-subscribes: doing so needs
 * the VAPID key and a session bearer token, and a service worker holds
 * neither. `PushNotificationsPanel` re-subscribes on the next app open, which
 * is why it always re-registers rather than trusting what it stored.
 *
 * The stale notification is cleared so the user is not left looking at one that
 * can no longer be delivered to.
 */
self.addEventListener("pushsubscriptionchange", (event) => {
  event.waitUntil(
    (async () => {
      const shown = await self.registration.getNotifications({ tag: PUSH_TAG });
      for (const n of shown) n.close();
    })(),
  );
});
