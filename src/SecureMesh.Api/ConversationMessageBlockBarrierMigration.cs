using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611280115_ConversationMessageBlockBarrier")]
public sealed class ConversationMessageBlockBarrierMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        CREATE FUNCTION require_conversation_message_delivery_open() RETURNS trigger
        LANGUAGE plpgsql AS $$
        BEGIN
            -- Serialize with block/unblock even for an older API process.
            PERFORM 1 FROM conversations WHERE id=NEW.conversation_id FOR UPDATE;
            IF EXISTS (
                SELECT 1 FROM conversation_message_blocks WHERE conversation_id=NEW.conversation_id
            ) THEN
                RAISE EXCEPTION USING ERRCODE='23514',
                    CONSTRAINT='conversation_message_delivery_open',
                    MESSAGE='Conversation message delivery is paused';
            END IF;
            RETURN NEW;
        END;
        $$;
        CREATE TRIGGER conversation_message_delivery_open
        BEFORE INSERT ON messages FOR EACH ROW
        EXECUTE FUNCTION require_conversation_message_delivery_open();
        """);

    protected override void Down(MigrationBuilder migrationBuilder) =>
        throw new NotSupportedException("Keep message blocking enforced across API rollback.");
}
