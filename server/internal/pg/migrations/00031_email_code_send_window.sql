-- +goose Up

-- +goose StatementBegin
DO $$
BEGIN
  IF current_user <> 'hasala_migrate' THEN
    RAISE EXCEPTION 'migrations must be applied as hasala_migrate, not %', current_user;
  END IF;
END $$;
-- +goose StatementEnd

ALTER TABLE email_codes ADD COLUMN awaiting_send_until timestamptz;

-- +goose Down
ALTER TABLE email_codes DROP COLUMN awaiting_send_until;
