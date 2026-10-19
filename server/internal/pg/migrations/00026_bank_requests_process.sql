-- +goose Up

-- +goose StatementBegin
DO $$
BEGIN
  IF current_user <> 'hasala_migrate' THEN
    RAISE EXCEPTION 'migrations must be applied as hasala_migrate, not %', current_user;
  END IF;
END $$;
-- +goose StatementEnd

ALTER TABLE banks
  ADD COLUMN note text NOT NULL DEFAULT '',
  ADD CONSTRAINT banks_note_is_bounded CHECK (char_length(note) <= 500);

ALTER TABLE bank_requests
  ADD COLUMN sender_domain text,
  ADD CONSTRAINT bank_requests_sender_domain_shape CHECK (sender_domain IS NULL OR (
    user_id IS NOT NULL
    AND char_length(sender_domain) BETWEEN 4 AND 253
    AND sender_domain ~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'));

-- +goose Down
ALTER TABLE bank_requests DROP COLUMN sender_domain;
ALTER TABLE banks DROP COLUMN note;
