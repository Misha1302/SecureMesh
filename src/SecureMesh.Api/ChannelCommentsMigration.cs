using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611280110_ChannelComments")]
public sealed class ChannelCommentsMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        CREATE TABLE public_channel_comments (
            id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            post_seq bigint NOT NULL REFERENCES public_channel_posts(seq) ON DELETE CASCADE,
            user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            request_id uuid NOT NULL,
            body text,
            deleted_at timestamptz,
            CHECK ((body IS NULL) = (deleted_at IS NOT NULL)),
            CHECK (length(body) BETWEEN 1 AND 512),
            UNIQUE (user_id, post_seq, request_id)
        );
        CREATE INDEX public_channel_comment_page ON public_channel_comments(post_seq,id DESC);
        """);

    protected override void Down(MigrationBuilder migrationBuilder) =>
        throw new NotSupportedException("Preserve channel comments during rollback.");
}
