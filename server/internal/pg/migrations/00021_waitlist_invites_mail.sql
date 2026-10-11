-- +goose Up
-- Spec 07's public half: banks, the beta waitlist, invites, bank requests, the
-- email outbox and log, and the operator audit log (spec 07 §2.2–§2.6, §2.8,
-- §2.9; the waitlist_submit function of §5.3 step 9). Numbered in WS-4's range
-- (00020–00029) because this lane builds them; squashed into
-- 00001_baseline.sql before the first QA deploy like every 00002–00029 file.
--
-- Not here yet (each a TODO for full parity, not a stub):
--   * testflight_enrolments and testflight_status (spec 07 §2.7): the App Store
--     Connect automation is not built; TestFlight testers are added by hand.
--   * §2.10's per-role grants: hasala_console does not exist yet (05's role
--     split), so the baseline's default privileges (hasala_runtime DML on every
--     table) still apply. admin_audit's trigger keeps it append-only regardless.
--
-- invite_codes is REPLACED by spec 07 §2.5's state machine (the table is empty
-- before the first deploy; there is no data to carry).

-- +goose StatementBegin
DO $$
BEGIN
  IF current_user <> 'hasala_migrate' THEN
    RAISE EXCEPTION 'migrations must be applied as hasala_migrate, not %', current_user;
  END IF;
END $$;
-- +goose StatementEnd

-- ── banks (spec 07 §2.2) ────────────────────────────────────────────────────
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
-- The operator edits the catalog; the seed is not re-applied.
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

-- ── waitlist (spec 07 §2.3, §2.4) ───────────────────────────────────────────
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

CREATE TABLE waitlist_tokens (
  token_hash bytea PRIMARY KEY,
  entry_id   uuid NOT NULL REFERENCES waitlist_entries(id) ON DELETE CASCADE,
  purpose    text NOT NULL,
  created_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  used_at    timestamptz,
  CONSTRAINT waitlist_tokens_hash_is_256_bits CHECK (octet_length(token_hash) = 32),
  CONSTRAINT waitlist_tokens_purpose_is_closed CHECK (purpose IN ('confirm','leave')),
  CONSTRAINT waitlist_tokens_ttl CHECK (expires_at > created_at AND expires_at <= created_at
    + CASE purpose WHEN 'confirm' THEN interval '7 days' ELSE interval '90 days' END)
);
CREATE INDEX waitlist_tokens_entry_idx ON waitlist_tokens (entry_id);
CREATE INDEX waitlist_tokens_expiry_idx ON waitlist_tokens (expires_at);

-- ── invites (spec 07 §2.5, replacing the baseline's ledgerd table) ──────────
DROP TRIGGER invite_note_dies_with_the_account ON invite_codes;
DROP TABLE invite_codes;
DROP FUNCTION forget_invite_note();

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

-- ── bank requests (spec 07 §2.6) ────────────────────────────────────────────
CREATE TABLE bank_requests (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  bank_slug         text REFERENCES banks(slug) ON DELETE RESTRICT,
  other_key         text,
  other_text        text,
  source            text NOT NULL,
  user_id           uuid REFERENCES users(id) ON DELETE CASCADE,
  waitlist_entry_id uuid REFERENCES waitlist_entries(id) ON DELETE CASCADE,
  created_at        timestamptz NOT NULL,
  notified_at       timestamptz,
  CONSTRAINT bank_requests_one_bank CHECK (num_nonnulls(bank_slug, other_key) = 1),
  CONSTRAINT bank_requests_other_shape CHECK ((other_key IS NULL) = (other_text IS NULL)
    AND (other_text IS NULL OR char_length(other_text) BETWEEN 1 AND 64)
    AND (other_key IS NULL OR char_length(other_key) BETWEEN 1 AND 64)),
  CONSTRAINT bank_requests_source_is_closed CHECK (source IN ('web','web_waitlist','app')),
  CONSTRAINT bank_requests_one_subject CHECK (num_nonnulls(user_id, waitlist_entry_id) <= 1),
  CONSTRAINT bank_requests_anonymous_web CHECK ((source = 'web') = (user_id IS NULL AND waitlist_entry_id IS NULL)),
  CONSTRAINT bank_requests_app_has_user CHECK (source <> 'app' OR user_id IS NOT NULL)
);
CREATE UNIQUE INDEX bank_requests_user_bank_uniq
  ON bank_requests (user_id, (coalesce(bank_slug, 'other:' || other_key))) WHERE user_id IS NOT NULL;
CREATE UNIQUE INDEX bank_requests_entry_bank_uniq
  ON bank_requests (waitlist_entry_id, (coalesce(bank_slug, 'other:' || other_key))) WHERE waitlist_entry_id IS NOT NULL;
CREATE INDEX bank_requests_bank_idx ON bank_requests (bank_slug, created_at) WHERE bank_slug IS NOT NULL;
CREATE INDEX bank_requests_other_idx ON bank_requests (other_key, created_at) WHERE other_key IS NOT NULL;

-- ── mail_log, the outbox and the email log (spec 07 §2.8) ───────────────────
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

-- ── admin_audit (spec 07 §2.9) ──────────────────────────────────────────────
CREATE TABLE admin_audit (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at          timestamptz NOT NULL DEFAULT now(),
  actor       text NOT NULL,
  action      text NOT NULL,
  target_kind text,
  target_id   text,
  params      jsonb NOT NULL DEFAULT '{}',
  result      text NOT NULL,
  error_code  text,
  request_id  text,
  client_addr inet,
  CONSTRAINT admin_audit_actor_shape CHECK (actor ~ '^(tailnet:[!-~]{1,128}|cli:[a-z_][a-z0-9_-]{0,31}|system:[a-z_]{1,32})$'),
  CONSTRAINT admin_audit_action_shape CHECK (action ~ '^[a-z_]+(\.[a-z_]+){1,3}$'),
  CONSTRAINT admin_audit_target_kind_is_closed CHECK (target_kind IS NULL OR target_kind IN
    ('waitlist_entry','invite','enrolment','bank','bank_other','account','mail','system')),
  CONSTRAINT admin_audit_target_bounded CHECK (target_id IS NULL OR char_length(target_id) <= 64),
  CONSTRAINT admin_audit_params_bounded CHECK (octet_length(params::text) <= 2048),
  CONSTRAINT admin_audit_result_is_closed CHECK (result IN ('ok','refused','error')),
  CONSTRAINT admin_audit_error_code_shape CHECK (error_code IS NULL OR error_code ~ '^[a-z_]{1,48}$'),
  CONSTRAINT admin_audit_request_id_shape CHECK (request_id IS NULL OR request_id ~ '^[0-9a-f]{16}$')
);
CREATE INDEX admin_audit_at_idx ON admin_audit (at DESC);
CREATE INDEX admin_audit_target_idx ON admin_audit (target_kind, target_id, at DESC);
-- +goose StatementBegin
CREATE FUNCTION admin_audit_guard() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'TRUNCATE' THEN
    RAISE EXCEPTION 'admin_audit: TRUNCATE is refused' USING ERRCODE = 'check_violation';
  END IF;
  IF TG_OP = 'UPDATE' THEN
    RAISE EXCEPTION 'admin_audit: append-only, UPDATE is refused' USING ERRCODE = 'check_violation';
  END IF;
  IF OLD.at >= now() - interval '400 days' THEN
    RAISE EXCEPTION 'admin_audit: rows younger than 400 days are kept' USING ERRCODE = 'check_violation';
  END IF;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql;
-- +goose StatementEnd
CREATE TRIGGER admin_audit_append_only BEFORE UPDATE OR DELETE ON admin_audit
  FOR EACH ROW EXECUTE FUNCTION admin_audit_guard();
CREATE TRIGGER admin_audit_no_truncate BEFORE TRUNCATE ON admin_audit
  FOR EACH STATEMENT EXECUTE FUNCTION admin_audit_guard();
REVOKE UPDATE ON admin_audit FROM hasala_runtime;

-- ── waitlist_derive_request: an entry's web_waitlist bank request ───────────
-- A confirmed entry that chose "Another bank" with a name, or a catalog bank
-- that is not supported yet, carries one web_waitlist request (spec 07 §2.6,
-- §5.3, §5.4). Re-derived whenever a confirmed entry's choice changes.
-- +goose StatementBegin
CREATE FUNCTION waitlist_derive_request(p_entry uuid) RETURNS void AS $$
DECLARE
  e waitlist_entries%ROWTYPE;
  supported boolean;
BEGIN
  SELECT * INTO e FROM waitlist_entries WHERE id = p_entry;
  DELETE FROM bank_requests WHERE waitlist_entry_id = p_entry;
  IF e.id IS NULL OR e.state <> 'confirmed' THEN
    RETURN;
  END IF;
  IF e.other_bank IS NOT NULL THEN
    INSERT INTO bank_requests (other_key, other_text, source, waitlist_entry_id, created_at)
      VALUES (e.other_bank_key, e.other_bank, 'web_waitlist', e.id, now());
  ELSIF e.bank_slug IS NOT NULL THEN
    SELECT status = 'supported' INTO supported FROM banks WHERE slug = e.bank_slug;
    IF NOT coalesce(supported, false) THEN
      INSERT INTO bank_requests (bank_slug, source, waitlist_entry_id, created_at)
        VALUES (e.bank_slug, 'web_waitlist', e.id, now());
    END IF;
  END IF;
END;
$$ LANGUAGE plpgsql;
-- +goose StatementEnd

-- ── waitlist_submit (spec 07 §5.3 step 9, §6.5) ─────────────────────────────
-- One round trip for every valid submission: the row change of §5.3's table,
-- then exactly one mail_log row (queued, or suppressed when a cap holds; past
-- the suppressed-row cap nothing is written). The answer to the caller is the
-- same whatever this returns; the outcome word is for the metric only.
-- +goose StatementBegin
CREATE FUNCTION waitlist_submit(p_tag bytea, p_email text, p_hint text, p_bank text,
    p_other_text text, p_other_key text, p_source text) RETURNS text AS $$
DECLARE
  e         waitlist_entries%ROWTYPE;
  has_acct  boolean;
  v_kind    text;
  v_params  jsonb := '{}';
  v_entry   uuid;
  v_outcome text;
  v_capped  boolean := false;
  recent10  int;
  recent24  int;
  supp1h    int;
BEGIN
  SELECT EXISTS (SELECT 1 FROM users WHERE email_norm = p_email) INTO has_acct;
  SELECT * INTO e FROM waitlist_entries WHERE email_tag = p_tag FOR UPDATE;

  IF e.id IS NULL THEN
    IF has_acct THEN
      v_kind := 'waitlist_has_account'; v_outcome := 'has_account';
    ELSE
      INSERT INTO waitlist_entries (email_tag, email_norm, state, bank_slug, other_bank, other_bank_key,
                                    source, created_at, updated_at)
        VALUES (p_tag, p_email, 'pending', p_bank, p_other_text, p_other_key, p_source, now(), now())
        ON CONFLICT (email_tag) DO NOTHING
        RETURNING * INTO e;
      IF e.id IS NULL THEN
        -- A concurrent submission of the same address won the insert.
        SELECT * INTO e FROM waitlist_entries WHERE email_tag = p_tag FOR UPDATE;
      END IF;
      v_kind := 'waitlist'; v_outcome := 'new';
    END IF;
  ELSIF e.state = 'pending' THEN
    UPDATE waitlist_entries SET bank_slug = p_bank, other_bank = p_other_text, other_bank_key = p_other_key,
           email_norm = p_email, updated_at = now()
     WHERE id = e.id RETURNING * INTO e;
    v_kind := 'waitlist'; v_outcome := 'pending';
  ELSIF e.state = 'confirmed' THEN
    UPDATE waitlist_entries SET bank_slug = p_bank, other_bank = p_other_text, other_bank_key = p_other_key,
           updated_at = now()
     WHERE id = e.id RETURNING * INTO e;
    PERFORM waitlist_derive_request(e.id);
    v_kind := 'waitlist_already'; v_params := '{"variant":"confirmed"}'; v_outcome := 'confirmed';
  ELSIF e.state = 'invited' THEN
    v_kind := 'waitlist_already'; v_params := '{"variant":"invited"}'; v_outcome := 'invited';
  ELSIF has_acct THEN
    -- joined, and the account still holds the address
    v_kind := 'waitlist_has_account'; v_outcome := 'joined';
    e.id := NULL;
  ELSE
    -- joined, the account deleted since: a fresh pending entry
    UPDATE waitlist_entries SET email_norm = p_email, state = 'pending', bank_slug = p_bank,
           other_bank = p_other_text, other_bank_key = p_other_key, source = p_source,
           updated_at = now(), confirm_sent_count = 0, last_confirm_sent_at = NULL,
           confirmed_at = NULL, invited_at = NULL, joined_at = NULL
     WHERE id = e.id RETURNING * INTO e;
    v_kind := 'waitlist'; v_outcome := 'reset';
  END IF;

  IF v_kind = 'waitlist_has_account' THEN
    v_entry := NULL;
  ELSE
    v_entry := e.id;
  END IF;

  -- Caps (spec 07 §6.5): per address on the waitlist lane, and per entry for
  -- the confirmation.
  SELECT count(*) FILTER (WHERE created_at > now() - interval '10 minutes'),
         count(*)
    INTO recent10, recent24
    FROM mail_log
   WHERE recipient_tag = p_tag AND lane = 'waitlist' AND status <> 'suppressed'
     AND created_at > now() - interval '24 hours';
  IF recent10 >= 1 OR recent24 >= 3 THEN
    v_capped := true;
  END IF;
  IF v_kind = 'waitlist' AND e.confirm_sent_count >= 5 THEN
    v_capped := true;
  END IF;

  IF v_capped THEN
    SELECT count(*) INTO supp1h FROM mail_log
     WHERE recipient_tag = p_tag AND status = 'suppressed' AND created_at > now() - interval '1 hour';
    IF supp1h >= 1 THEN
      RETURN v_outcome || '_dropped';
    END IF;
    INSERT INTO mail_log (kind, lane, recipient, recipient_tag, recipient_hint, waitlist_entry_id, params,
                          status, created_at, final_at)
      VALUES (v_kind, 'waitlist', p_email, p_tag, p_hint, v_entry, v_params, 'suppressed', now(), now());
    RETURN v_outcome || '_suppressed';
  END IF;

  IF v_kind = 'waitlist' THEN
    UPDATE waitlist_entries SET confirm_sent_count = confirm_sent_count + 1, last_confirm_sent_at = now()
     WHERE id = e.id;
  END IF;
  INSERT INTO mail_log (kind, lane, recipient, recipient_tag, recipient_hint, waitlist_entry_id, params,
                        status, next_attempt_at, created_at)
    VALUES (v_kind, 'waitlist', p_email, p_tag, p_hint, v_entry, v_params, 'queued', now(), now());
  PERFORM pg_notify('hasala_mail', '');
  RETURN v_outcome;
END;
$$ LANGUAGE plpgsql;
-- +goose StatementEnd

-- +goose Down
-- pgtest only (MigrateDown): back to the baseline's invite_codes.
DROP FUNCTION waitlist_submit(bytea, text, text, text, text, text, text), waitlist_derive_request(uuid);
DROP TABLE admin_audit, mail_log, bank_requests;
DROP TABLE invite_codes;
DROP FUNCTION admin_audit_guard(), forget_invite_details();
DROP TABLE waitlist_tokens, waitlist_entries, banks;
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
