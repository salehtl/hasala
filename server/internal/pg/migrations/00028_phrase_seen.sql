-- +goose Up

-- +goose StatementBegin
DO $$
BEGIN
  IF current_user <> 'hasala_migrate' THEN
    RAISE EXCEPTION 'migrations must be applied as hasala_migrate, not %', current_user;
  END IF;
END $$;
-- +goose StatementEnd

ALTER TABLE account_keys ADD COLUMN phrase_seen_at timestamptz;
UPDATE account_keys SET phrase_seen_at = created_at;

-- +goose Down
ALTER TABLE account_keys DROP COLUMN phrase_seen_at;
