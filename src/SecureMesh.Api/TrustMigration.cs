using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611180003_DeviceTrust")]
public sealed class DeviceTrustMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        -- Existing first devices were enrolled by verified password + possession proof.
        ALTER TABLE devices ADD COLUMN trusted boolean NOT NULL DEFAULT true;
        CREATE TABLE device_enrollments (
          id uuid PRIMARY KEY, user_id uuid NOT NULL REFERENCES users(id),
          device_id uuid NOT NULL REFERENCES devices(id), payload bytea NOT NULL,
          candidate_signature bytea, approver_id uuid REFERENCES devices(id), grant_signature bytea,
          expires_at timestamptz NOT NULL, approved_at timestamptz,
          CHECK(candidate_signature IS NULL OR octet_length(candidate_signature)=64),
          CHECK(grant_signature IS NULL OR octet_length(grant_signature)=64));
        CREATE UNIQUE INDEX device_enrollments_pending ON device_enrollments(device_id) WHERE approved_at IS NULL;
        CREATE INDEX device_enrollments_expiry ON device_enrollments(expires_at);
        """);
    protected override void Down(MigrationBuilder migrationBuilder) => throw new NotSupportedException("Device trust rollback requires reviewed recovery; do not silently trust pending devices.");
}
