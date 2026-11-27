using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611270007_DisplayName")]
public sealed class DisplayNameMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        ALTER TABLE users ADD COLUMN display_name text
            CHECK (char_length(display_name) BETWEEN 1 AND 64);
        """);

    protected override void Down(MigrationBuilder migrationBuilder) =>
        throw new NotSupportedException("Older clients can use the additive schema. Preserve user display names.");
}
