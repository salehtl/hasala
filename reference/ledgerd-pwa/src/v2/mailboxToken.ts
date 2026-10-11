/**
 * Browser custody of the Gmail OAuth **refresh token**.
 *
 * # Why this is sealed exactly like the ingest key
 *
 * The refresh token is the standing credential to a user's mailbox: with it,
 * anything that runs on this origin can mint access tokens and read mail for as
 * long as the grant lives. So it is held the same way `keys.ts` holds the ingest
 * private key — **sealed under the account's DEK**, a non-extractable AES-GCM
 * `CryptoKey` that JavaScript cannot export, with the account id bound in as
 * associated data. What is written to storage is ciphertext; the plaintext token
 * exists only for the moment {@link openMailboxToken} hands it to a caller, and
 * the intermediate byte buffers are zeroed before this module lets go of them.
 *
 * The threat model is the one `keys.ts` states plainly and does not oversell: a
 * `CryptoKey` cannot be read, but any script on this origin can USE it, so an
 * XSS is a decryption oracle. What the seal does buy is real and is the class of
 * loss a browser actually suffers — a stolen profile directory, an extension
 * reading storage, a devtools heap snapshot and any `JSON.stringify` of app
 * state all yield ciphertext and an account-bound AAD, never the token.
 *
 * # A sibling row, never the account row
 *
 * This lives in the SAME IndexedDB database and object store as the account key
 * vault (`ledger-v2-keys` / `keys`), under its own row key
 * {@link MAILBOX_TOKEN_ROW}. It is a sibling of the `"account"` row, never that
 * row: {@link sealMailboxToken} and {@link deleteMailboxToken} touch only
 * {@link MAILBOX_TOKEN_ROW}, and disconnecting a mailbox therefore removes the
 * token and leaves the account's keys — and everything sealed under them —
 * exactly where they were. `deleteMailboxToken` never calls `clear()`.
 *
 * The sibling-row arrangement has one consequence a consumer must handle: on a
 * shared browser, signing in as a new account overwrites only the `"account"`
 * row, so the previous account's token row is left behind as a residual. The new
 * account's {@link openMailboxToken} THROWS on that residual rather than reading
 * it — see that function's consumer contract, and {@link deleteMailboxToken},
 * which is the sweep the throw path prescribes.
 *
 * The store is a tiny injectable seam for the same reason `keys.ts`'s vault is:
 * jsdom has no IndexedDB, so the unit tests drive a memory-backed store, and the
 * real IndexedDB path is exercised by the connect ceremony in a real browser.
 */

import { webPlatform } from "@ledger/client/platform.web";
import { zero } from "@ledger/client/crypto/keys";

/**
 * What the sealed refresh token is bound to, before the account id is appended.
 *
 * A frozen wire/crypto domain separator once shipped — mirrored byte-for-byte if
 * it is ever reimplemented, exactly like the strings `keys.ts` and `client/src`
 * hold. The trailing byte is a **NUL**, written as the escape `\x00` (never a
 * literal NUL, which git treats as binary and hides from review), so the account
 * id that follows can never be read as part of the label.
 */
export const MAILBOX_TOKEN_AAD = "ledger-v2-mailbox-token\x00"; // + accountId

/** The IndexedDB database and object store — the SAME ones the account key vault uses. */
const KEY_VAULT_DB = "ledger-v2-keys";
const KEY_VAULT_STORE = "keys";

/**
 * The row the sealed token lives in. A sibling of the account vault's `"account"`
 * row, and a storage identity in its own right once shipped: renaming it orphans
 * every connected user's token.
 */
export const MAILBOX_TOKEN_ROW = "mailbox-token";

/** AES-GCM nonce length, in bytes. The one every seal in this codebase uses. */
const IV_BYTES = 12;

/** The sealed token at rest: ciphertext plus the nonce it was sealed with. Nothing else. */
interface StoredToken {
  /** The 12-byte AES-GCM nonce {@link sealed} was sealed with. */
  iv: Uint8Array;
  /** The refresh token's UTF-8 bytes, sealed under the DEK. Ciphertext || 16-byte tag. */
  sealed: Uint8Array;
}

/**
 * The three operations this module needs over the key object store, keyed by row.
 *
 * Deliberately keyed (not hiding the row) so a caller — and a test — can see that
 * only {@link MAILBOX_TOKEN_ROW} is ever written or deleted, and that the account
 * row is never in reach. Three methods, so a test double is honest rather than
 * partial.
 */
export interface KeyStore {
  get(key: string): Promise<unknown>;
  put(key: string, value: unknown): Promise<void>;
  delete(key: string): Promise<void>;
}

/**
 * What the sealed token is bound to: the label, a NUL, then the account id — so a
 * row lifted out of one account's storage and dropped into another's does not
 * open, the same rule `keys.ts` applies to the ingest key, enforced where an
 * attacker who can write IndexedDB cannot edit around it.
 */
function aadFor(accountId: string): Uint8Array {
  return webPlatform.utf8Encode(`${MAILBOX_TOKEN_AAD}${accountId}`);
}

/**
 * Seals the refresh token under `dek`, writes it to the token row, then **reads
 * it back and opens it**, throwing if it does not come back whole.
 *
 * The read-back is a real decrypt, not a shape check — the same discipline
 * `keys.ts`'s `write` uses, and for the same reason: a store that can accept a
 * write and silently lose or truncate it (WebKit has done exactly this to key
 * material) must not be able to look like success, or a device reports a mailbox
 * connected that it can never read a token for.
 *
 * `store` defaults to the browser's IndexedDB-backed store; the connect ceremony
 * and the tests pass their own.
 */
export async function sealMailboxToken(
  dek: CryptoKey,
  accountId: string,
  refreshToken: string,
  store: KeyStore = browserMailboxTokenStore(),
): Promise<void> {
  const plaintext = webPlatform.utf8Encode(refreshToken);
  try {
    const iv = Uint8Array.from(webPlatform.randomBytes(IV_BYTES));
    const sealed = new Uint8Array(
      await subtle().encrypt(
        { name: "AES-GCM", iv: toBuffer(iv), additionalData: toBuffer(aadFor(accountId)) },
        dek,
        toBuffer(plaintext),
      ),
    );
    await store.put(MAILBOX_TOKEN_ROW, { iv, sealed } satisfies StoredToken);

    const back = decodeStored(await store.get(MAILBOX_TOKEN_ROW));
    if (back === null) {
      throw new Error("this browser accepted the mailbox-token write and lost it");
    }
    let readBack: string;
    try {
      readBack = await openStored(dek, accountId, back);
    } catch (err) {
      throw new Error(
        `this browser stored the mailbox token but cannot read it back: ${err instanceof Error ? err.message : String(err)}`,
      );
    }
    if (readBack !== refreshToken) {
      throw new Error("this browser stored the mailbox token and read back a different value");
    }
  } finally {
    // The plaintext token bytes are the only copy this module owns (the caller's
    // `refreshToken` string is immutable and cannot be zeroed); destroy them on
    // every exit so a heap snapshot or a `JSON.stringify` of app state cannot
    // find the token in this frame after it has been sealed.
    zero(plaintext);
  }
}

/**
 * Opens the refresh token for the account it was sealed to.
 *
 * Returns `null` **only** when no token row exists — the ordinary "no mailbox
 * connected" state. It **throws** on any row that is present but does not open:
 * corrupt or tampered ciphertext, or — the expected real-world trigger — a row
 * sealed for a DIFFERENT account. That last case is the **shared-browser
 * account-switch residual**: signing in as account B overwrites only the vault's
 * `"account"` row (see `keys.ts`), so account A's {@link MAILBOX_TOKEN_ROW} is
 * left behind, and B's first open fails because neither B's DEK nor B's accountId
 * AAD can open A's ciphertext. Every failure is one indistinguishable AES-GCM
 * rejection, never a wrong token.
 *
 * **Consumer contract (Task 9/12).** Treat a throw as "no usable token —
 * reconnect, and call {@link deleteMailboxToken} to clear the residual row."
 * Never surface it as an error banner, and never read it as "connected". `null`
 * and a throw both mean "there is no token to use here"; they differ only in
 * whether a stale row must be swept first.
 */
export async function openMailboxToken(
  dek: CryptoKey,
  accountId: string,
  store: KeyStore = browserMailboxTokenStore(),
): Promise<string | null> {
  const row = decodeStored(await store.get(MAILBOX_TOKEN_ROW));
  if (row === null) return null;
  return openStored(dek, accountId, row);
}

/**
 * Decrypts a stored row and returns the token, zeroing the plaintext bytes before
 * it returns. The AES-GCM tag over {@link aadFor} is the account binding: a row
 * sealed for another account, under another DEK, or with a flipped byte all throw
 * here.
 */
async function openStored(dek: CryptoKey, accountId: string, row: StoredToken): Promise<string> {
  const opened = new Uint8Array(
    await subtle().decrypt(
      { name: "AES-GCM", iv: toBuffer(row.iv), additionalData: toBuffer(aadFor(accountId)) },
      dek,
      toBuffer(row.sealed),
    ),
  );
  try {
    return webPlatform.utf8Decode(opened);
  } finally {
    zero(opened);
  }
}

/**
 * Deletes the token row, and **only** the token row.
 *
 * Disconnecting a mailbox is not a sign-out and not a key wipe: the account's
 * keys, and everything sealed under them, are a sibling row that this must never
 * touch. It deletes {@link MAILBOX_TOKEN_ROW} by key — never `clear()`, never the
 * `"account"` row — so the blast radius of a disconnect is exactly this one
 * credential.
 *
 * This is also the residual-row cleanup {@link openMailboxToken}'s throw path
 * prescribes: when a row sealed for a previous account (the shared-browser
 * account-switch residual) throws on open, call this to sweep it before offering
 * to reconnect.
 */
export async function deleteMailboxToken(store: KeyStore = browserMailboxTokenStore()): Promise<void> {
  await store.delete(MAILBOX_TOKEN_ROW);
}

/**
 * Refuses a row that is not a complete sealed token rather than half-reading it.
 *
 * A partial or foreign-shaped row reads as "no token" — which routes the user to
 * reconnect — instead of producing an `AES-GCM` call over `undefined` much
 * further away. The account row shares this store and has a different shape (no
 * `sealed`/`iv` pair of the right lengths), so it decodes to `null` here and is
 * never mistaken for a token.
 */
function decodeStored(v: unknown): StoredToken | null {
  if (typeof v !== "object" || v === null) return null;
  const r = v as Record<string, unknown>;
  if (!(r["iv"] instanceof Uint8Array) || r["iv"].length !== IV_BYTES) return null;
  if (!(r["sealed"] instanceof Uint8Array) || r["sealed"].length === 0) return null;
  return { iv: r["iv"], sealed: r["sealed"] };
}

// ---------------------------------------------------------------------------
// The stores
// ---------------------------------------------------------------------------

/**
 * The real store: the token row of the account key vault's IndexedDB database.
 *
 * The open/transaction machinery mirrors `keys.ts`'s `indexedDbKeyVault`
 * deliberately — same database, same object store, same "resolve on
 * `transaction.oncomplete`, never on `request.onsuccess`" rule, so a write that
 * has not committed is never reported durable. It creates the `keys` store on
 * upgrade the same idempotent way the key vault does, so whichever module opens
 * the database first, the other finds the store it needs.
 */
function indexedDbTokenStore(dbName = KEY_VAULT_DB): KeyStore {
  const open = (): Promise<IDBDatabase> =>
    new Promise((resolve, reject) => {
      const req = indexedDB.open(dbName, 1);
      req.onupgradeneeded = () => {
        if (!req.result.objectStoreNames.contains(KEY_VAULT_STORE)) req.result.createObjectStore(KEY_VAULT_STORE);
      };
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error ?? new Error("indexedDB.open failed"));
      req.onblocked = () => reject(new Error("the key vault is blocked by another tab"));
    });

  const tx = async <T,>(mode: IDBTransactionMode, run: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> => {
    const db = await open();
    try {
      return await new Promise<T>((resolve, reject) => {
        const transaction = db.transaction(KEY_VAULT_STORE, mode);
        let result: T;
        const request = run(transaction.objectStore(KEY_VAULT_STORE));
        request.onsuccess = () => {
          result = request.result;
        };
        request.onerror = () => reject(request.error ?? new Error("key vault request failed"));
        transaction.oncomplete = () => resolve(result);
        transaction.onerror = () => reject(transaction.error ?? new Error("key vault transaction failed"));
        transaction.onabort = () => reject(transaction.error ?? new Error("key vault transaction aborted"));
      });
    } finally {
      db.close();
    }
  };

  return {
    get: (key) => tx<unknown>("readonly", (s) => s.get(key) as IDBRequest<unknown>),
    put: async (key, value) => {
      await tx("readwrite", (s) => s.put(value, key) as IDBRequest<IDBValidKey>);
    },
    delete: async (key) => {
      await tx("readwrite", (s) => s.delete(key) as IDBRequest<undefined>);
    },
  };
}

/**
 * A store that keeps rows in memory for the life of the tab.
 *
 * Not only test scaffolding — `indexedDB` is genuinely absent in Safari private
 * browsing and in a storage-partitioned embed, and the same judgement the key
 * vault makes applies. The backing map is injectable so a test can seed the
 * account row beside the token row and prove a disconnect leaves it standing.
 */
export function memoryKeyStore(backing: Map<string, unknown> = new Map()): KeyStore {
  return {
    get: async (key) => (backing.has(key) ? backing.get(key) : undefined),
    put: async (key, value) => {
      backing.set(key, value);
    },
    delete: async (key) => {
      backing.delete(key);
    },
  };
}

/** The token store this browser can actually use. */
export function browserMailboxTokenStore(dbName = KEY_VAULT_DB): KeyStore {
  return typeof indexedDB === "undefined" ? memoryKeyStore() : indexedDbTokenStore(dbName);
}

// ---------------------------------------------------------------------------
// WebCrypto helpers — the same shapes `keys.ts` uses, for the same reasons.
// ---------------------------------------------------------------------------

function subtle(): SubtleCrypto {
  if (typeof crypto === "undefined" || crypto.subtle === undefined) {
    throw new Error(
      "this browser cannot store the mailbox token safely: crypto.subtle is unavailable, " +
        "which usually means the page is not being served over HTTPS",
    );
  }
  return crypto.subtle;
}

// The typed array, not a detached `ArrayBuffer` — see `platform.aead.ts`'s
// `toBuffer` for why the difference is load bearing under jsdom.
function toBuffer(b: Uint8Array): Uint8Array<ArrayBuffer> {
  return new Uint8Array(b);
}
