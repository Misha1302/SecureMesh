using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611270011_ChannelInvitations")]
public sealed class ChannelInvitationsMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        ALTER TABLE public_channels RENAME TO channel_catalog;
        ALTER TABLE channel_catalog ADD COLUMN invite_only boolean NOT NULL DEFAULT false;
        ALTER TABLE channel_catalog DROP CONSTRAINT public_channels_slug_key;
        CREATE UNIQUE INDEX channel_public_handle ON channel_catalog(slug) WHERE NOT invite_only;
        CREATE UNIQUE INDEX channel_invite_owner_handle ON channel_catalog(owner_id,slug) WHERE invite_only;
        CREATE INDEX channel_catalog_order ON channel_catalog(slug,id);
        -- Existing server versions query this relation before servicing a feed or write.
        -- A rollback must never disclose invite-only channel metadata or posts.
        CREATE VIEW public_channels AS
          SELECT id,owner_id,slug,title FROM channel_catalog WHERE NOT invite_only WITH LOCAL CHECK OPTION;
        CREATE TABLE channel_invitations (
            channel_id uuid NOT NULL REFERENCES channel_catalog(id) ON DELETE CASCADE,
            user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            expires_at timestamptz NOT NULL,
            PRIMARY KEY(channel_id,user_id)
        );
        CREATE INDEX channel_invitations_recipient ON channel_invitations(user_id,expires_at);
        ALTER TABLE public_channel_posts ADD COLUMN revision integer NOT NULL DEFAULT 1 CHECK(revision>0);
        """);

    protected override void Down(MigrationBuilder migrationBuilder) =>
        throw new NotSupportedException("Preserve invite-only visibility, invitations and post revisions.");
}
