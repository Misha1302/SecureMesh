using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611280105_ContactBlocks")]
public sealed class ContactBlocksMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        CREATE TABLE contact_blocks (
            owner_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            blocked_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            PRIMARY KEY(owner_id,blocked_id),
            CHECK(owner_id<>blocked_id)
        );
        CREATE INDEX contact_blocks_target ON contact_blocks(blocked_id);
        """);

    protected override void Down(MigrationBuilder migrationBuilder) =>
        migrationBuilder.Sql("DROP TABLE contact_blocks;");
}
