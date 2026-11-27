using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611270013_DeviceRoster")]
public sealed class RosterMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        ALTER TABLE key_packages ADD COLUMN roster_group uuid REFERENCES conversations ON DELETE SET NULL;
        CREATE TABLE conversation_links(
          conversation_id uuid NOT NULL REFERENCES conversations ON DELETE CASCADE,
          device_id uuid NOT NULL REFERENCES devices ON DELETE CASCADE,
          join_seq bigint NOT NULL CHECK(join_seq>0),
          PRIMARY KEY(conversation_id,device_id));
        CREATE INDEX conversation_links_device ON conversation_links(device_id,conversation_id);
        CREATE VIEW conversation_devices AS
          SELECT conversation_id,device_id,0::bigint AS join_seq FROM members
          UNION ALL SELECT conversation_id,device_id,join_seq FROM conversation_links;
        CREATE TABLE roster_changes(
          conversation_id uuid NOT NULL REFERENCES conversations ON DELETE CASCADE,
          id uuid NOT NULL,
          committer uuid NOT NULL REFERENCES devices ON DELETE CASCADE,
          device_id uuid NOT NULL REFERENCES devices ON DELETE CASCADE,
          seq bigint NOT NULL, digest bytea NOT NULL, transition jsonb NOT NULL,
          PRIMARY KEY(conversation_id,id), UNIQUE(conversation_id,seq));
        -- Old server binaries only know original members. Protect the send path on rollback
        -- when a linked leaf is revoked but its remove commit has not been recorded.
        CREATE FUNCTION guard_linked_leaf() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
            PERFORM d.id FROM conversation_links l JOIN devices d ON d.id=l.device_id
                WHERE l.conversation_id=NEW.conversation_id ORDER BY d.id FOR SHARE OF d;
            IF EXISTS (SELECT 1 FROM conversation_links l JOIN devices d ON d.id=l.device_id
                       WHERE l.conversation_id=NEW.conversation_id AND (d.revoked OR NOT d.trusted))
              AND NOT EXISTS(SELECT 1 FROM roster_changes r WHERE r.conversation_id=NEW.conversation_id AND r.seq=NEW.seq
                    AND r.committer=NEW.device_id AND r.id=NEW.client_id AND r.transition->>'action'='remove'
                    AND decode(r.transition->>'commit','base64')=NEW.ciphertext)
            THEN RAISE EXCEPTION 'stale linked device' USING ERRCODE='23514'; END IF;
            RETURN NEW;
        END $$;
        CREATE TRIGGER protect_linked_leaf BEFORE INSERT ON messages
            FOR EACH ROW EXECUTE FUNCTION guard_linked_leaf();
        """);
    protected override void Down(MigrationBuilder migrationBuilder) =>
        throw new NotSupportedException("Restore a backup to preserve linked-device history boundaries.");
}
