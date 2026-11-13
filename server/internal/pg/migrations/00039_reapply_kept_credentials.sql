-- +goose Up

-- +goose StatementBegin
DO $$
BEGIN
  IF current_user <> 'hasala_migrate' THEN
    RAISE EXCEPTION 'migrations must be applied as hasala_migrate, not %', current_user;
  END IF;
END $$;
-- +goose StatementEnd

CREATE TABLE reapply_kept_credentials (
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  credential_id bytea NOT NULL,
  kept_at       timestamptz NOT NULL,
  PRIMARY KEY (user_id, credential_id),
  CONSTRAINT reapply_kept_credentials_credential_fk FOREIGN KEY (user_id, credential_id)
    REFERENCES webauthn_credentials (user_id, credential_id) ON DELETE CASCADE
);

-- +goose Down
DROP TABLE reapply_kept_credentials;
