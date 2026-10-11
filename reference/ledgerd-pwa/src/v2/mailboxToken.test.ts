/**
 * Sealed custody of the Gmail OAuth refresh token.
 *
 * The refresh token is the standing credential to a user's mailbox, so it is
 * sealed exactly the way the ingest private key is (`keys.ts`): under the
 * account's non-extractable DEK, with the account id bound in as associated
 * data, and it never leaves storage as anything but ciphertext. This suite
 * proves three things the module exists to guarantee:
 *
 *   - a round trip returns the token unchanged, and a fresh store reads `null`;
 *   - the seal is BOUND to its account — opening under a different account id is
 *     a hard failure, not a wrong plaintext (the AAD-binding proof);
 *   - `deleteMailboxToken` removes ONLY the token row. The account key row is a
 *     sibling in the same object store, and disconnect must never take it — so a
 *     real `StoredKeys` account row is seeded alongside and proven to still OPEN
 *     after the token is sealed and deleted.
 */

import { describe, expect, test } from "vitest";
import { generateAccountKeys } from "@ledger/client/crypto/keys";
import { webPlatform } from "@ledger/client/platform.web";
import { installAccountKeys, memoryKeyVault, openIngestPrivate, type StoredKeys } from "./keys";
import {
  deleteMailboxToken,
  MAILBOX_TOKEN_AAD,
  MAILBOX_TOKEN_ROW,
  memoryKeyStore,
  openMailboxToken,
  sealMailboxToken,
} from "./mailboxToken";

const ACCOUNT_A = "11111111-1111-4111-8111-111111111111";
const ACCOUNT_B = "22222222-2222-4222-8222-222222222222";
// A realistic Google refresh token: opaque, starts `1//`, and long.
const REFRESH_TOKEN = "1//0eXaMpLe-refresh-token_9f83aa2c4b7e1d6f0a2b3c4d5e6f7a8b9c0d1e2f";

/** A DEK shaped exactly like the one `installAccountKeys` stores: AES-256-GCM, non-extractable, encrypt/decrypt only. */
async function freshDek(): Promise<CryptoKey> {
  return crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
}

describe("MAILBOX_TOKEN_AAD", () => {
  // The domain separator is a frozen wire/crypto string once shipped, mirrored
  // byte-for-byte if it is ever reimplemented. It ends with a NUL so the account
  // id that follows cannot be confused with the label — and this asserts the NUL
  // is really there, since a literal NUL byte in the source would be invisible to
  // review (the git-binary trap).
  test("is the label plus a NUL separator, and nothing else", () => {
    expect(MAILBOX_TOKEN_AAD).toBe("ledger-v2-mailbox-token\x00");
    expect(MAILBOX_TOKEN_AAD.charCodeAt(MAILBOX_TOKEN_AAD.length - 1)).toBe(0);
    expect(MAILBOX_TOKEN_AAD).not.toContain(ACCOUNT_A);
  });
});

describe("sealMailboxToken / openMailboxToken", () => {
  test("a fresh store has no token", async () => {
    expect(await openMailboxToken(await freshDek(), ACCOUNT_A, memoryKeyStore())).toBeNull();
  });

  test("round-trips the refresh token unchanged", async () => {
    const dek = await freshDek();
    const store = memoryKeyStore();
    await sealMailboxToken(dek, ACCOUNT_A, REFRESH_TOKEN, store);
    expect(await openMailboxToken(dek, ACCOUNT_A, store)).toBe(REFRESH_TOKEN);
  });

  test("the token at rest is ciphertext, never the plaintext token", async () => {
    const dek = await freshDek();
    const backing = new Map<string, unknown>();
    await sealMailboxToken(dek, ACCOUNT_A, REFRESH_TOKEN, memoryKeyStore(backing));
    const row = backing.get(MAILBOX_TOKEN_ROW) as { iv: Uint8Array; sealed: Uint8Array };
    expect(row.iv.length).toBe(12);
    expect(row.sealed.length).toBeGreaterThan(0);
    // The plaintext bytes must not appear anywhere in the stored row.
    const plain = new TextEncoder().encode(REFRESH_TOKEN);
    const hay = new Uint8Array(row.iv.length + row.sealed.length);
    hay.set(row.iv, 0);
    hay.set(row.sealed, row.iv.length);
    expect(indexOfBytes(hay, plain)).toBe(-1);
  });

  test("resealing replaces the previous token rather than accumulating rows", async () => {
    const dek = await freshDek();
    const backing = new Map<string, unknown>();
    const store = memoryKeyStore(backing);
    await sealMailboxToken(dek, ACCOUNT_A, "first", store);
    await sealMailboxToken(dek, ACCOUNT_A, "second", store);
    expect(await openMailboxToken(dek, ACCOUNT_A, store)).toBe("second");
    // One token row, not two.
    expect([...backing.keys()].filter((k) => k === MAILBOX_TOKEN_ROW)).toHaveLength(1);
  });

  // THE AAD-BINDING PROOF. A token sealed for account A must not open under
  // account B. The binding is the associated data, so this bites the moment the
  // AAD stops carrying the account id — flip `aadFor` to drop the id and B opens
  // A's token.
  test("a token sealed for one account does not open under another", async () => {
    const dek = await freshDek();
    const store = memoryKeyStore();
    await sealMailboxToken(dek, ACCOUNT_A, REFRESH_TOKEN, store);
    await expect(openMailboxToken(dek, ACCOUNT_B, store)).rejects.toThrow();
  });

  // A different DEK is the real cross-account case (each account has its own),
  // and it must also be a hard failure, never a wrong plaintext.
  test("a token does not open under a different DEK", async () => {
    const store = memoryKeyStore();
    await sealMailboxToken(await freshDek(), ACCOUNT_A, REFRESH_TOKEN, store);
    await expect(openMailboxToken(await freshDek(), ACCOUNT_A, store)).rejects.toThrow();
  });

  // THE SHARED-BROWSER ACCOUNT-SWITCH RESIDUAL the contract names. Account A
  // connected a mailbox; account B then signed in on the same profile. keys.ts
  // overwrites only the "account" vault row, so A's token row is still here — and
  // B, with BOTH its own DEK and its own accountId, must get a THROW ("no usable
  // token — reconnect and sweep"), never null ("no mailbox connected") and never
  // a wrong token. Pins throw-not-null: make openMailboxToken swallow the decrypt
  // error and return null and this fails.
  test("a residual token from a previous account throws on open, it does not read as null", async () => {
    const backing = new Map<string, unknown>();
    await sealMailboxToken(await freshDek(), ACCOUNT_A, REFRESH_TOKEN, memoryKeyStore(backing));
    // `rejects.toThrow` is the pin: were open to swallow the error and return
    // null (the mutation), a resolved `null` would not reject and this fails.
    await expect(openMailboxToken(await freshDek(), ACCOUNT_B, memoryKeyStore(backing))).rejects.toThrow();
  });

  test("a corrupted ciphertext byte is a rejection, not a wrong token", async () => {
    const dek = await freshDek();
    const backing = new Map<string, unknown>();
    await sealMailboxToken(dek, ACCOUNT_A, REFRESH_TOKEN, memoryKeyStore(backing));
    const row = backing.get(MAILBOX_TOKEN_ROW) as { iv: Uint8Array; sealed: Uint8Array };
    row.sealed[0] = (row.sealed[0]! ^ 0xff) & 0xff;
    await expect(openMailboxToken(dek, ACCOUNT_A, memoryKeyStore(backing))).rejects.toThrow();
  });
});

describe("deleteMailboxToken", () => {
  test("removes the token row", async () => {
    const dek = await freshDek();
    const store = memoryKeyStore();
    await sealMailboxToken(dek, ACCOUNT_A, REFRESH_TOKEN, store);
    await deleteMailboxToken(store);
    expect(await openMailboxToken(dek, ACCOUNT_A, store)).toBeNull();
  });

  // THE ACCOUNT-ROW-SURVIVAL PROOF. The account's key material lives in the
  // "account" row of the SAME object store. Disconnecting a mailbox deletes the
  // token row and nothing else — never `clear()`, never the account row. A real
  // `StoredKeys` row is seeded alongside and proven to still OPEN its ingest key
  // after the token is sealed and deleted. Mutate `deleteMailboxToken` to clear
  // the store or drop the account row and this test fails.
  test("does not disturb the account key row, which still opens afterwards", async () => {
    const backing = new Map<string, unknown>();
    // Seed a genuine account row, exactly as `installAccountKeys` writes one.
    const accountKeys = generateAccountKeys(webPlatform);
    const stored = await installAccountKeys(ACCOUNT_A, accountKeys, memoryKeyVault());
    backing.set("account", stored);

    const store = memoryKeyStore(backing);
    await sealMailboxToken(stored.dek, ACCOUNT_A, REFRESH_TOKEN, store);
    expect(backing.has(MAILBOX_TOKEN_ROW)).toBe(true);

    await deleteMailboxToken(store);

    // The token row is gone; the account row is untouched, byte-for-byte.
    expect(backing.has(MAILBOX_TOKEN_ROW)).toBe(false);
    expect(backing.get("account")).toBe(stored);
    // And it is not merely present — it still OPENS. `openIngestPrivate` decrypts
    // under the stored DEK and imports the key, which is the real proof the row
    // survived intact.
    const account = backing.get("account") as StoredKeys;
    const opened = await openIngestPrivate(account);
    expect(opened.extractable).toBe(false);
  });
});

function indexOfBytes(hay: Uint8Array, needle: Uint8Array): number {
  outer: for (let i = 0; i + needle.length <= hay.length; i++) {
    for (let j = 0; j < needle.length; j++) if (hay[i + j] !== needle[j]) continue outer;
    return i;
  }
  return -1;
}
