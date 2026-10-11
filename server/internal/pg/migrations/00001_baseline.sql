-- +goose Up
-- hasalad's baseline schema (spec 02 §5.3). It replaces ledgerd's 00001–00035:
-- the database is fresh (no import path), so the tables the surgery retired
-- (spec 02 §2.5: inbound addresses, quarantine, diagnostics, templates, the
-- crowd dictionary, samples, consent, Web Push, Expo push tokens, the Gmail
-- broker, SMTP counters, ledgerd's waitlist) are simply absent.
--
-- What is here is the schema the code in this tree uses, with spec 02's
-- integrity guarantees applied now:
--   * op_log is frame v3 only: hasala_frame_is_sealed (spec 01 §8.2, byte for
--     byte; serve checks md5(prosrc) at startup), the AAD-position CHECK, the
--     hot-only and edit-only CHECKs, the writer foreign key, head_sig, and an
--     append-only trigger;
--   * key_history is append-only and writers revoke-once, by trigger;
--   * the runtime role has no UPDATE/DELETE on op_log or key_history, no
--     DELETE on writers and no write on goose_db_version (spec 02 D-6).
-- The account model (users, webauthn_*, sessions, writer registration,
-- user_keys and user_key_wraps, invite_codes) is still ledgerd's shape. WS-3
-- (auth, keys, sessions) and 07 (invites, waitlist, mail) replace those tables
-- with spec 02 §5.3's before the first QA deploy. Numbers 00002–00029 are
-- reserved for changes made before that deploy and are squashed back into this
-- file before it; after it, migrations are forward-only.
--
-- Applied as hasala_migrate (the schema owner) by `hasalad migrate`; served as
-- hasala_runtime, which serve checks is not the owner (internal/pg/owner.go).

-- +goose StatementBegin
DO $$
BEGIN
  IF current_user <> 'hasala_migrate' THEN
    RAISE EXCEPTION 'the baseline must be applied as hasala_migrate, not %', current_user;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hasala_runtime') THEN
    RAISE EXCEPTION 'role hasala_runtime must exist before the baseline is applied';
  END IF;
END $$;
-- +goose StatementEnd

-- ── accounts ────────────────────────────────────────────────────────────────
-- ledgerd's identity-keyed account. Only 'passkey' identities can be created
-- (auth.UpsertUserInvited from the passkey register ceremony); WS-3 replaces
-- this table with spec 02 §5.3's email-keyed account (D-4).
CREATE TABLE users (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  idp          text NOT NULL,
  idp_sub_hash bytea NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  status       text NOT NULL DEFAULT 'active',
  CONSTRAINT users_idp_is_closed CHECK (idp IN ('passkey')),
  CONSTRAINT users_idp_sub_hash_is_sha256 CHECK (octet_length(idp_sub_hash) = 32),
  CONSTRAINT users_identity_uniq UNIQUE (idp, idp_sub_hash),
  CONSTRAINT users_status_is_closed CHECK (status IN ('active','suspended'))
);

CREATE TABLE webauthn_credentials (
  credential_id   bytea PRIMARY KEY,
  user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  user_handle     bytea NOT NULL,
  public_key      bytea NOT NULL,
  sign_count      bigint NOT NULL DEFAULT 0,
  aaguid          bytea,
  transports      text,
  backup_eligible boolean NOT NULL,
  backup_state    boolean NOT NULL,
  created_at      timestamptz NOT NULL,
  last_used_at    timestamptz,
  CONSTRAINT webauthn_credentials_id_is_bounded CHECK (octet_length(credential_id) BETWEEN 16 AND 1023),
  CONSTRAINT webauthn_credentials_handle_is_256_bits CHECK (octet_length(user_handle) = 32),
  CONSTRAINT webauthn_credentials_user_cred_uniq UNIQUE (user_id, credential_id)
);
CREATE INDEX webauthn_credentials_user_idx ON webauthn_credentials (user_id);

CREATE TABLE webauthn_ceremonies (
  id               text PRIMARY KEY,
  kind             text NOT NULL,
  user_id          uuid REFERENCES users(id) ON DELETE CASCADE,
  user_handle      bytea,
  session_data     jsonb NOT NULL,
  invite_code_hash bytea,
  created_at       timestamptz NOT NULL,
  expires_at       timestamptz NOT NULL,
  CONSTRAINT webauthn_ceremonies_kind_is_closed CHECK (kind IN ('register','login','add')),
  CONSTRAINT webauthn_ceremonies_ttl CHECK (expires_at > created_at AND expires_at <= created_at + interval '5 minutes')
);
CREATE INDEX webauthn_ceremonies_expiry_idx ON webauthn_ceremonies (expires_at);

-- ledgerd's invite codes (spec 07 §2.5 replaces this table with its invite
-- state machine). The note is erased when the redeeming account is deleted.
CREATE TABLE invite_codes (
  code_hash   bytea PRIMARY KEY,
  note        text,
  created_at  timestamptz NOT NULL,
  redeemed_at timestamptz,
  redeemed_by uuid REFERENCES users(id) ON DELETE SET NULL,
  CONSTRAINT invite_codes_hash_is_256_bits CHECK (octet_length(code_hash) = 32),
  CONSTRAINT invite_codes_redeemer_implies_redemption CHECK (redeemed_by IS NULL OR redeemed_at IS NOT NULL)
);
CREATE INDEX invite_codes_unredeemed_idx ON invite_codes (created_at) WHERE redeemed_at IS NULL;

-- +goose StatementBegin
CREATE FUNCTION forget_invite_note() RETURNS trigger AS $$
BEGIN
  NEW.note := NULL;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
-- +goose StatementEnd
CREATE TRIGGER invite_note_dies_with_the_account BEFORE UPDATE ON invite_codes
  FOR EACH ROW WHEN (OLD.redeemed_by IS NOT NULL AND NEW.redeemed_by IS NULL)
  EXECUTE FUNCTION forget_invite_note();

-- ── device writers (before sessions and op_log: both reference them) ────────
-- Every writer is a device writer with an Ed25519 key (ledgerd's keyless
-- server "ingest" writer is gone with the ingest path). The DAK column and the
-- ios-<uuid> writer-id grammar of spec 02 §5.3 arrive with WS-3's enrolment.
CREATE TABLE writers (
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  writer_id     text NOT NULL,
  kind          text NOT NULL DEFAULT 'device',
  pubkey        bytea NOT NULL,
  registered_at timestamptz NOT NULL,
  revoked_at    timestamptz,
  PRIMARY KEY (user_id, writer_id),
  CONSTRAINT writers_writer_id_charset CHECK (writer_id ~ '^[A-Za-z0-9._-]{1,64}$'),
  CONSTRAINT writers_kind_is_device CHECK (kind = 'device'),
  CONSTRAINT writers_key_is_ed25519 CHECK (octet_length(pubkey) = 32),
  CONSTRAINT writers_revocation_follows_registration CHECK (revoked_at IS NULL OR revoked_at >= registered_at)
);
CREATE UNIQUE INDEX writers_pubkey_uniq ON writers (user_id, pubkey);

-- +goose StatementBegin
CREATE FUNCTION writers_guard() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'TRUNCATE' THEN
    RAISE EXCEPTION 'writers: TRUNCATE is refused' USING ERRCODE = 'check_violation';
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL
       AND (NEW.user_id, NEW.writer_id, NEW.kind, NEW.pubkey, NEW.registered_at)
         = (OLD.user_id, OLD.writer_id, OLD.kind, OLD.pubkey, OLD.registered_at) THEN
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
CREATE TRIGGER writers_no_rewrite BEFORE UPDATE OR DELETE ON writers
  FOR EACH ROW EXECUTE FUNCTION writers_guard();
CREATE TRIGGER writers_no_truncate BEFORE TRUNCATE ON writers
  FOR EACH STATEMENT EXECUTE FUNCTION writers_guard();

-- +goose StatementBegin
CREATE FUNCTION append_only_while_user_exists() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'TRUNCATE' THEN
    RAISE EXCEPTION '%: append-only, TRUNCATE is refused', TG_TABLE_NAME USING ERRCODE = 'check_violation';
  END IF;
  IF TG_OP = 'UPDATE' THEN
    RAISE EXCEPTION '%: append-only, UPDATE is refused', TG_TABLE_NAME USING ERRCODE = 'check_violation';
  END IF;
  -- The only legitimate DELETE is the RI cascade from users, which runs after the users row is gone.
  IF EXISTS (SELECT 1 FROM users WHERE id = OLD.user_id) THEN
    RAISE EXCEPTION '%: append-only, DELETE refused while user % exists', TG_TABLE_NAME, OLD.user_id
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql;
-- +goose StatementEnd

-- The append-only key-history log a peer device audits for key substitution.
CREATE TABLE key_history (
  id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id   uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  writer_id text NOT NULL,
  pubkey    bytea,
  event     text NOT NULL,
  at        timestamptz NOT NULL,
  CONSTRAINT key_history_event_is_closed CHECK (event IN ('registered','revoked','recovery_registered')),
  CONSTRAINT key_history_pubkey_is_ed25519 CHECK (pubkey IS NULL OR octet_length(pubkey) = 32)
);
CREATE INDEX key_history_user_idx ON key_history (user_id, id);
CREATE TRIGGER key_history_no_rewrite BEFORE UPDATE OR DELETE ON key_history
  FOR EACH ROW EXECUTE FUNCTION append_only_while_user_exists();
CREATE TRIGGER key_history_no_truncate BEFORE TRUNCATE ON key_history
  FOR EACH STATEMENT EXECUTE FUNCTION append_only_while_user_exists();

CREATE TABLE writer_challenges (
  nonce      bytea PRIMARY KEY,
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  issued_at  timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  used_at    timestamptz,
  CONSTRAINT writer_challenges_nonce_is_256_bits CHECK (octet_length(nonce) = 32),
  CONSTRAINT writer_challenges_ttl CHECK (expires_at > issued_at AND expires_at <= issued_at + interval '5 minutes')
);
CREATE INDEX writer_challenges_expiry_idx ON writer_challenges (expires_at);

-- ── sessions ────────────────────────────────────────────────────────────────
CREATE TABLE sessions (
  token_hash    bytea PRIMARY KEY,
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  credential_id bytea REFERENCES webauthn_credentials(credential_id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL,
  revoked_at    timestamptz,
  CONSTRAINT sessions_hash_is_256_bits CHECK (octet_length(token_hash) = 32),
  CONSTRAINT sessions_cap_follows_creation CHECK (expires_at > created_at)
);
CREATE INDEX sessions_user_idx ON sessions (user_id);
CREATE INDEX sessions_credential_idx ON sessions (credential_id) WHERE credential_id IS NOT NULL;
CREATE INDEX sessions_reap_idx ON sessions (expires_at);

-- A deleted account's live session tokens answer 410 account_deleted (not 401)
-- until they would have expired, so a device may wipe on exactly that answer.
CREATE TABLE deleted_account_sessions (
  token_hash bytea PRIMARY KEY,
  deleted_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  CONSTRAINT deleted_account_sessions_hash_is_256_bits CHECK (octet_length(token_hash) = 32)
);
CREATE INDEX deleted_account_sessions_expiry_idx ON deleted_account_sessions (expires_at);

-- +goose StatementBegin
CREATE FUNCTION tombstone_account_sessions() RETURNS trigger AS $$
BEGIN
  INSERT INTO deleted_account_sessions (token_hash, deleted_at, expires_at)
  SELECT s.token_hash, now(), s.expires_at
    FROM sessions s
   WHERE s.user_id = OLD.id AND s.revoked_at IS NULL
  ON CONFLICT (token_hash) DO NOTHING;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql;
-- +goose StatementEnd
CREATE TRIGGER users_tombstone_sessions BEFORE DELETE ON users
  FOR EACH ROW EXECUTE FUNCTION tombstone_account_sessions();

-- ledgerd's account-deletion nonce; WS-3 replaces it with step_up_challenges.
CREATE TABLE account_deletion_challenges (
  nonce      bytea PRIMARY KEY,
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  issued_at  timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  used_at    timestamptz,
  CONSTRAINT account_deletion_challenges_nonce_is_256_bits CHECK (octet_length(nonce) = 32)
);
CREATE INDEX account_deletion_challenges_expiry_idx ON account_deletion_challenges (expires_at);

-- ── account key material (ledgerd's shape; WS-3 replaces both with
--    account_keys and account_key_wraps, spec 02 §5.3) ──────────────────────
CREATE TABLE user_keys (
  user_id         uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  ingest_pubkey   bytea NOT NULL,
  recovery_pubkey bytea NOT NULL,
  wrapped_keys    bytea NOT NULL,
  key_version     integer NOT NULL,
  created_at      timestamptz NOT NULL,
  updated_at      timestamptz NOT NULL,
  CONSTRAINT user_keys_pubkey_is_256_bits CHECK (octet_length(ingest_pubkey) = 32),
  CONSTRAINT user_keys_recovery_pubkey_is_256_bits CHECK (octet_length(recovery_pubkey) = 32),
  CONSTRAINT user_keys_version_is_positive CHECK (key_version > 0),
  CONSTRAINT user_keys_wrapped_is_bounded CHECK (octet_length(wrapped_keys) BETWEEN 32 AND 4096)
);

CREATE TABLE user_key_wraps (
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  credential_id bytea NOT NULL REFERENCES webauthn_credentials(credential_id) ON DELETE CASCADE,
  wrapped       bytea NOT NULL,
  wrap_version  integer NOT NULL,
  created_at    timestamptz NOT NULL,
  PRIMARY KEY (user_id, credential_id),
  CONSTRAINT user_key_wraps_version_is_positive CHECK (wrap_version > 0),
  CONSTRAINT user_key_wraps_wrapped_is_bounded CHECK (octet_length(wrapped) BETWEEN 32 AND 4096)
);

-- ── the op log ──────────────────────────────────────────────────────────────
-- spec 01 §8.2, verbatim (VERIFIED in PostgreSQL 17.11 against Go LooksSealed on 32 cases, V-F).
-- The 8 checks of LooksSealed in order; CASE fixes the order so a short input yields false.
-- Check 3 is 1 ≤ epoch ≤ 2³¹−1 (N-01). md5(prosrc) = cecad4a55664c960ee9e1e301a76c30d (O7).
-- op_log.blob MUST stay NOT NULL: this function is STRICT, so a NULL blob would pass the CHECK
-- (spec 01 §8.2, review N-02). Do not relax either.
-- +goose StatementBegin
CREATE FUNCTION hasala_frame_is_sealed(b bytea) RETURNS boolean
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $fn$
  SELECT CASE
    WHEN octet_length(b) NOT IN (1024, 4096, 16384, 65536, 262144, 524288, 1048576) THEN false
    WHEN get_byte(b, 0) <> 3 THEN false
    WHEN get_byte(b, 1) >= 128 OR substring(b FROM 2 FOR 4) = decode('00000000', 'hex') THEN false
    WHEN get_byte(b, 5) * 256 + get_byte(b, 6) + 67 > octet_length(b) THEN false
    WHEN substring(b FROM get_byte(b, 5) * 256 + get_byte(b, 6) + 8 FOR 12)
         = decode('000000000000000000000000', 'hex') THEN false
    WHEN substring(b FROM octet_length(b) - 15 FOR 16)
         = decode('00000000000000000000000000000000', 'hex') THEN false
    WHEN substring(b FROM octet_length(b) - 47 FOR 32)
         = decode('0000000000000000000000000000000000000000000000000000000000000000', 'hex') THEN false
    WHEN substring(b FROM get_byte(b, 5) * 256 + get_byte(b, 6) + 24 FOR 3)
         = decode('1f8b08', 'hex') THEN false
    ELSE true
  END
$fn$;
-- +goose StatementEnd

-- One counter row per user, NOT a sequence: the appending transaction UPDATEs
-- it, so commit order is seq order and a rolled-back append leaves no hole
-- (oplog.Appender.appendRows).
CREATE TABLE oplog_seq (
  user_id  uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  next_seq bigint NOT NULL DEFAULT 1,
  CONSTRAINT oplog_seq_is_positive CHECK (next_seq >= 1)
);

CREATE TABLE op_log (
  user_id        uuid   NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  seq            bigint NOT NULL,
  stream         text   NOT NULL,
  writer_id      text   NOT NULL,
  writer_counter bigint NOT NULL,
  type_flag      text   NOT NULL,
  blob           bytea  NOT NULL,     -- NOT NULL is load-bearing for op_log_blob_is_sealed (N-02)
  size_bucket    int    NOT NULL,
  blob_hash      bytea  NOT NULL,
  prev_hash      bytea  NOT NULL,
  -- spec 01 §7.1 (R-02): the DWK signature over HeadMessage, on the LAST row of each upload batch
  -- only; NULL on the others. Which rows end a batch is enforced by the upload path (WS-2).
  head_sig       bytea,
  created_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, seq),
  CONSTRAINT op_log_position_uniq UNIQUE (user_id, writer_id, stream, writer_counter),
  CONSTRAINT op_log_writer_fk FOREIGN KEY (user_id, writer_id)
    REFERENCES writers (user_id, writer_id) ON DELETE CASCADE,
  CONSTRAINT op_log_stream_is_hot CHECK (stream = 'hot'),
  CONSTRAINT op_log_type_flag_is_edit CHECK (type_flag = 'edit'),
  CONSTRAINT op_log_seq_is_positive CHECK (seq >= 1 AND writer_counter >= 1),
  CONSTRAINT op_log_bucket_is_on_the_ladder CHECK (
    size_bucket IN (1024, 4096, 16384, 65536, 262144, 524288, 1048576)),
  CONSTRAINT op_log_blob_fills_bucket CHECK (octet_length(blob) = size_bucket),
  CONSTRAINT op_log_hashes_are_sha256 CHECK (octet_length(blob_hash) = 32 AND octet_length(prev_hash) = 32),
  CONSTRAINT op_log_head_sig_is_ed25519 CHECK (head_sig IS NULL OR octet_length(head_sig) = 64),
  -- Frame v3 (spec 01 §6.1): [0x03][u32be key_epoch][u16be aad_len][aad][nonce 12][ct][tag 16].
  -- get_byte is 0-based, substring is 1-based.
  CONSTRAINT op_log_blob_is_sealed CHECK (hasala_frame_is_sealed(blob)),
  -- DEVIATION from spec 02 §5.3's text, which relies on "the bucket CHECKs above" to keep
  -- get_byte(blob, 6) in range: PostgreSQL evaluates CHECK constraints in NAME order, so this one
  -- ("op_log_aad…") runs before op_log_blob_fills_bucket and a 1-byte or empty blob raised a
  -- get_byte range error (2202E) instead of a CHECK violation (spec 01 AT-P3). The CASE guard is the
  -- only change; for any frame of 7 bytes or more the comparison is spec 02's, byte for byte.
  CONSTRAINT op_log_aad_matches_position CHECK (CASE
    WHEN octet_length(blob) < 7 THEN false
    ELSE substring(blob FROM 8 FOR get_byte(blob, 5) * 256 + get_byte(blob, 6))
      = convert_to(user_id::text || '|' || stream || '|' || writer_id || '|' || writer_counter::text, 'UTF8') END)
);
CREATE INDEX op_log_stream_idx ON op_log (user_id, stream, seq);
CREATE INDEX op_log_writer_head_idx ON op_log (user_id, writer_id, writer_counter DESC);
CREATE TRIGGER op_log_no_rewrite BEFORE UPDATE OR DELETE ON op_log
  FOR EACH ROW EXECUTE FUNCTION append_only_while_user_exists();
CREATE TRIGGER op_log_no_truncate BEFORE TRUNCATE ON op_log
  FOR EACH STATEMENT EXECUTE FUNCTION append_only_while_user_exists();

-- ── storage budget (resource vocabulary, spec 02 §5.4) ──────────────────────
CREATE TABLE account_usage (
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  resource   text NOT NULL,
  amount     bigint NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, resource),
  CONSTRAINT account_usage_resource_is_closed CHECK (resource IN ('oplog_hot_bytes')),
  CONSTRAINT account_usage_amount_is_non_negative CHECK (amount >= 0)
);

CREATE TABLE account_limits (
  user_id     uuid REFERENCES users(id) ON DELETE CASCADE,
  oplog_bytes bigint NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT account_limits_oplog_bytes_is_non_negative CHECK (oplog_bytes >= 0)
);
CREATE UNIQUE INDEX account_limits_one_row_per_account ON account_limits (user_id) WHERE user_id IS NOT NULL;
CREATE UNIQUE INDEX account_limits_one_default_row ON account_limits ((true)) WHERE user_id IS NULL;
INSERT INTO account_limits (user_id, oplog_bytes) VALUES (NULL, 256 * 1024 * 1024);
-- +goose StatementBegin
CREATE FUNCTION account_limits_keep_the_default_row() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'account_limits: the default policy row cannot be deleted; UPDATE it instead'
    USING ERRCODE = 'check_violation';
END;
$$ LANGUAGE plpgsql;
-- +goose StatementEnd
CREATE TRIGGER account_limits_default_row_is_permanent BEFORE DELETE ON account_limits
  FOR EACH ROW WHEN (OLD.user_id IS NULL) EXECUTE FUNCTION account_limits_keep_the_default_row();

CREATE TABLE account_refusals (
  user_id  uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  day      date NOT NULL,
  resource text NOT NULL,
  count    bigint NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, day, resource),
  CONSTRAINT account_refusals_resource_is_closed CHECK (
    resource IN ('oplog_hot_bytes','upload_bytes','headroom','suspended')),
  CONSTRAINT account_refusals_count_is_non_negative CHECK (count >= 0)
);
CREATE INDEX account_refusals_day_idx ON account_refusals (day);

-- ── push (spec 02 §5.3; the routes and sender are WS-4's) ───────────────────
-- One APNs token per device writer, bound to the session that registered it:
-- logout deletes it with the session (spec 02 §9.3, F4).
CREATE TABLE apns_tokens (
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  writer_id    text NOT NULL,
  session_hash bytea NOT NULL REFERENCES sessions(token_hash) ON DELETE CASCADE,
  token_hex    text NOT NULL,
  environment  text NOT NULL,
  created_at   timestamptz NOT NULL,
  updated_at   timestamptz NOT NULL,
  PRIMARY KEY (user_id, writer_id),
  CONSTRAINT apns_tokens_writer_fk FOREIGN KEY (user_id, writer_id)
    REFERENCES writers (user_id, writer_id) ON DELETE CASCADE,
  CONSTRAINT apns_tokens_token_is_hex CHECK (token_hex ~ '^([0-9a-f]{2}){32,100}$'),
  CONSTRAINT apns_tokens_token_uniq UNIQUE (token_hex),
  CONSTRAINT apns_tokens_environment_is_closed CHECK (environment IN ('sandbox','production'))
);
CREATE INDEX apns_tokens_session_idx ON apns_tokens (session_hash);

-- ── privileges (spec 02 §5.3, D-6) ──────────────────────────────────────────
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO hasala_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO hasala_runtime;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO hasala_runtime;
REVOKE UPDATE, DELETE ON op_log, key_history FROM hasala_runtime;
REVOKE DELETE ON writers FROM hasala_runtime;
REVOKE INSERT, UPDATE, DELETE ON goose_db_version FROM hasala_runtime;
GRANT SELECT ON goose_db_version TO hasala_runtime;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO hasala_runtime;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO hasala_runtime;

-- +goose Down
-- Forward-only after the first QA deploy. Down exists for pgtest only. It drops
-- what Up created and leaves goose_db_version, which goose updates after this.
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM hasala_runtime;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE USAGE, SELECT ON SEQUENCES FROM hasala_runtime;
DROP TABLE apns_tokens, account_refusals, account_limits, account_usage, op_log, oplog_seq,
  user_key_wraps, user_keys, account_deletion_challenges, deleted_account_sessions, sessions,
  writer_challenges, key_history, writers, invite_codes, webauthn_ceremonies,
  webauthn_credentials, users;
DROP FUNCTION hasala_frame_is_sealed(bytea), account_limits_keep_the_default_row(),
  tombstone_account_sessions(), append_only_while_user_exists(), writers_guard(),
  forget_invite_note();
