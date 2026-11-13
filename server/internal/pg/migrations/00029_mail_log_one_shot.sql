-- +goose Up

-- +goose StatementBegin
DO $$
BEGIN
  IF current_user <> 'hasala_migrate' THEN
    RAISE EXCEPTION 'migrations must be applied as hasala_migrate, not %', current_user;
  END IF;
END $$;
-- +goose StatementEnd

ALTER TABLE mail_log ADD COLUMN one_shot boolean NOT NULL DEFAULT false;

-- +goose Down
ALTER TABLE mail_log DROP COLUMN one_shot;
