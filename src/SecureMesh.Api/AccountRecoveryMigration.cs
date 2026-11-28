using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611280106_AccountRecovery")]
public sealed class AccountRecoveryMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) =>
        migrationBuilder.Sql("""
            ALTER TABLE email_tokens ADD COLUMN purpose text NOT NULL DEFAULT 'verification'
                CHECK (purpose IN ('verification','account_recovery'));
            ALTER TABLE users ADD COLUMN recovery_window timestamptz,
                ADD COLUMN recovery_requests integer NOT NULL DEFAULT 0;
            CREATE INDEX email_tokens_recovery ON email_tokens(user_id,expires_at)
                WHERE purpose='account_recovery';
            """);

    protected override void Down(MigrationBuilder migrationBuilder) =>
        migrationBuilder.Sql("""
            DROP INDEX email_tokens_recovery;
            ALTER TABLE users DROP COLUMN recovery_window, DROP COLUMN recovery_requests;
            ALTER TABLE email_tokens DROP COLUMN purpose;
            """);
}
