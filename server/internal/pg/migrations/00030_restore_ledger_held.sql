-- +goose Up

-- +goose StatementBegin
DO $$
BEGIN
  IF current_user <> 'hasala_migrate' THEN
    RAISE EXCEPTION 'migrations must be applied as hasala_migrate, not %', current_user;
  END IF;
END $$;
-- +goose StatementEnd

CREATE TABLE restore_ledger_held (
  id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  line text NOT NULL,
  CONSTRAINT restore_ledger_held_line_is_bounded CHECK (char_length(line) BETWEEN 1 AND 4096)
);

-- +goose Down
DROP TABLE restore_ledger_held;
