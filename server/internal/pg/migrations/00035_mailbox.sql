-- +goose Up

-- The Gmail transaction mailbox (spec D2/D3): a user connects a Gmail account
-- through Google's OAuth consent screen instead of forwarding bank mail by
-- hand, and the server polls that mailbox on their behalf.
--
-- # What is stored, and what is not
--
-- mailbox_grants.refresh_token_hash and mailbox_oauth_states.state_hash are
-- both SHA-256 digests, on the same terms as `sessions.token_hash` (00001) and
-- `invite_codes.code_hash` (00020): the live secret — Google's refresh token,
-- the CSRF state token handed to the browser — is never written here, so a
-- database backup, a log line or a replica leaks a set of digests and yields
-- no mailbox credential and no live OAuth state. Both secrets are minted from
-- crypto/rand-grade sources with no attacker-chosen structure, which is what
-- makes an unsalted digest sound rather than a dictionary-attack surface the
-- way a password hash would be — the same argument 00020's header makes for
-- invite codes.
--
-- refresh_token_hash is the credential a compromised database would want
-- most: it is what internal/mailbox polls Gmail with on the user's behalf, so
-- unlike a session token (bounded TTL) it is close to permanent until the
-- user revokes access at Google or reconnects. Digest-only storage is why a
-- dump of this table cannot be replayed against Google.
--
-- # mailbox_grants
--
-- One row per (user, provider): the polling credential and its health.
-- `status` flips to 'reconnect_required' when Google reports the refresh
-- token dead (revoked at Google, or expired from disuse) — internal/mailbox
-- sets it rather than deleting the row, because the user's sender allowlist
-- in mailbox_senders should not be lost just because the token needs
-- refreshing through the consent screen again. UNIQUE (user_id, provider)
-- is what makes a reconnect an UPSERT: Task 3's Grants.Upsert rotates
-- refresh_token_hash and resets status to 'active' in place, which is D9's
-- holdership rotation — the old digest stops verifying the moment the new
-- one is written, in the same statement, so there is no window where both
-- work.
--
-- # mailbox_senders
--
-- The per-user allowlist of bank domains this mailbox may source transaction
-- mail from: a bare (user_id, domain) pair with no surrogate key, because
-- nothing ever needs to name one row independently of that pair — adding a
-- domain is an INSERT, removing one is a DELETE keyed on the same two
-- columns.
--
-- # mailbox_oauth_states
--
-- The CSRF-state row for one in-flight OAuth ceremony, the same single-use
-- shape as `webauthn_ceremonies` (00025) — NOT `writer_challenges` (00003),
-- which marks a spent row with `used_at` rather than deleting it.
-- webauthn_ceremonies is the delete-on-consume precedent: Passkeys.claimCeremony
-- (internal/auth/passkey_store.go) spends a row with `DELETE ... RETURNING`,
-- and Task 3's States.Claim does the same thing here, so a row that exists is
-- a ceremony not yet spent and a replay of the same state matches nothing.
-- There is deliberately no "used" column, for the same reason
-- webauthn_ceremonies has none rather than the reason writer_challenges does
-- (it has one).
--
-- pkce_verifier is stored in the clear, deliberately, not as a digest: it is
-- 5-minute single-use ceremony state, the same class of row as
-- webauthn_ceremonies.session_data (also plaintext JSONB) rather than a
-- standing credential like refresh_token_hash above — and a digest cannot
-- substitute here regardless, because the literal verifier has to be replayed
-- to Google at the token-exchange request that consumes this row, not merely
-- compared against.
CREATE TABLE mailbox_grants (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider      text NOT NULL CHECK (provider IN ('gmail')),
    status        text NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active','reconnect_required')),
    refresh_token_hash bytea NOT NULL,  -- sha256 of the refresh token; never the token
    created_at    timestamptz NOT NULL DEFAULT now(),
    last_broker_at timestamptz,
    UNIQUE (user_id, provider)
);

CREATE TABLE mailbox_senders (
    user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    domain     text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, domain)
);

CREATE TABLE mailbox_oauth_states (
    state_hash    bytea PRIMARY KEY,          -- sha256 of the state token; never the token
    user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    pkce_verifier text NOT NULL,
    expires_at    timestamptz NOT NULL
);

-- Matches webauthn_ceremonies_expiry_idx (00025) and writer_challenges_expiry_idx
-- (00003): both single-use-ceremony precedents index expires_at for their
-- opportunistic sweep. Task 4 wires the sweep itself (deliberately deferred,
-- per the plan); the index is added now so that later sweep is not the thing
-- that first notices this table has none.
CREATE INDEX mailbox_oauth_states_expiry_idx ON mailbox_oauth_states (expires_at);

-- DEPLOYMENT: the two-role split (00003_writers.sql's header has the full
-- recipe). ledger_migrate owns the schema; ledger_runtime gets DML only. A
-- deployment that already ran the documented ALTER DEFAULT PRIVILEGES steps
-- has this covered and the block below is then a no-op — but the failure mode
-- of having missed them is "permission denied for table mailbox_grants" on
-- the connect path in PRODUCTION ONLY, discovered by the first user to try,
-- so it is granted explicitly here as well, the same as 00025 did for the
-- passkey tables.
--
-- Conditional on the role existing: pgtest clusters and single-role
-- deployments have no ledger_runtime, and an unconditional GRANT would fail
-- the migration for every one of them. No sequence grant is needed — none of
-- the three tables has a serial column (mailbox_grants.id defaults from
-- gen_random_uuid(), not a sequence).
-- +goose StatementBegin
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ledger_runtime') THEN
    EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON mailbox_grants       TO ledger_runtime';
    EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON mailbox_senders      TO ledger_runtime';
    EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON mailbox_oauth_states TO ledger_runtime';
  END IF;
END $$;
-- +goose StatementEnd

-- +goose Down
-- FORWARD-ONLY DEPLOYMENT (deploy/README.md): read 00025_passkeys.sql's "READ
-- THIS BEFORE REACHING FOR THE DOWN MIGRATION" before ever running this Down.
-- It is correct only on a database with no mailbox_grants/mailbox_senders/
-- mailbox_oauth_states rows yet; production's fix for a bad migration is
-- another migration or a restore from the pre-deploy backup, not `goose down`.
DROP TABLE mailbox_oauth_states;
DROP TABLE mailbox_senders;
DROP TABLE mailbox_grants;
