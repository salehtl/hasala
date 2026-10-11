/**
 * The state the "Transaction mailbox" settings drill-in renders — derived, once,
 * from two facts and nothing else, so each of the four honest renders is a
 * distinct value the panel switches on rather than a pile of booleans it
 * re-checks (spec §3, "states designed, not bolted on").
 *
 * The two inputs:
 *
 *   - **the grant's status**, from its one authority `GET /api/v1/mailbox/grant`
 *     (`mailboxConnect.grantStatus`): `null` for no grant, `"reconnect_required"`
 *     when Google has stopped honouring the connection, or any other string for a
 *     live grant. The account's fact — every device sees the same answer.
 *   - **whether THIS device holds a usable sealed token** (`hasSealedToken`, the
 *     holder test D9 turns on). A device-local fact: the holder fetches, a
 *     non-holder never does and says the mailbox is read on another device.
 *
 * The mapping, which `settingsState.test.ts` pins whole:
 *
 * | grant status          | holds token | state                |
 * | --------------------- | ----------- | -------------------- |
 * | null                  | *           | `never_connected`    |
 * | "reconnect_required"  | *           | `reconnect_required` |
 * | any other (live)      | yes         | `active`             |
 * | any other (live)      | no          | `another_device`     |
 *
 * `reconnect_required` outranks holdership deliberately: a dead grant is dead for
 * every device, and a holder whose grant Google has dropped needs the reconnect
 * prompt, not the active screen with a "Catch up now" that can only fail.
 *
 * `disconnected` is NOT here: it is the transient the panel shows for the moment
 * after the user taps Disconnect, before the grant re-reads as gone. It is the
 * panel's own post-action state, owned in React, never derived from the server —
 * so this resolver has nothing to say about it and cannot get it wrong.
 */

/** Which of the four derived renders the drill-in shows. See this file's header. */
export type MailboxSettingsState =
  | "never_connected"
  | "active"
  | "another_device"
  | "reconnect_required";

/**
 * The grant status string Google's connection is in, or `null` for no grant —
 * the exact shape `mailboxConnect.grantStatus` returns.
 */
export type GrantStatus = string | null;

/**
 * Resolves the drill-in state from the grant status and this device's holdership.
 *
 * Pure and total: the panel's mount effect reads the grant and the sealed-token
 * presence, hands both here, and switches on the one value. A grant that could
 * not be read is the caller's concern (it renders a read-error state); this
 * function is only reached with a definite `GrantStatus`.
 */
export function mailboxSettingsState(grant: GrantStatus, holdsToken: boolean): MailboxSettingsState {
  if (grant === null) return "never_connected";
  if (grant === "reconnect_required") return "reconnect_required";
  return holdsToken ? "active" : "another_device";
}
