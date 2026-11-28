using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611280108_ChannelReactions")]
public sealed class ChannelReactionsMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        CREATE TABLE public_channel_reactions (
            post_seq bigint NOT NULL REFERENCES public_channel_posts(seq) ON DELETE CASCADE,
            user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            kind text NOT NULL CHECK(kind IN ('like','heart','smile')),
            PRIMARY KEY(post_seq,user_id)
        );
        CREATE INDEX public_channel_reactions_account ON public_channel_reactions(user_id,post_seq);
        """);

    protected override void Down(MigrationBuilder migrationBuilder) =>
        throw new NotSupportedException("Preserve account reaction choices during rollback.");
}
