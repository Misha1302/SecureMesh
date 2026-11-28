using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611280101_VerificationEmailQueue")]
public sealed class VerificationEmailQueueMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        CREATE TABLE verification_email_queue (
            token_hash bytea PRIMARY KEY REFERENCES email_tokens(hash) ON DELETE CASCADE,
            payload text NOT NULL,
            expires_at timestamptz NOT NULL,
            next_attempt_at timestamptz NOT NULL DEFAULT now(),
            attempts integer NOT NULL DEFAULT 0
        );
        CREATE INDEX verification_email_due ON verification_email_queue(next_attempt_at);
        """);

    protected override void Down(MigrationBuilder migrationBuilder) =>
        migrationBuilder.Sql("DROP TABLE verification_email_queue;");
}
