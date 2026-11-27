using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611270017_UnicodeDisplayName")]
public sealed class UnicodeDisplayNameMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        ALTER TABLE users DROP CONSTRAINT users_display_name_check,
            ADD CONSTRAINT users_display_name_check CHECK (octet_length(display_name) BETWEEN 1 AND 2048);
        """);

    protected override void Down(MigrationBuilder migrationBuilder) =>
        throw new NotSupportedException("Retain names containing multi-code-point graphemes for older clients.");
}
