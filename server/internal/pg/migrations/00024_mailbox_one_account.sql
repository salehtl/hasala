-- +goose Up

-- +goose StatementBegin
DO $$
BEGIN
  IF current_user <> 'hasala_migrate' THEN
    RAISE EXCEPTION 'migrations must be applied as hasala_migrate, not %', current_user;
  END IF;
END $$;
-- +goose StatementEnd

DELETE FROM mailbox_links l
 USING mailbox_links newer
 WHERE newer.address_hmac = l.address_hmac
   AND (newer.created_at, newer.user_id) > (l.created_at, l.user_id);

DROP INDEX mailbox_links_route_idx;
CREATE UNIQUE INDEX mailbox_links_one_account_per_mailbox ON mailbox_links (address_hmac);

-- +goose Down
DROP INDEX mailbox_links_one_account_per_mailbox;
CREATE INDEX mailbox_links_route_idx ON mailbox_links (address_hmac);
