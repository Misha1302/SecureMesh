using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611280107_SecurityEmail")]
public sealed class SecurityEmailMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        ALTER TABLE users ADD COLUMN security_email_enabled boolean NOT NULL DEFAULT false,
            ADD COLUMN device_email_at timestamptz, ADD COLUMN refresh_reuse_email_at timestamptz;
        ALTER TABLE verification_email_queue
            ADD COLUMN security_owner uuid REFERENCES users(id) ON DELETE CASCADE,
            ADD COLUMN credential_hash bytea GENERATED ALWAYS AS
                (CASE WHEN security_owner IS NULL THEN token_hash END) STORED;
        ALTER TABLE verification_email_queue
            DROP CONSTRAINT verification_email_queue_token_hash_fkey,
            ADD FOREIGN KEY(credential_hash) REFERENCES email_tokens(hash) ON DELETE CASCADE;
        CREATE INDEX security_email_owner ON verification_email_queue(security_owner)
            WHERE security_owner IS NOT NULL;
        """);

    protected override void Down(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        DELETE FROM verification_email_queue WHERE security_owner IS NOT NULL;
        ALTER TABLE verification_email_queue DROP COLUMN credential_hash, DROP COLUMN security_owner,
            ADD FOREIGN KEY(token_hash) REFERENCES email_tokens(hash) ON DELETE CASCADE;
        ALTER TABLE users DROP COLUMN security_email_enabled, DROP COLUMN device_email_at,
            DROP COLUMN refresh_reuse_email_at;
        """);
}
