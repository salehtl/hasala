-- +goose Up
-- WS-3, accounts and auth (spec 02 §5.3; spec 01 §9). Pre-assigned number
-- 00011 of WS-3's range; squashed into 00001_baseline.sql before the first QA
-- deploy, like every migration in 00002–00029.
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
--   * spec 07's block, as far as this work needs it: banks (with its seed),
--     waitlist_entries, invite_codes (07 §2.5's state machine, replacing
--     ledgerd's table) and mail_log (07 §2.8). The rest of 07's block
--     (waitlist_tokens, bank_requests, TestFlight, admin_audit) and 07 §2.10's
--     per-column grants arrive with WS-19, together with the hasala_console role
--     those grants name.
--
-- Every ADD COLUMN ... NOT NULL without a default applies only to empty tables,
-- which holds because no database has been deployed with 00001 yet (see 00010's
-- header): against a database that already holds accounts this migration fails,
-- on purpose.

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

-- ── spec 07's block (07 §2.2, §2.3, §2.5, §2.8): the part this work reaches ──
DROP TABLE invite_codes;
DROP FUNCTION forget_invite_note();

CREATE TABLE banks (
  slug              text PRIMARY KEY,
  name              text NOT NULL,
  status            text NOT NULL DEFAULT 'new',
  aliases           text[] NOT NULL DEFAULT '{}',
  status_changed_at timestamptz NOT NULL DEFAULT now(),
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT banks_slug_shape CHECK (slug ~ '^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$' AND slug <> 'other'),
  CONSTRAINT banks_name_is_bounded CHECK (char_length(name) BETWEEN 1 AND 64),
  CONSTRAINT banks_status_is_closed CHECK (status IN ('new','planned','in_progress','supported','wont_do')),
  CONSTRAINT banks_aliases_are_bounded CHECK (cardinality(aliases) <= 32)
);
INSERT INTO banks (slug, name, status, aliases) VALUES
  ('enbd',             'Emirates NBD',         'supported', '{"emirates nbd","enbd"}'),
  ('dib',              'Dubai Islamic Bank',   'supported', '{"dubai islamic bank","dubai islamic","dib"}'),
  ('adcb',             'ADCB',                 'new', '{"adcb","abu dhabi commercial bank"}'),
  ('fab',              'First Abu Dhabi Bank', 'new', '{"fab","first abu dhabi bank","first abu dhabi"}'),
  ('mashreq',          'Mashreq',              'new', '{"mashreq","mashreq bank","mashreqbank","mashreq neo"}'),
  ('rakbank',          'RAKBANK',              'new', '{"rakbank","rak bank","rak"}'),
  ('emirates-islamic', 'Emirates Islamic',     'new', '{"emirates islamic","emirates islamic bank"}'),
  ('wio',              'Wio',                  'new', '{"wio","wio bank"}'),
  ('liv',              'Liv',                  'new', '{"liv","liv bank"}');

CREATE TABLE waitlist_entries (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email_tag            bytea NOT NULL,
  email_norm           text,
  state                text NOT NULL,
  bank_slug            text REFERENCES banks(slug) ON DELETE RESTRICT,
  other_bank           text,
  other_bank_key       text,
  source               text NOT NULL,
  created_at           timestamptz NOT NULL,
  updated_at           timestamptz NOT NULL,
  confirm_sent_count   smallint NOT NULL DEFAULT 0,
  last_confirm_sent_at timestamptz,
  confirmed_at         timestamptz,
  invited_at           timestamptz,
  joined_at            timestamptz,
  CONSTRAINT waitlist_entries_tag_uniq UNIQUE (email_tag),
  CONSTRAINT waitlist_entries_tag_is_256_bits CHECK (octet_length(email_tag) = 32),
  CONSTRAINT waitlist_entries_email_shape CHECK (email_norm IS NULL OR (
    email_norm ~ '^[!-?A-~]{1,64}@[!-?A-~]{1,253}$' AND email_norm ~ '@[^@.][^@]*[.][^@]*[^@.]$'
    AND email_norm !~ '[A-Z]' AND octet_length(email_norm) <= 254)),
  CONSTRAINT waitlist_entries_state_is_closed CHECK (state IN ('pending','confirmed','invited','joined')),
  CONSTRAINT waitlist_entries_email_until_joined CHECK ((state = 'joined') = (email_norm IS NULL)),
  CONSTRAINT waitlist_entries_source_is_closed CHECK (source IN ('web','app')),
  CONSTRAINT waitlist_entries_one_bank CHECK (NOT (bank_slug IS NOT NULL AND other_bank IS NOT NULL)),
  CONSTRAINT waitlist_entries_other_shape CHECK ((other_bank IS NULL) = (other_bank_key IS NULL)
    AND (other_bank IS NULL OR char_length(other_bank) BETWEEN 1 AND 64)
    AND (other_bank_key IS NULL OR char_length(other_bank_key) BETWEEN 1 AND 64)),
  CONSTRAINT waitlist_entries_confirmed_shape CHECK ((state = 'pending') = (confirmed_at IS NULL)),
  CONSTRAINT waitlist_entries_invited_shape CHECK (state NOT IN ('invited','joined') OR invited_at IS NOT NULL),
  CONSTRAINT waitlist_entries_joined_shape CHECK ((state = 'joined') = (joined_at IS NOT NULL)),
  CONSTRAINT waitlist_entries_confirm_sends_bounded CHECK (confirm_sent_count BETWEEN 0 AND 5)
);
CREATE INDEX waitlist_entries_state_idx ON waitlist_entries (state, created_at DESC);
CREATE INDEX waitlist_entries_pending_expiry_idx
  ON waitlist_entries ((coalesce(last_confirm_sent_at, created_at))) WHERE state = 'pending';
CREATE INDEX waitlist_entries_bank_idx ON waitlist_entries (bank_slug) WHERE bank_slug IS NOT NULL;
CREATE INDEX waitlist_entries_other_idx ON waitlist_entries (other_bank_key) WHERE other_bank_key IS NOT NULL;

CREATE TABLE invite_codes (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code_hash         bytea,
  link_key_hash     bytea,
  email_tag         bytea,
  waitlist_entry_id uuid REFERENCES waitlist_entries(id) ON DELETE SET NULL,
  origin            text NOT NULL,
  review            boolean NOT NULL DEFAULT false,
  state             text NOT NULL,
  note              text,
  ttl               interval NOT NULL DEFAULT interval '14 days',
  created_at        timestamptz NOT NULL,
  minted_at         timestamptz,
  expires_at        timestamptz,
  mint_count        smallint NOT NULL DEFAULT 0,
  redeemed_at       timestamptz,
  redeemed_by       uuid REFERENCES users(id) ON DELETE SET NULL,
  closed_at         timestamptz,
  CONSTRAINT invite_codes_code_uniq UNIQUE (code_hash),
  CONSTRAINT invite_codes_link_key_uniq UNIQUE (link_key_hash),
  CONSTRAINT invite_codes_hashes_are_256_bits CHECK (
    (code_hash IS NULL OR octet_length(code_hash) = 32)
    AND (link_key_hash IS NULL OR octet_length(link_key_hash) = 32)
    AND (email_tag IS NULL OR octet_length(email_tag) = 32)),
  CONSTRAINT invite_codes_origin_is_closed CHECK (origin IN ('admin','cli')),
  CONSTRAINT invite_codes_state_is_closed CHECK (state IN
    ('awaiting_testflight','queued','active','redeemed','expired','revoked')),
  CONSTRAINT invite_codes_unminted_shape CHECK (state NOT IN ('awaiting_testflight','queued')
    OR (code_hash IS NULL AND link_key_hash IS NULL AND minted_at IS NULL)),
  CONSTRAINT invite_codes_minted_shape CHECK (state NOT IN ('active','redeemed')
    OR (code_hash IS NOT NULL AND minted_at IS NOT NULL AND expires_at IS NOT NULL)),
  CONSTRAINT invite_codes_expiry_follows_mint CHECK (expires_at IS NULL OR expires_at > minted_at),
  CONSTRAINT invite_codes_link_key_needs_address CHECK (link_key_hash IS NULL OR email_tag IS NOT NULL),
  CONSTRAINT invite_codes_admin_invites_are_addressed CHECK (origin = 'cli' OR email_tag IS NOT NULL
    OR closed_at IS NOT NULL),
  CONSTRAINT invite_codes_review_shape CHECK (NOT review OR (origin = 'cli' AND email_tag IS NULL
    AND link_key_hash IS NULL AND waitlist_entry_id IS NULL)),
  CONSTRAINT invite_codes_redemption_shape CHECK ((state = 'redeemed') = (redeemed_at IS NOT NULL)
    AND (redeemed_by IS NULL OR redeemed_at IS NOT NULL)),
  CONSTRAINT invite_codes_closed_shape CHECK ((state IN ('redeemed','expired','revoked')) = (closed_at IS NOT NULL)),
  CONSTRAINT invite_codes_note_is_bounded CHECK (note IS NULL OR char_length(note) <= 200),
  CONSTRAINT invite_codes_ttl_is_bounded CHECK (ttl BETWEEN interval '1 day' AND interval '30 days'),
  CONSTRAINT invite_codes_mint_count_bounded CHECK (mint_count BETWEEN 0 AND 20)
);
CREATE INDEX invite_codes_state_idx ON invite_codes (state, expires_at);
CREATE INDEX invite_codes_entry_idx ON invite_codes (waitlist_entry_id) WHERE waitlist_entry_id IS NOT NULL;
CREATE INDEX invite_codes_redeemer_idx ON invite_codes (redeemed_by) WHERE redeemed_by IS NOT NULL;
-- +goose StatementBegin
CREATE FUNCTION forget_invite_details() RETURNS trigger AS $$
BEGIN
  NEW.note := NULL;
  NEW.email_tag := NULL;
  NEW.link_key_hash := NULL;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
-- +goose StatementEnd
CREATE TRIGGER invite_details_die_with_the_account BEFORE UPDATE ON invite_codes
  FOR EACH ROW WHEN (OLD.redeemed_by IS NOT NULL AND NEW.redeemed_by IS NULL)
  EXECUTE FUNCTION forget_invite_details();

CREATE TABLE mail_log (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind                text NOT NULL,
  subkind             text,
  lane                text NOT NULL,
  recipient           text,
  recipient_tag       bytea,
  recipient_hint      text NOT NULL,
  user_id             uuid REFERENCES users(id) ON DELETE CASCADE,
  waitlist_entry_id   uuid REFERENCES waitlist_entries(id) ON DELETE CASCADE,
  invite_id           uuid REFERENCES invite_codes(id) ON DELETE SET NULL,
  bank_slug           text REFERENCES banks(slug) ON DELETE SET NULL,
  params              jsonb NOT NULL DEFAULT '{}',
  status              text NOT NULL,
  attempts            smallint NOT NULL DEFAULT 0,
  next_attempt_at     timestamptz,
  lease_until         timestamptz,
  provider_message_id text,
  error               text,
  created_at          timestamptz NOT NULL,
  sent_at             timestamptz,
  final_at            timestamptz,
  CONSTRAINT mail_log_kind_is_closed CHECK (kind IN ('waitlist','waitlist_already',
    'waitlist_has_account','invite','bank_supported','code','reset_code','recovery_code',
    'alert','deleted','test')),
  CONSTRAINT mail_log_lane_is_closed CHECK (lane IN ('transactional','waitlist','bulk')),
  CONSTRAINT mail_log_status_is_closed CHECK (status IN ('queued','sending','sent','failed','bounced','suppressed')),
  CONSTRAINT mail_log_recipient_shape CHECK (recipient IS NULL OR (
    recipient ~ '^[!-?A-~]{1,64}@[!-?A-~]{1,253}$' AND recipient !~ '[A-Z]' AND octet_length(recipient) <= 254)),
  CONSTRAINT mail_log_recipient_until_final CHECK (recipient IS NOT NULL OR final_at IS NOT NULL),
  CONSTRAINT mail_log_tag_shape CHECK ((recipient_tag IS NULL AND status = 'queued')
    OR octet_length(recipient_tag) = 32),
  CONSTRAINT mail_log_hint_is_bounded CHECK (char_length(recipient_hint) BETWEEN 3 AND 80),
  CONSTRAINT mail_log_one_subject CHECK (num_nonnulls(user_id, waitlist_entry_id) <= 1),
  CONSTRAINT mail_log_params_bounded CHECK (octet_length(params::text) <= 1024),
  CONSTRAINT mail_log_attempts_bounded CHECK (attempts BETWEEN 0 AND 10),
  CONSTRAINT mail_log_texts_bounded CHECK ((provider_message_id IS NULL OR char_length(provider_message_id) <= 128)
    AND (error IS NULL OR char_length(error) <= 200) AND (subkind IS NULL OR subkind ~ '^[a-z_]{1,32}$')),
  CONSTRAINT mail_log_queued_shape CHECK ((status = 'queued') = (next_attempt_at IS NOT NULL)),
  CONSTRAINT mail_log_sending_shape CHECK ((status = 'sending') = (lease_until IS NOT NULL)),
  CONSTRAINT mail_log_sent_shape CHECK ((status = 'sent') = (sent_at IS NOT NULL)),
  CONSTRAINT mail_log_final_shape CHECK ((status IN ('sent','failed','bounced','suppressed')) = (final_at IS NOT NULL))
);
CREATE INDEX mail_log_due_idx ON mail_log (lane, next_attempt_at) WHERE status = 'queued';
CREATE INDEX mail_log_lease_idx ON mail_log (lease_until) WHERE status = 'sending';
CREATE INDEX mail_log_tag_idx ON mail_log (recipient_tag, created_at DESC);
CREATE INDEX mail_log_created_idx ON mail_log (created_at DESC);
CREATE INDEX mail_log_user_idx ON mail_log (user_id) WHERE user_id IS NOT NULL;
CREATE INDEX mail_log_entry_idx ON mail_log (waitlist_entry_id) WHERE waitlist_entry_id IS NOT NULL;
CREATE UNIQUE INDEX mail_log_bank_supported_once ON mail_log (recipient, bank_slug)
  WHERE kind = 'bank_supported' AND status <> 'failed';

-- The runtime role's DML on these tables comes from 00001's default privileges.

-- +goose Down
-- pgtest only (MigrateDown): back to 00010's shape where 00010's and 00001's
-- Down statements need it.
DROP TABLE mail_log, invite_codes, waitlist_entries, banks, auth_events, device_freeze_challenges,
  freeze_tokens, email_change_ceremonies, password_reset_ceremonies, recovery_ceremonies,
  password_login_ceremonies, rate_counters, email_code_pauses, email_codes, server_meta;
DROP FUNCTION forget_invite_details();
ALTER TABLE webauthn_ceremonies DROP COLUMN signup_id;
DROP TABLE signup_ceremonies;
CREATE TABLE invite_codes (code_hash bytea PRIMARY KEY);
-- +goose StatementBegin
CREATE FUNCTION forget_invite_note() RETURNS trigger AS $$
BEGIN
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
-- +goose StatementEnd
