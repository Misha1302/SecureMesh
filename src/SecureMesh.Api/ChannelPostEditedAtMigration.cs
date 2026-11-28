using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611280109_ChannelPostEditedAt")]
public sealed class ChannelPostEditedAtMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        ALTER TABLE public_channel_posts ADD COLUMN edited_at timestamptz
            CHECK (edited_at IS NULL OR revision>1);
        """);

    protected override void Down(MigrationBuilder migrationBuilder) =>
        throw new NotSupportedException("Preserve publication edit timestamps during rollback.");
}
