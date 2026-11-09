-- +goose Up

-- +goose StatementBegin
DO $$
BEGIN
  IF current_user <> 'hasala_migrate' THEN
    RAISE EXCEPTION 'migrations must be applied as hasala_migrate, not %', current_user;
  END IF;
END $$;
-- +goose StatementEnd

ALTER TABLE mail_log DROP CONSTRAINT mail_log_untagged_shape;
ALTER TABLE mail_log ADD CONSTRAINT mail_log_untagged_shape CHECK (
  recipient_tag IS NOT NULL
  OR status = 'queued'
  OR (kind = 'deleted' AND status = 'failed' AND recipient IS NULL)
  OR (status = 'failed' AND error IS NOT DISTINCT FROM 'mail: refused permanently: not configured')) NOT VALID;

-- +goose Down
ALTER TABLE mail_log DROP CONSTRAINT mail_log_untagged_shape;
ALTER TABLE mail_log ADD CONSTRAINT mail_log_untagged_shape CHECK (
  recipient_tag IS NOT NULL
  OR status = 'queued'
  OR (kind = 'deleted' AND status = 'failed' AND recipient IS NULL)) NOT VALID;
