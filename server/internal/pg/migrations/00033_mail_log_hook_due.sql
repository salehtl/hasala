-- +goose Up

-- +goose StatementBegin
DO $$
BEGIN
  IF current_user <> 'hasala_migrate' THEN
    RAISE EXCEPTION 'migrations must be applied as hasala_migrate, not %', current_user;
  END IF;
END $$;
-- +goose StatementEnd

ALTER TABLE mail_log ADD COLUMN hook_due boolean NOT NULL DEFAULT false;
ALTER TABLE mail_log ADD CONSTRAINT mail_log_hook_due_when_final CHECK (NOT hook_due OR final_at IS NOT NULL);
CREATE INDEX mail_log_hook_due_idx ON mail_log (id) WHERE hook_due;

-- +goose Down
DROP INDEX mail_log_hook_due_idx;
ALTER TABLE mail_log DROP CONSTRAINT mail_log_hook_due_when_final;
ALTER TABLE mail_log DROP COLUMN hook_due;
