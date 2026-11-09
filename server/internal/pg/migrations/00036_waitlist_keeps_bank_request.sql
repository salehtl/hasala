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
CREATE OR REPLACE FUNCTION waitlist_derive_request(p_entry uuid) RETURNS void AS $$
DECLARE
  e         waitlist_entries%ROWTYPE;
  supported boolean := false;
BEGIN
  SELECT * INTO e FROM waitlist_entries WHERE id = p_entry;
  IF e.id IS NULL OR e.state <> 'confirmed' THEN
    DELETE FROM bank_requests WHERE waitlist_entry_id = p_entry;
    RETURN;
  END IF;
  IF e.other_bank IS NULL AND e.bank_slug IS NOT NULL THEN
    SELECT coalesce(status = 'supported', false) INTO supported FROM banks WHERE slug = e.bank_slug;
  END IF;
  DELETE FROM bank_requests
   WHERE waitlist_entry_id = p_entry
     AND (bank_slug IS DISTINCT FROM e.bank_slug
          OR other_key IS DISTINCT FROM e.other_bank_key
          OR (supported AND notified_at IS NULL));
  IF e.other_bank IS NOT NULL THEN
    INSERT INTO bank_requests (other_key, other_text, source, waitlist_entry_id, created_at)
      VALUES (e.other_bank_key, e.other_bank, 'web_waitlist', e.id, now())
      ON CONFLICT (waitlist_entry_id, (coalesce(bank_slug, 'other:' || other_key)))
        WHERE waitlist_entry_id IS NOT NULL
      DO UPDATE SET other_text = EXCLUDED.other_text;
  ELSIF e.bank_slug IS NOT NULL AND NOT supported THEN
    INSERT INTO bank_requests (bank_slug, source, waitlist_entry_id, created_at)
      VALUES (e.bank_slug, 'web_waitlist', e.id, now())
      ON CONFLICT (waitlist_entry_id, (coalesce(bank_slug, 'other:' || other_key)))
        WHERE waitlist_entry_id IS NOT NULL
      DO NOTHING;
  END IF;
END;
$$ LANGUAGE plpgsql;
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
CREATE OR REPLACE FUNCTION waitlist_derive_request(p_entry uuid) RETURNS void AS $$
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
