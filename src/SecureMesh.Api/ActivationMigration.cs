using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace SecureMesh;
[DbContext(typeof(MeshDb))]
[Migration("202611180005_EnrollmentActivation")]
public sealed class ActivationMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        ALTER TABLE device_enrollments ADD COLUMN activation_signature bytea CHECK(activation_signature IS NULL OR octet_length(activation_signature)=64);
        ALTER TABLE device_enrollments ADD COLUMN activated_at timestamptz;
        """);
    protected override void Down(MigrationBuilder migrationBuilder) => throw new NotSupportedException("Do not silently skip client verification on downgrade.");
}
