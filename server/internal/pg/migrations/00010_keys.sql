-- +goose Up
-- WS-3, keys and writers (spec 02 §5.3; spec 01 §9). Pre-assigned number
-- 00010 of WS-3's range; squashed into 00001_baseline.sql before the first QA
-- deploy, like every migration in 00002–00029.
--
-- What changes:
--   * account_keys and account_key_wraps replace ledgerd's user_keys and
--     user_key_wraps: exact 127-byte wraps with their header bytes, the 45-byte
--     phrase box, the immutability trigger (spec 01 §5, §9);
--   * writers carry the AAK-certified device approval key and the §4.8
--     writer-id grammar (spec 02 N-03), and lose ledgerd's `kind`;
--   * key_history becomes spec 02's verifiable log: every row carries its nonce
--     and signature, registrations the DAK, revocations the pinned final head
--     (R-02); recovery_registered is gone (registration is AAK-only);
--   * users gain authority_pubkey_pending (C_reg's authority key, cleared by
--     bootstrap) and a nullable email_norm with spec 02's shape CHECK: the
--     account's address, which bootstrap's email_hash binds. The signup work
--     that sets it at account creation makes it NOT NULL;
--   * webauthn_credentials gain attestation_sha256 (R-01), webauthn_ceremonies
--     the register binding (authority_pubkey, register_nonce) and the add
--     binding (add_nonce: the passkey.add step-up nonce PasskeyAddMessage
--     signs, spec 01 §10.7);
--   * sessions gain the writer binding (spec 02 §9.4);
--   * step_up_challenges (spec 02 §8.1).
--
-- Two ADD COLUMN ... NOT NULL statements below have no default
-- (webauthn_credentials.attestation_sha256, writers.dak_pubkey). They apply
-- only to empty tables, which holds because no database has been deployed with
-- 00001 yet: the QA database is created from scratch (or this file is squashed
-- into the baseline) before the first deploy. Against a database that already
-- holds credentials or writers this migration fails, on purpose: there is no
-- honest value to backfill.
--
-- users.email_norm is nullable here and nothing in this tree writes it yet;
-- spec 01 §9 wants it NOT NULL plus email_verified_at. The signup work (spec
-- 02 #43-#45) sets it at account creation and tightens the column. Until
-- then bootstrap refuses every account it cannot bind an address for, so this
-- tree must not be deployed to real users before signup lands.

-- +goose StatementBegin
DO $$
BEGIN
  IF current_user <> 'hasala_migrate' THEN
    RAISE EXCEPTION 'migrations must be applied as hasala_migrate, not %', current_user;
  END IF;
END $$;
-- +goose StatementEnd

-- ── accounts ────────────────────────────────────────────────────────────────
ALTER TABLE users
  ADD COLUMN authority_pubkey_pending bytea,
  ADD COLUMN email_norm text,
  ADD CONSTRAINT users_pending_authority_is_ed25519 CHECK (
    authority_pubkey_pending IS NULL OR octet_length(authority_pubkey_pending) = 32),
  ADD CONSTRAINT users_email_norm_shape CHECK (email_norm IS NULL OR (
    email_norm ~ '^[!-?A-~]{1,64}@[!-?A-~]{1,253}$'
    AND email_norm ~ '@[^@.][^@]*[.][^@]*[^@.]$'
    AND email_norm !~ '[A-Z]'
    AND octet_length(email_norm) <= 254)),
  ADD CONSTRAINT users_email_uniq UNIQUE (email_norm);

ALTER TABLE webauthn_credentials
  ADD COLUMN attestation_sha256 bytea NOT NULL,
  ADD CONSTRAINT webauthn_credentials_attestation_is_sha256 CHECK (octet_length(attestation_sha256) = 32);

ALTER TABLE webauthn_ceremonies
  ADD COLUMN authority_pubkey bytea,
  ADD COLUMN register_nonce bytea,
  ADD CONSTRAINT webauthn_ceremonies_register_binding CHECK (
    (kind = 'register') = (authority_pubkey IS NOT NULL)
    AND (kind = 'register') = (register_nonce IS NOT NULL)
    AND (authority_pubkey IS NULL OR octet_length(authority_pubkey) = 32)
    AND (register_nonce IS NULL OR octet_length(register_nonce) = 32)),
  ADD COLUMN add_nonce bytea,
  ADD CONSTRAINT webauthn_ceremonies_add_binding CHECK (
    (kind = 'add') = (add_nonce IS NOT NULL) AND (add_nonce IS NULL OR octet_length(add_nonce) = 32));

-- ── writers ─────────────────────────────────────────────────────────────────
-- The table is empty before the first deploy; the DAK has no default because a
-- writer without one cannot exist (spec 01 §4.9, §10.5).
ALTER TABLE writers DROP CONSTRAINT writers_kind_is_device;
ALTER TABLE writers DROP CONSTRAINT writers_writer_id_charset;
ALTER TABLE writers DROP CONSTRAINT writers_key_is_ed25519;
ALTER TABLE writers DROP COLUMN kind;
ALTER TABLE writers
  ADD COLUMN alg text NOT NULL DEFAULT 'ed25519',
  ADD COLUMN dak_pubkey bytea NOT NULL,
  ADD CONSTRAINT writers_writer_id_grammar CHECK (
    writer_id ~ '^ios-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'),
  ADD CONSTRAINT writers_alg_is_closed CHECK (alg IN ('ed25519')),
  ADD CONSTRAINT writers_key_matches_alg CHECK (alg = 'ed25519' AND octet_length(pubkey) = 32),
  ADD CONSTRAINT writers_dak_is_p256_uncompressed CHECK (CASE
    WHEN octet_length(dak_pubkey) <> 65 THEN false
    ELSE get_byte(dak_pubkey, 0) = 4 END);
ALTER TABLE writers ALTER COLUMN alg DROP DEFAULT;
CREATE UNIQUE INDEX writers_dak_uniq ON writers (user_id, dak_pubkey);

-- +goose StatementBegin
CREATE OR REPLACE FUNCTION writers_guard() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'TRUNCATE' THEN
    RAISE EXCEPTION 'writers: TRUNCATE is refused' USING ERRCODE = 'check_violation';
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL
       AND (NEW.user_id, NEW.writer_id, NEW.alg, NEW.pubkey, NEW.dak_pubkey, NEW.registered_at)
         = (OLD.user_id, OLD.writer_id, OLD.alg, OLD.pubkey, OLD.dak_pubkey, OLD.registered_at) THEN
      RETURN NEW;                       -- the only permitted update: revoke once
    END IF;
    RAISE EXCEPTION 'writers: only setting revoked_at once is permitted' USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM users WHERE id = OLD.user_id) THEN
    RAISE EXCEPTION 'writers: DELETE refused while user % exists', OLD.user_id USING ERRCODE = 'check_violation';
  END IF;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql;
-- +goose StatementEnd

-- ── key history (spec 02 §5.3, spec 01 §9 (a)–(d)) ──────────────────────────
DROP TABLE key_history;
CREATE TABLE key_history (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id              uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  writer_id            text NOT NULL,
  alg                  text NOT NULL,
  pubkey               bytea NOT NULL,
  dak_pubkey           bytea,                 -- 'registered' rows: the AAK-certified DAK (spec 01 §9 (c))
  event                text NOT NULL,
  authorized_by        text NOT NULL,
  authorizer_writer_id text,
  final_counter        bigint,                -- 'revoked' rows: the pinned final head (spec 01 §10.6, R-02)
  final_head           bytea,
  nonce                bytea NOT NULL,
  signature            bytea NOT NULL,
  at                   timestamptz NOT NULL,
  CONSTRAINT key_history_writer_id_grammar CHECK (
    writer_id ~ '^ios-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'),
  CONSTRAINT key_history_alg_is_closed CHECK (alg IN ('ed25519') AND octet_length(pubkey) = 32),
  CONSTRAINT key_history_event_is_closed CHECK (event IN ('registered','revoked')),
  CONSTRAINT key_history_authority_is_closed CHECK (authorized_by IN ('authority','device')),
  CONSTRAINT key_history_authorizer_shape CHECK ((authorized_by = 'device') = (authorizer_writer_id IS NOT NULL)),
  CONSTRAINT key_history_revocation_by_device CHECK (event <> 'revoked' OR authorized_by = 'device'),
  -- spec 01 §9 (DEV-7): every registration, the first writer included, carries an AAK-signed
  -- RegistrationMessage over its own nonce; the bootstrap signature is never stored here.
  CONSTRAINT key_history_registration_by_authority CHECK (event <> 'registered' OR authorized_by = 'authority'),
  CONSTRAINT key_history_dak_on_registration CHECK (
    (event = 'registered') = (dak_pubkey IS NOT NULL)
    AND (dak_pubkey IS NULL OR (CASE WHEN octet_length(dak_pubkey) <> 65 THEN false
                                     ELSE get_byte(dak_pubkey, 0) = 4 END))),
  CONSTRAINT key_history_final_head_on_revocation CHECK (
    (event = 'revoked') = (final_counter IS NOT NULL AND final_head IS NOT NULL)
    AND (final_counter IS NULL OR final_counter >= 0)
    AND (final_head IS NULL OR octet_length(final_head) = 32)),
  CONSTRAINT key_history_nonce_is_256_bits CHECK (octet_length(nonce) = 32),
  CONSTRAINT key_history_signature_is_ed25519 CHECK (octet_length(signature) = 64)
);
CREATE INDEX key_history_user_idx ON key_history (user_id, id);
CREATE TRIGGER key_history_no_rewrite BEFORE UPDATE OR DELETE ON key_history
  FOR EACH ROW EXECUTE FUNCTION append_only_while_user_exists();
CREATE TRIGGER key_history_no_truncate BEFORE TRUNCATE ON key_history
  FOR EACH STATEMENT EXECUTE FUNCTION append_only_while_user_exists();

-- ── sessions ↔ writers (spec 02 §9.4) ───────────────────────────────────────
-- Set once, by bootstrap or writer registration; a bound session is never
-- re-bound. Revoking the writer revokes its sessions (§9.5).
ALTER TABLE sessions
  ADD COLUMN writer_id text,
  ADD CONSTRAINT sessions_writer_fk FOREIGN KEY (user_id, writer_id)
    REFERENCES writers (user_id, writer_id) ON DELETE CASCADE;
CREATE INDEX sessions_writer_idx ON sessions (user_id, writer_id) WHERE writer_id IS NOT NULL;

-- ── step-up (spec 02 §8.1) ──────────────────────────────────────────────────
CREATE TABLE step_up_challenges (
  nonce         bytea PRIMARY KEY,
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  session_hash  bytea NOT NULL REFERENCES sessions(token_hash) ON DELETE CASCADE,
  action        text NOT NULL,
  params_hash   bytea NOT NULL,
  proof_kind    text NOT NULL,
  code_id       uuid,                          -- device_code: the password_reset code issued at begin
  code_attempts smallint NOT NULL DEFAULT 0,
  issued_at     timestamptz NOT NULL,
  expires_at    timestamptz NOT NULL,
  used_at       timestamptz,
  CONSTRAINT step_up_nonce_is_256_bits CHECK (octet_length(nonce) = 32),
  CONSTRAINT step_up_params_hash_is_sha256 CHECK (octet_length(params_hash) = 32),
  CONSTRAINT step_up_action_is_closed CHECK (action IN (
    'passkey.add','passkey.delete','keys.bootstrap','keys.wrap.put','keys.wrap.delete',
    'keys.recovery.rotate','keys.epoch.rotate','writer.revoke','mailbox.link','mailbox.unlink',
    'session.logout_all','account.delete',
    'password.set','password.change','password.remove','password.reset','email.change',
    'phrase.view','account.freeze','account.unfreeze')),
  CONSTRAINT step_up_proof_kind_is_closed CHECK (proof_kind IN ('passkey','device','device_code')),
  CONSTRAINT step_up_device_code_only_for_reset CHECK ((proof_kind = 'device_code') = (action = 'password.reset')),
  CONSTRAINT step_up_code_shape CHECK (
    (proof_kind = 'device_code') = (code_id IS NOT NULL) AND code_attempts BETWEEN 0 AND 5),
  CONSTRAINT step_up_ttl CHECK (expires_at > issued_at AND expires_at <= issued_at + interval '5 minutes')
);
CREATE INDEX step_up_challenges_expiry_idx ON step_up_challenges (expires_at);

-- ── account key material (spec 01 owns the byte layouts) ────────────────────
DROP TABLE user_key_wraps;
DROP TABLE user_keys;

CREATE TABLE account_keys (
  user_id          uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  format_version   smallint NOT NULL,
  amk_commitment   bytea NOT NULL,
  authority_pubkey bytea NOT NULL,
  recovery_pubkey  bytea NOT NULL,
  recovery_wrap    bytea NOT NULL,
  -- spec 01 §5.5: E sealed under K_pv; never returned by GET /keys, only by phrase.view (#67).
  phrase_box       bytea NOT NULL,
  current_epoch    integer NOT NULL DEFAULT 1,
  created_at       timestamptz NOT NULL,
  updated_at       timestamptz NOT NULL,
  CONSTRAINT account_keys_format_is_known CHECK (format_version = 1),
  CONSTRAINT account_keys_commitment_is_256_bits CHECK (octet_length(amk_commitment) = 32),
  CONSTRAINT account_keys_authority_is_ed25519 CHECK (octet_length(authority_pubkey) = 32),
  CONSTRAINT account_keys_recovery_is_ed25519 CHECK (octet_length(recovery_pubkey) = 32),
  -- spec 01 §5.1: version 0x01, kdf 0x01 (phrase), exactly 127 bytes. CASE keeps get_byte in range.
  CONSTRAINT account_keys_recovery_wrap_shape CHECK (CASE
    WHEN octet_length(recovery_wrap) <> 127 THEN false
    ELSE get_byte(recovery_wrap, 0) = 1 AND get_byte(recovery_wrap, 1) = 1 END),
  CONSTRAINT account_keys_phrase_box_shape CHECK (CASE
    WHEN octet_length(phrase_box) <> 45 THEN false
    ELSE get_byte(phrase_box, 0) = 1 END),
  CONSTRAINT account_keys_epoch_is_valid CHECK (current_epoch BETWEEN 1 AND 2147483647),
  CONSTRAINT account_keys_recovery_pubkey_uniq UNIQUE (recovery_pubkey),
  CONSTRAINT account_keys_authority_pubkey_uniq UNIQUE (authority_pubkey)
);

-- +goose StatementBegin
CREATE FUNCTION account_keys_guard() RETURNS trigger AS $$
BEGIN
  IF NEW.user_id <> OLD.user_id OR NEW.format_version <> OLD.format_version
     OR NEW.amk_commitment <> OLD.amk_commitment OR NEW.authority_pubkey <> OLD.authority_pubkey
     OR NEW.created_at <> OLD.created_at OR NEW.current_epoch < OLD.current_epoch THEN
    RAISE EXCEPTION 'account_keys: commitment, authority key and creation time are immutable; epochs only rise'
      USING ERRCODE = 'check_violation';
  END IF;
  -- spec 01 §9: the phrase box changes only together with the recovery key (phrase rotation).
  IF NEW.phrase_box <> OLD.phrase_box AND NEW.recovery_pubkey = OLD.recovery_pubkey THEN
    RAISE EXCEPTION 'account_keys: the phrase box changes only with the recovery key'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
-- +goose StatementEnd
CREATE TRIGGER account_keys_immutable BEFORE UPDATE ON account_keys
  FOR EACH ROW EXECUTE FUNCTION account_keys_guard();

CREATE TABLE account_key_wraps (
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  credential_id bytea NOT NULL,
  wrap          bytea NOT NULL,
  wrap_version  smallint NOT NULL,
  created_at    timestamptz NOT NULL,
  PRIMARY KEY (user_id, credential_id),
  CONSTRAINT account_key_wraps_credential_fk FOREIGN KEY (user_id, credential_id)
    REFERENCES webauthn_credentials (user_id, credential_id) ON DELETE CASCADE,
  -- spec 01 §5.1: version 0x01, kdf 0x02 (PRF), exactly 127 bytes.
  CONSTRAINT account_key_wraps_wrap_shape CHECK (CASE
    WHEN octet_length(wrap) <> 127 THEN false
    ELSE get_byte(wrap, 0) = 1 AND get_byte(wrap, 1) = 2 END),
  CONSTRAINT account_key_wraps_version_is_known CHECK (wrap_version = 1)
);

-- ── privileges (spec 02 D-6): the default privileges granted the runtime role
-- DML on every new table; key_history stays append-only for it ─────────────
REVOKE UPDATE, DELETE ON key_history FROM hasala_runtime;

-- +goose Down
-- pgtest only (MigrateDown): back to 00001's table set, so its Down can run.
DROP TABLE account_key_wraps, account_keys, step_up_challenges;
DROP FUNCTION account_keys_guard();
DROP INDEX sessions_writer_idx;
ALTER TABLE sessions DROP CONSTRAINT sessions_writer_fk, DROP COLUMN writer_id;
CREATE TABLE user_keys (user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE);
CREATE TABLE user_key_wraps (user_id uuid REFERENCES users(id) ON DELETE CASCADE);
