using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611190006_EnrollmentIssuanceQuota")]
public sealed class EnrollmentQuotaMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        -- Keep issuance accounting when an expired unapproved request is deleted.
        -- Only public identifiers/timestamps; no keys, nonces or signatures.
        CREATE TABLE device_enrollment_issuance (
          id uuid PRIMARY KEY, device_id uuid NOT NULL REFERENCES devices(id),
          created_at timestamptz NOT NULL DEFAULT now());
        CREATE INDEX device_enrollment_issuance_window ON device_enrollment_issuance(device_id,created_at);
        INSERT INTO device_enrollment_issuance(id,device_id,created_at)
          SELECT id,device_id,expires_at-interval '5 minutes' FROM device_enrollments;
        """);
    protected override void Down(MigrationBuilder migrationBuilder) => throw new NotSupportedException("Do not discard persistent device enrollment issuance accounting.");
}
