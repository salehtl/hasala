-- +goose Up

-- +goose StatementBegin
DO $$
BEGIN
  IF current_user <> 'hasala_migrate' THEN
    RAISE EXCEPTION 'migrations must be applied as hasala_migrate, not %', current_user;
  END IF;
END $$;
-- +goose StatementEnd

INSERT INTO banks (slug, name, status, aliases) VALUES
  ('adib', 'Abu Dhabi Islamic Bank', 'supported', '{"adib","abu dhabi islamic bank","abu dhabi islamic"}')
ON CONFLICT (slug) DO UPDATE
  SET status = 'supported',
      status_changed_at = now()
  WHERE banks.status <> 'supported';

-- +goose Down
UPDATE banks SET status = 'new', status_changed_at = now() WHERE slug = 'adib';
