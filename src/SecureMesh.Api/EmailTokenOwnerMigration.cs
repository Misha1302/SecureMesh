using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611280102_EmailTokenOwner")]
public sealed class EmailTokenOwnerMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) =>
        migrationBuilder.Sql("""
            CREATE INDEX email_tokens_owner ON email_tokens(user_id);
            ALTER TABLE users ADD COLUMN verification_resend_window timestamptz,
                ADD COLUMN verification_resends integer NOT NULL DEFAULT 0;
            """);

    protected override void Down(MigrationBuilder migrationBuilder) =>
        migrationBuilder.Sql("""
            ALTER TABLE users DROP COLUMN verification_resend_window, DROP COLUMN verification_resends;
            DROP INDEX email_tokens_owner;
            """);
}
