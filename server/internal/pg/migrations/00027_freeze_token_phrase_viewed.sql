-- +goose Up

-- +goose StatementBegin
DO $$
BEGIN
  IF current_user <> 'hasala_migrate' THEN
    RAISE EXCEPTION 'migrations must be applied as hasala_migrate, not %', current_user;
  END IF;
END $$;
-- +goose StatementEnd

ALTER TABLE freeze_tokens DROP CONSTRAINT freeze_tokens_trigger_is_closed;
ALTER TABLE freeze_tokens ADD CONSTRAINT freeze_tokens_trigger_is_closed
  CHECK (trigger_kind IN ('new_sign_in','recovery_used','phrase_viewed'));

-- +goose Down
DELETE FROM freeze_tokens WHERE trigger_kind = 'phrase_viewed';
ALTER TABLE freeze_tokens DROP CONSTRAINT freeze_tokens_trigger_is_closed;
ALTER TABLE freeze_tokens ADD CONSTRAINT freeze_tokens_trigger_is_closed
  CHECK (trigger_kind IN ('new_sign_in','recovery_used'));
