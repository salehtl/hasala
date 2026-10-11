-- +goose Up
-- WS-4, the Gmail mailbox link (spec 02 §5.3, §13). Pre-assigned number 00020
-- of WS-4's range (00020–00029); squashed into 00001_baseline.sql before the
-- first QA deploy, like every migration in 00002–00029.
--
-- apns_tokens is already in the baseline. What this adds:
--   * mailbox_links: one holder writer per account, the mailbox address only as
--     an HMAC under the route key (spec 02 §13.3), never in plaintext;
--   * mailbox_link_challenges: the single-use nonce the link's Google ID token
--     must carry (spec 02 §13.2), bound to the session that asked for it.

-- +goose StatementBegin
DO $$
BEGIN
  IF current_user <> 'hasala_migrate' THEN
    RAISE EXCEPTION 'migrations must be applied as hasala_migrate, not %', current_user;
  END IF;
END $$;
-- +goose StatementEnd

CREATE TABLE mailbox_links (
  user_id          uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider         text NOT NULL,
  address_hmac     bytea NOT NULL,
  route_key_id     bytea NOT NULL,
  holder_writer_id text NOT NULL,
  watch_expires_at timestamptz,
  last_wake_hour   timestamptz,            -- truncated to the UTC hour by Go
  last_nudge_at    timestamptz,
  created_at       timestamptz NOT NULL,
  updated_at       timestamptz NOT NULL,
  PRIMARY KEY (user_id, provider),
  CONSTRAINT mailbox_links_provider_is_gmail CHECK (provider = 'gmail'),
  CONSTRAINT mailbox_links_hmac_is_256_bits CHECK (octet_length(address_hmac) = 32),
  CONSTRAINT mailbox_links_key_id_is_64_bits CHECK (octet_length(route_key_id) = 8),
  CONSTRAINT mailbox_links_holder_fk FOREIGN KEY (user_id, holder_writer_id)
    REFERENCES writers (user_id, writer_id) ON DELETE CASCADE
);
-- Not UNIQUE: two accounts may each prove the same mailbox.
CREATE INDEX mailbox_links_route_idx ON mailbox_links (address_hmac);
CREATE INDEX mailbox_links_watch_idx ON mailbox_links (watch_expires_at);

CREATE TABLE mailbox_link_challenges (
  nonce_hash   bytea PRIMARY KEY,
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  session_hash bytea NOT NULL REFERENCES sessions(token_hash) ON DELETE CASCADE,
  issued_at    timestamptz NOT NULL,
  expires_at   timestamptz NOT NULL,
  used_at      timestamptz,
  CONSTRAINT mailbox_link_challenges_hash_is_256_bits CHECK (octet_length(nonce_hash) = 32),
  CONSTRAINT mailbox_link_challenges_ttl CHECK (expires_at > issued_at AND expires_at <= issued_at + interval '15 minutes')
);
CREATE INDEX mailbox_link_challenges_expiry_idx ON mailbox_link_challenges (expires_at);

-- +goose Down
-- pgtest only (MigrateDown).
DROP TABLE mailbox_link_challenges, mailbox_links;
