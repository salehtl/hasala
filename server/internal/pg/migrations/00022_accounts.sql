-- +goose Up
-- WS-3, accounts and auth (spec 02 §5.3; spec 01 §9). Numbered 00022, after
-- WS-4's 00020 and 00021, which create spec 07's banks, waitlist_entries,
-- invite_codes (with the review flag this work reads) and mail_log; this file
-- reuses those tables and creates none of them. It is applied as it stands,
-- on top of 00001, 00010, 00020 and 00021: the QA database already runs
-- 00001, so nothing is squashed into the baseline any more.
--
-- What changes:
--   * users becomes the email-keyed account of spec 02 D-4: no IdP columns, a
--     user handle, the verified address (NOT NULL now that signup sets it), the
--     display name, the review flag, the password verifier and its failure
--     counter and pause, the freeze columns (frozen_by, holder_also_froze) and
--     suspended_at;
--   * sessions record who minted them, whether they are restricted (minted
--     while frozen), when they were last used (the sliding idle window) and why
--     they were revoked;
--   * webauthn_ceremonies' register binding names a signup ceremony instead of
--     an invite hash;
--   * new: signup, password-login, recovery, password-reset and email-change
--     ceremonies; email codes, their pauses and the Postgres-backed counters;
--     freeze tokens and the session-free device-freeze challenges; auth events;
--     server_meta (the key fingerprints of spec 02 §5.6 O9);
--   * gone: ledgerd's account_deletion_challenges (spec 02 §2.5): deletion
--     takes an account.delete step-up now.
--
-- Every ADD COLUMN ... NOT NULL without a default applies only to empty tables:
-- the QA database runs 00001 with no account in it, and the deploy checks that
-- before the chain is applied. Against a database that already holds accounts
-- this migration fails, on purpose.

-- +goose StatementBegin
DO $$
BEGIN
  IF current_user <> 'hasala_migrate' THEN
    RAISE EXCEPTION 'migrations must be applied as hasala_migrate, not %', current_user;
  END IF;
END $$;
-- +goose StatementEnd

-- ── accounts (spec 02 §5.3 users) ───────────────────────────────────────────
ALTER TABLE users
  DROP CONSTRAINT users_idp_is_closed,
  DROP CONSTRAINT users_idp_sub_hash_is_sha256,
  DROP CONSTRAINT users_identity_uniq,
  DROP COLUMN idp,
  DROP COLUMN idp_sub_hash,
  ALTER COLUMN created_at DROP DEFAULT,
  ALTER COLUMN email_norm SET NOT NULL,
  ADD COLUMN user_handle bytea NOT NULL,
  ADD COLUMN suspended_at timestamptz,
  ADD COLUMN email_verified_at timestamptz NOT NULL,
  ADD COLUMN email_undeliverable_at timestamptz,
  ADD COLUMN reverify_requested_at timestamptz,
  ADD COLUMN display_name text NOT NULL,
  ADD COLUMN review_account boolean NOT NULL DEFAULT false,
  ADD COLUMN password_hash bytea,
  ADD COLUMN password_salt bytea,
  ADD COLUMN password_version smallint,
  ADD COLUMN password_set_at timestamptz,
  ADD COLUMN password_failures integer NOT NULL DEFAULT 0,
  ADD COLUMN password_paused_until timestamptz,
  ADD COLUMN frozen_at timestamptz,
  ADD COLUMN freeze_trigger_at timestamptz,
  ADD COLUMN frozen_by text,
  ADD COLUMN holder_also_froze boolean NOT NULL DEFAULT false,
  ADD CONSTRAINT users_handle_is_256_bits CHECK (octet_length(user_handle) = 32),
  ADD CONSTRAINT users_handle_uniq UNIQUE (user_handle),
  ADD CONSTRAINT users_suspension_time CHECK ((status = 'suspended') = (suspended_at IS NOT NULL)),
  ADD CONSTRAINT users_password_all_or_nothing CHECK (
    (password_hash IS NULL) = (password_salt IS NULL)
    AND (password_hash IS NULL) = (password_version IS NULL)
    AND (password_hash IS NULL) = (password_set_at IS NULL)),
  ADD CONSTRAINT users_password_shape CHECK (password_hash IS NULL OR (
    octet_length(password_hash) = 32 AND octet_length(password_salt) = 16 AND password_version >= 1)),
  ADD CONSTRAINT users_password_failures_non_negative CHECK (password_failures >= 0),
  ADD CONSTRAINT users_freeze_pair CHECK (
    (frozen_at IS NULL) = (freeze_trigger_at IS NULL)
    AND (frozen_at IS NULL) = (frozen_by IS NULL)
    AND (freeze_trigger_at IS NULL OR freeze_trigger_at <= frozen_at)),
  ADD CONSTRAINT users_frozen_by_is_closed CHECK (frozen_by IS NULL OR frozen_by IN ('holder','operator')),
  ADD CONSTRAINT users_holder_also_froze_shape CHECK (NOT holder_also_froze OR frozen_by = 'operator'),
  -- The backstop for auth.DisplayName (spec 02 §10.7.4), which runs first in Go.
  ADD CONSTRAINT users_display_name_shape CHECK (
    char_length(display_name) BETWEEN 1 AND 64
    AND octet_length(display_name) <= 256
    AND display_name = btrim(display_name)
    AND display_name !~ '[\x01-\x1f\x7f-\x9f​-‏‪-‮⁠-⁩﻿]'
    AND display_name !~ '[0-9@/:<>";=?&#%]'
    AND display_name !~ '  '
    AND display_name !~ '[.][^ ]');

-- ── signup (spec 02 §10.7; no FK to users: the account does not exist yet) ──
CREATE TABLE signup_ceremonies (
  id               text PRIMARY KEY,
  user_id          uuid NOT NULL,
  invite_code_hash bytea NOT NULL,
  email_norm       text NOT NULL,
  email_tag        bytea NOT NULL,
  display_name     text NOT NULL,
  email_proven     boolean NOT NULL,
  code_id          uuid,
  verified_at      timestamptz,
  signup_nonce     bytea NOT NULL,
  claimed_at       timestamptz,
  created_at       timestamptz NOT NULL,
  expires_at       timestamptz NOT NULL,
  CONSTRAINT signup_ceremonies_user_uniq UNIQUE (user_id),
  CONSTRAINT signup_ceremonies_nonce_uniq UNIQUE (signup_nonce),
  CONSTRAINT signup_ceremonies_sizes CHECK (
    octet_length(invite_code_hash) = 32 AND octet_length(email_tag) = 32 AND octet_length(signup_nonce) = 32),
  CONSTRAINT signup_ceremonies_proof_shape CHECK (
    email_proven = (code_id IS NULL) AND (NOT email_proven OR verified_at IS NULL)),
  CONSTRAINT signup_ceremonies_claim_needs_proof CHECK (
    claimed_at IS NULL OR email_proven OR verified_at IS NOT NULL),
  CONSTRAINT signup_ceremonies_ttl CHECK (expires_at > created_at AND expires_at <= created_at + interval '30 minutes'),
  CONSTRAINT signup_ceremonies_display_name_shape CHECK (
    char_length(display_name) BETWEEN 1 AND 64 AND octet_length(display_name) <= 256
    AND display_name = btrim(display_name))
);
CREATE INDEX signup_ceremonies_expiry_idx ON signup_ceremonies (expires_at);

ALTER TABLE webauthn_ceremonies
  DROP CONSTRAINT webauthn_ceremonies_register_binding,
  DROP COLUMN invite_code_hash,
  ADD COLUMN signup_id text REFERENCES signup_ceremonies(id) ON DELETE CASCADE,
  ADD CONSTRAINT webauthn_ceremonies_register_binding CHECK (
    (kind = 'register') = (authority_pubkey IS NOT NULL)
    AND (kind = 'register') = (register_nonce IS NOT NULL)
    AND (kind = 'register') = (signup_id IS NOT NULL)
    AND (authority_pubkey IS NULL OR octet_length(authority_pubkey) = 32)
    AND (register_nonce IS NULL OR octet_length(register_nonce) = 32));

-- ── sessions (spec 02 §9) ───────────────────────────────────────────────────
ALTER TABLE sessions
  ALTER COLUMN created_at DROP DEFAULT,
  ADD COLUMN minted_by text NOT NULL,
  ADD COLUMN restricted boolean NOT NULL DEFAULT false,
  ADD COLUMN last_used_at timestamptz NOT NULL,
  ADD COLUMN revoked_reason text,
  ADD CONSTRAINT sessions_revocation_reason CHECK (
    (revoked_at IS NULL) = (revoked_reason IS NULL)
    AND (revoked_reason IS NULL OR revoked_reason IN ('logout','writer','others'))),
  ADD CONSTRAINT sessions_minted_by_is_closed CHECK (minted_by IN (
    'register','login','recover','password_signup','password_login','password_reset')),
  ADD CONSTRAINT sessions_use_follows_creation CHECK (last_used_at >= created_at);

-- ── email codes, ceremonies, counters (spec 01 §10.9, §10.14–§10.17) ───────
-- Only HMAC(K_code, …) of a code is stored; K_code is not in the database.
CREATE TABLE email_codes (
  code_id       uuid PRIMARY KEY,
  purpose       text NOT NULL,
  email_tag     bytea NOT NULL,
  user_id       uuid REFERENCES users(id) ON DELETE CASCADE,
  ceremony_kind text NOT NULL,
  ceremony_id   text NOT NULL,
  code_mac      bytea NOT NULL,
  sent          boolean NOT NULL,
  attempts      smallint NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL,
  expires_at    timestamptz NOT NULL,
  used_at       timestamptz,
  burned_at     timestamptz,
  CONSTRAINT email_codes_purpose_is_closed CHECK (purpose IN (
    'signup','email_verify','email_change_old','email_change_new','password_reset','recovery','waitlist')),
  CONSTRAINT email_codes_ceremony_is_closed CHECK (ceremony_kind IN (
    'signup','step_up','email_change','email_verify','password_reset','recovery','waitlist')),
  CONSTRAINT email_codes_sizes CHECK (octet_length(email_tag) = 32 AND octet_length(code_mac) = 32),
  CONSTRAINT email_codes_attempts CHECK (attempts BETWEEN 0 AND 5),
  CONSTRAINT email_codes_one_ending CHECK (used_at IS NULL OR burned_at IS NULL),
  CONSTRAINT email_codes_ttl CHECK (expires_at > created_at AND expires_at <= created_at + interval '10 minutes')
);
CREATE INDEX email_codes_send_window_idx ON email_codes (purpose, email_tag, created_at);
CREATE INDEX email_codes_ceremony_idx ON email_codes (ceremony_kind, ceremony_id);
CREATE INDEX email_codes_expiry_idx ON email_codes (expires_at);

CREATE TABLE email_code_pauses (
  purpose      text NOT NULL,
  email_tag    bytea NOT NULL,
  paused_until timestamptz NOT NULL,
  PRIMARY KEY (purpose, email_tag),
  CONSTRAINT email_code_pauses_tag_is_256_bits CHECK (octet_length(email_tag) = 32)
);

-- Fixed-window counters keyed by 32 bytes that are never an address.
CREATE TABLE rate_counters (
  scope        text NOT NULL,
  key          bytea NOT NULL,
  window_start timestamptz NOT NULL,
  count        integer NOT NULL,
  PRIMARY KEY (scope, key, window_start),
  CONSTRAINT rate_counters_scope_is_closed CHECK (scope IN (
    'password-email','code-verify-email','password-writer')),
  CONSTRAINT rate_counters_key_is_256_bits CHECK (octet_length(key) = 32),
  CONSTRAINT rate_counters_count_is_non_negative CHECK (count >= 0)
);
CREATE INDEX rate_counters_window_idx ON rate_counters (window_start);

CREATE TABLE password_login_ceremonies (
  id         text PRIMARY KEY,
  user_id    uuid REFERENCES users(id) ON DELETE CASCADE,
  email_tag  bytea NOT NULL,
  nonce      bytea NOT NULL,
  created_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  used_at    timestamptz,
  CONSTRAINT password_login_sizes CHECK (octet_length(email_tag) = 32 AND octet_length(nonce) = 32),
  CONSTRAINT password_login_nonce_uniq UNIQUE (nonce),
  CONSTRAINT password_login_ttl CHECK (expires_at > created_at AND expires_at <= created_at + interval '5 minutes')
);
CREATE INDEX password_login_ceremonies_expiry_idx ON password_login_ceremonies (expires_at);

CREATE TABLE recovery_ceremonies (
  id            text PRIMARY KEY,
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  recover_nonce bytea NOT NULL,
  code_id       uuid NOT NULL,
  verified_at   timestamptz,
  kind          text,
  session_data  jsonb,
  claimed_at    timestamptz,
  created_at    timestamptz NOT NULL,
  expires_at    timestamptz NOT NULL,
  CONSTRAINT recovery_ceremonies_nonce CHECK (octet_length(recover_nonce) = 32),
  CONSTRAINT recovery_ceremonies_nonce_uniq UNIQUE (recover_nonce),
  CONSTRAINT recovery_ceremonies_kind CHECK (
    (verified_at IS NULL) = (kind IS NULL)
    AND ((kind IS NULL AND session_data IS NULL)
         OR (kind = 'passkey' AND session_data IS NOT NULL)
         OR (kind = 'password' AND session_data IS NULL))),
  CONSTRAINT recovery_ceremonies_claim_needs_code CHECK (claimed_at IS NULL OR verified_at IS NOT NULL),
  CONSTRAINT recovery_ceremonies_ttl CHECK (
    expires_at > created_at
    AND (verified_at IS NULL OR verified_at <= created_at + interval '10 minutes')
    AND expires_at <= coalesce(verified_at, created_at) + interval '10 minutes')
);
CREATE INDEX recovery_ceremonies_expiry_idx ON recovery_ceremonies (expires_at);

CREATE TABLE password_reset_ceremonies (
  id                 text PRIMARY KEY,
  user_id            uuid REFERENCES users(id) ON DELETE CASCADE,
  email_tag          bytea NOT NULL,
  code_id            uuid NOT NULL,
  verified_at        timestamptz,
  reset_nonce        bytea NOT NULL,
  ek_pubkey          bytea,
  approved_by_writer text,
  approved_session   bytea,
  approval_sig       bytea,
  approved_at        timestamptz,
  consumed_at        timestamptz,
  created_at         timestamptz NOT NULL,
  expires_at         timestamptz NOT NULL,
  CONSTRAINT password_reset_sizes CHECK (
    octet_length(email_tag) = 32 AND octet_length(reset_nonce) = 32
    AND (ek_pubkey IS NULL OR octet_length(ek_pubkey) = 32)
    AND (approval_sig IS NULL OR octet_length(approval_sig) = 64)
    AND (approved_session IS NULL OR octet_length(approved_session) = 32)),
  CONSTRAINT password_reset_nonce_uniq UNIQUE (reset_nonce),
  CONSTRAINT password_reset_approval_shape CHECK (
    (approved_by_writer IS NULL) = (approval_sig IS NULL)
    AND (approved_by_writer IS NULL) = (approved_session IS NULL)
    AND (approved_by_writer IS NULL) = (approved_at IS NULL)
    AND (approved_at IS NULL OR ek_pubkey IS NOT NULL)
    AND (ek_pubkey IS NULL OR verified_at IS NOT NULL)
    AND (consumed_at IS NULL OR approved_at IS NOT NULL)),
  CONSTRAINT password_reset_approver_fk FOREIGN KEY (user_id, approved_by_writer)
    REFERENCES writers (user_id, writer_id) ON DELETE CASCADE,
  CONSTRAINT password_reset_ttl CHECK (
    expires_at > created_at
    AND (verified_at IS NULL OR verified_at <= created_at + interval '10 minutes')
    AND expires_at <= coalesce(verified_at, created_at) + interval '10 minutes')
);
CREATE INDEX password_reset_ceremonies_expiry_idx ON password_reset_ceremonies (expires_at);
CREATE INDEX password_reset_ceremonies_pending_idx ON password_reset_ceremonies (user_id)
  WHERE ek_pubkey IS NOT NULL AND approved_at IS NULL;

CREATE TABLE email_change_ceremonies (
  id                uuid PRIMARY KEY,
  user_id           uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  new_email_norm    text NOT NULL,
  new_email_tag     bytea NOT NULL,
  new_in_use        boolean NOT NULL,
  new_password_hash bytea,
  new_password_salt bytea,
  change_nonce      bytea NOT NULL,
  code_old_id       uuid NOT NULL,
  code_new_id       uuid NOT NULL,
  consumed_at       timestamptz,
  created_at        timestamptz NOT NULL,
  expires_at        timestamptz NOT NULL,
  CONSTRAINT email_change_new_email_shape CHECK (
    new_email_norm ~ '^[!-?A-~]{1,64}@[!-?A-~]{1,253}$'
    AND new_email_norm ~ '@[^@.][^@]*[.][^@]*[^@.]$'
    AND new_email_norm !~ '[A-Z]' AND octet_length(new_email_norm) <= 254),
  CONSTRAINT email_change_sizes CHECK (octet_length(new_email_tag) = 32 AND octet_length(change_nonce) = 32),
  CONSTRAINT email_change_nonce_uniq UNIQUE (change_nonce),
  CONSTRAINT email_change_password_pair CHECK (
    (new_password_hash IS NULL) = (new_password_salt IS NULL)
    AND (new_password_hash IS NULL OR (octet_length(new_password_hash) = 32 AND octet_length(new_password_salt) = 16))),
  CONSTRAINT email_change_ttl CHECK (expires_at > created_at AND expires_at <= created_at + interval '10 minutes')
);
CREATE INDEX email_change_ceremonies_expiry_idx ON email_change_ceremonies (expires_at);

-- ── freeze and auth events (spec 01 §10.18, Q12) ────────────────────────────
CREATE TABLE freeze_tokens (
  token_hash   bytea PRIMARY KEY,
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  trigger_kind text NOT NULL,
  trigger_at   timestamptz NOT NULL,
  created_at   timestamptz NOT NULL,
  expires_at   timestamptz NOT NULL,
  used_at      timestamptz,
  CONSTRAINT freeze_tokens_hash_is_256_bits CHECK (octet_length(token_hash) = 32),
  CONSTRAINT freeze_tokens_trigger_is_closed CHECK (trigger_kind IN ('new_sign_in','recovery_used')),
  CONSTRAINT freeze_tokens_ttl CHECK (expires_at > created_at AND expires_at <= created_at + interval '7 days')
);
CREATE INDEX freeze_tokens_expiry_idx ON freeze_tokens (expires_at);

-- D42: no FK and no user id, because #77 answers every well-formed writer id alike.
CREATE TABLE device_freeze_challenges (
  nonce      bytea PRIMARY KEY,
  writer_id  text NOT NULL,
  issued_at  timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  used_at    timestamptz,
  CONSTRAINT device_freeze_challenges_nonce_is_256_bits CHECK (octet_length(nonce) = 32),
  CONSTRAINT device_freeze_challenges_writer_id_grammar CHECK (
    writer_id ~ '^ios-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'),
  CONSTRAINT device_freeze_challenges_ttl CHECK (expires_at > issued_at AND expires_at <= issued_at + interval '5 minutes')
);
CREATE INDEX device_freeze_challenges_expiry_idx ON device_freeze_challenges (expires_at);

CREATE TABLE auth_events (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id        uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind           text NOT NULL,
  at             timestamptz NOT NULL,
  method         text,
  writer_id      text,
  credential_id  bytea,
  CONSTRAINT auth_events_kind_is_closed CHECK (kind IN (
    'sign_in_new','passkey_added','passkey_removed','password_set','password_changed',
    'password_removed','password_reset','recovery_used','phrase_viewed','phrase_rotated',
    'device_added','device_removed','email_changed','email_verified','account_frozen',
    'account_unfrozen','sessions_revoked','mailbox_linked','mailbox_unlinked')),
  CONSTRAINT auth_events_method_is_closed CHECK (method IS NULL OR method IN ('passkey','password'))
);
CREATE INDEX auth_events_user_idx ON auth_events (user_id, id DESC);
CREATE INDEX auth_events_at_idx ON auth_events (at);

-- ── server facts (spec 02 §5.6 O9) ──────────────────────────────────────────
CREATE TABLE server_meta (
  key   text PRIMARY KEY,
  value text NOT NULL,
  CONSTRAINT server_meta_key_is_closed CHECK (key IN ('auth_key_id','salt_key_id'))
);

-- ── ledgerd's deletion nonce (spec 02 §2.5: replaced by step_up_challenges) ──
DROP TABLE account_deletion_challenges;

-- The runtime role's DML on these tables comes from 00001's default privileges.

-- +goose Down
-- pgtest only (MigrateDown, and TestDownTo21IsWhat00021Left): exactly 00021's
-- shape again. Dropping a column drops the constraints that name it.
CREATE TABLE account_deletion_challenges (
  nonce      bytea PRIMARY KEY,
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  issued_at  timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  used_at    timestamptz,
  CONSTRAINT account_deletion_challenges_nonce_is_256_bits CHECK (octet_length(nonce) = 32)
);
CREATE INDEX account_deletion_challenges_expiry_idx ON account_deletion_challenges (expires_at);
DROP TABLE auth_events, device_freeze_challenges, freeze_tokens, email_change_ceremonies,
  password_reset_ceremonies, recovery_ceremonies, password_login_ceremonies, rate_counters,
  email_code_pauses, email_codes, server_meta;
ALTER TABLE sessions
  DROP COLUMN minted_by,
  DROP COLUMN restricted,
  DROP COLUMN last_used_at,
  DROP COLUMN revoked_reason,
  ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE webauthn_ceremonies
  DROP COLUMN signup_id,
  ADD COLUMN invite_code_hash bytea,
  ADD CONSTRAINT webauthn_ceremonies_register_binding CHECK (
    (kind = 'register') = (authority_pubkey IS NOT NULL)
    AND (kind = 'register') = (register_nonce IS NOT NULL)
    AND (authority_pubkey IS NULL OR octet_length(authority_pubkey) = 32)
    AND (register_nonce IS NULL OR octet_length(register_nonce) = 32));
DROP TABLE signup_ceremonies;
ALTER TABLE users
  DROP COLUMN user_handle,
  DROP COLUMN suspended_at,
  DROP COLUMN email_verified_at,
  DROP COLUMN email_undeliverable_at,
  DROP COLUMN reverify_requested_at,
  DROP COLUMN display_name,
  DROP COLUMN review_account,
  DROP COLUMN password_hash,
  DROP COLUMN password_salt,
  DROP COLUMN password_version,
  DROP COLUMN password_set_at,
  DROP COLUMN password_failures,
  DROP COLUMN password_paused_until,
  DROP COLUMN frozen_at,
  DROP COLUMN freeze_trigger_at,
  DROP COLUMN frozen_by,
  DROP COLUMN holder_also_froze,
  ALTER COLUMN created_at SET DEFAULT now(),
  ALTER COLUMN email_norm DROP NOT NULL,
  ADD COLUMN idp text NOT NULL,
  ADD COLUMN idp_sub_hash bytea NOT NULL,
  ADD CONSTRAINT users_idp_is_closed CHECK (idp IN ('passkey')),
  ADD CONSTRAINT users_idp_sub_hash_is_sha256 CHECK (octet_length(idp_sub_hash) = 32),
  ADD CONSTRAINT users_identity_uniq UNIQUE (idp, idp_sub_hash);
