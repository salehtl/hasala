-- +goose Up

-- +goose StatementBegin
DO $$
BEGIN
  IF current_user <> 'hasala_migrate' THEN
    RAISE EXCEPTION 'migrations must be applied as hasala_migrate, not %', current_user;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE OR REPLACE FUNCTION waitlist_submit(p_tag bytea, p_email text, p_hint text, p_bank text,
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
    v_kind := 'waitlist_has_account'; v_outcome := 'joined';
    e.id := NULL;
  ELSE
    UPDATE waitlist_entries SET email_norm = p_email, state = 'pending', bank_slug = p_bank,
           other_bank = p_other_text, other_bank_key = p_other_key, source = p_source,
           updated_at = now(), confirm_sent_count = 0, last_confirm_sent_at = NULL,
           confirmed_at = NULL, invited_at = NULL, joined_at = NULL
     WHERE id = e.id RETURNING * INTO e;
    DELETE FROM waitlist_tokens WHERE entry_id = e.id AND purpose = 'confirm';
    v_kind := 'waitlist'; v_outcome := 'reset';
  END IF;

  IF v_kind = 'waitlist_has_account' THEN
    v_entry := NULL;
  ELSE
    v_entry := e.id;
  END IF;

  SELECT count(*) FILTER (WHERE created_at > now() - interval '10 minutes'),
         count(*)
    INTO recent10, recent24
    FROM mail_log
   WHERE recipient_tag = p_tag AND lane = 'waitlist' AND status <> 'suppressed'
     AND created_at > now() - interval '24 hours';
  IF (recent10 >= 1 OR recent24 >= 3) AND NOT (v_kind = 'waitlist' AND e.confirm_sent_count = 0) THEN
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
-- +goose StatementBegin
CREATE OR REPLACE FUNCTION waitlist_submit(p_tag bytea, p_email text, p_hint text, p_bank text,
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
    v_kind := 'waitlist_has_account'; v_outcome := 'joined';
    e.id := NULL;
  ELSE
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

  SELECT count(*) FILTER (WHERE created_at > now() - interval '10 minutes'),
         count(*)
    INTO recent10, recent24
    FROM mail_log
   WHERE recipient_tag = p_tag AND lane = 'waitlist' AND status <> 'suppressed'
     AND created_at > now() - interval '24 hours';
  IF (recent10 >= 1 OR recent24 >= 3) AND NOT (v_kind = 'waitlist' AND e.confirm_sent_count = 0) THEN
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
