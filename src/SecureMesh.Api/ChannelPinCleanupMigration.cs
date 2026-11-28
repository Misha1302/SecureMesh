using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611280113_ChannelPinCleanup")]
public sealed class ChannelPinCleanupMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        -- Existing API writers lock the channel first. Hold the same order
        -- so a concurrent soft delete cannot slip between backfill and trigger.
        LOCK TABLE channel_catalog IN EXCLUSIVE MODE;
        LOCK TABLE public_channel_posts IN SHARE ROW EXCLUSIVE MODE;

        UPDATE channel_catalog AS channel
        SET pinned_seq = NULL, pin_revision = pin_revision + 1
        WHERE pinned_seq IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM public_channel_posts AS post
            WHERE post.seq = channel.pinned_seq AND post.channel_id = channel.id AND post.body IS NOT NULL
        );

        CREATE FUNCTION clear_deleted_channel_pin() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
            UPDATE channel_catalog
            SET pinned_seq = NULL, pin_revision = pin_revision + 1
            WHERE id = OLD.channel_id AND pinned_seq = OLD.seq;
            RETURN OLD;
        END;
        $$;

        CREATE TRIGGER clear_soft_deleted_channel_pin
        AFTER UPDATE OF body ON public_channel_posts
        FOR EACH ROW WHEN (OLD.body IS NOT NULL AND NEW.body IS NULL)
        EXECUTE FUNCTION clear_deleted_channel_pin();

        CREATE TRIGGER clear_hard_deleted_channel_pin
        BEFORE DELETE ON public_channel_posts
        FOR EACH ROW
        EXECUTE FUNCTION clear_deleted_channel_pin();
        """);

    protected override void Down(MigrationBuilder migrationBuilder) =>
        throw new NotSupportedException("Keep pin cleanup active for older API versions.");
}
