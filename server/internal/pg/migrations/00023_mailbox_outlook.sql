-- +goose Up
-- Outlook as a second mailbox provider (personal Microsoft accounts only). It
-- is applied as it stands on top of 00022: every row already in mailbox_links
-- is a Gmail link, which every new constraint accepts.
--
-- What changes:
--   * provider may be 'gmail' or 'outlook';
--   * client_state_hash is SHA-256 of the Outlook subscription's clientState,
--     which the link mints and returns once; Microsoft Graph echoes it on every
--     change notification, and the hook routes by its hash. It is present
--     exactly when the provider is 'outlook', and unique, so one notification
--     reaches at most one link. The clientState itself is never stored;
--   * one mailbox per account: linking either provider replaces the other.

-- +goose StatementBegin
DO $$
BEGIN
  IF current_user <> 'hasala_migrate' THEN
    RAISE EXCEPTION 'migrations must be applied as hasala_migrate, not %', current_user;
  END IF;
END $$;
-- +goose StatementEnd

ALTER TABLE mailbox_links
  DROP CONSTRAINT mailbox_links_provider_is_gmail,
  ADD CONSTRAINT mailbox_links_provider_known CHECK (provider IN ('gmail', 'outlook')),
  ADD COLUMN client_state_hash bytea,
  ADD CONSTRAINT mailbox_links_client_state_is_outlooks CHECK (
    CASE provider
      WHEN 'outlook' THEN client_state_hash IS NOT NULL AND octet_length(client_state_hash) = 32
      ELSE client_state_hash IS NULL
    END);
CREATE UNIQUE INDEX mailbox_links_client_state_idx ON mailbox_links (client_state_hash);
CREATE UNIQUE INDEX mailbox_links_one_per_user ON mailbox_links (user_id);

-- +goose Down
-- pgtest only (MigrateDown, and TestDownTo22IsWhat00022Left): exactly 00022's
-- shape again. A Down over Outlook links would break the restored CHECK, so
-- they go first.
DELETE FROM mailbox_links WHERE provider <> 'gmail';
DROP INDEX mailbox_links_one_per_user, mailbox_links_client_state_idx;
ALTER TABLE mailbox_links
  DROP CONSTRAINT mailbox_links_client_state_is_outlooks,
  DROP COLUMN client_state_hash,
  DROP CONSTRAINT mailbox_links_provider_known,
  ADD CONSTRAINT mailbox_links_provider_is_gmail CHECK (provider = 'gmail');
