using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611270009_PublicChannels")]
public sealed class PublicChannelMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        CREATE TABLE public_channels (
            id uuid PRIMARY KEY, owner_id uuid NOT NULL REFERENCES users(id),
            slug text COLLATE "C" NOT NULL UNIQUE CHECK(slug ~ '^[a-z0-9_]{3,32}$'),
            title text NOT NULL CHECK(char_length(title) BETWEEN 1 AND 80)
        );
        CREATE INDEX public_channels_owner ON public_channels(owner_id);
        CREATE TABLE public_channel_subscriptions (
            user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            channel_id uuid NOT NULL REFERENCES public_channels(id) ON DELETE CASCADE,
            PRIMARY KEY (user_id, channel_id)
        );
        CREATE INDEX public_channel_sub_by_channel ON public_channel_subscriptions(channel_id);
        CREATE TABLE public_channel_posts (
            seq bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            channel_id uuid NOT NULL REFERENCES public_channels(id) ON DELETE CASCADE,
            request_id uuid NOT NULL,
            body text CHECK(char_length(body) BETWEEN 1 AND 2048),
            deleted_at timestamptz, CHECK ((body IS NULL) = (deleted_at IS NOT NULL)),
            published_at timestamptz NOT NULL DEFAULT now(),
            UNIQUE(channel_id, request_id)
        );
        CREATE INDEX public_channel_feed ON public_channel_posts(channel_id, seq DESC);
        CREATE TABLE public_channel_removed (
            owner_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE, id uuid NOT NULL,
            deleted_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(owner_id,id)
        );
        CREATE TABLE public_channel_activity (
            user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            action text NOT NULL, window_start timestamptz NOT NULL, count integer NOT NULL,
            PRIMARY KEY(user_id, action)
        );
        """);

    protected override void Down(MigrationBuilder migrationBuilder) =>
        throw new NotSupportedException("Preserve public channel publications and subscriptions during rollback.");
}
