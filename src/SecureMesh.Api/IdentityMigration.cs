using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace SecureMesh;
[DbContext(typeof(MeshDb))]
[Migration("202611180002_DeviceChallenges")]
public sealed class DeviceChallenges : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        CREATE TABLE auth_challenges(id uuid PRIMARY KEY,username text NOT NULL,device_id uuid NOT NULL,payload bytea NOT NULL,expires_at timestamptz NOT NULL);
        CREATE INDEX auth_challenges_expiry ON auth_challenges(expires_at);
        """);
    protected override void Down(MigrationBuilder migrationBuilder) => throw new NotSupportedException();
}
