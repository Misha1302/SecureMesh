using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611280112_ChannelPin")]
public sealed class ChannelPinMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        ALTER TABLE channel_catalog
          ADD COLUMN pinned_seq bigint REFERENCES public_channel_posts(seq),
          ADD COLUMN pin_revision bigint NOT NULL DEFAULT 0 CHECK(pin_revision>=0);
        """);

    protected override void Down(MigrationBuilder migrationBuilder) =>
        throw new NotSupportedException("Preserve channel pins during rollback.");
}
