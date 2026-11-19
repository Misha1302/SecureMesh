using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611190007_DeviceBoundRefresh")]
public sealed class RefreshMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        ALTER TABLE sessions ADD COLUMN device_bound_refresh boolean NOT NULL DEFAULT false;
        CREATE TABLE refresh_rotations (
          old_session_id uuid PRIMARY KEY REFERENCES sessions(id),
          new_session_id uuid UNIQUE NOT NULL REFERENCES sessions(id),
          device_id uuid NOT NULL REFERENCES devices(id), request_id uuid NOT NULL,
          request_digest bytea NOT NULL CHECK(octet_length(request_digest)=32),
          protected_response text NOT NULL CHECK(length(protected_response)<=16384),
          created_at timestamptz NOT NULL DEFAULT now(),
          expires_at timestamptz NOT NULL DEFAULT now()+interval '1 day',
          UNIQUE(device_id,request_id),
          CHECK(expires_at=created_at+interval '1 day'));
        CREATE INDEX refresh_rotations_window ON refresh_rotations(device_id,created_at);
        """);
    protected override void Down(MigrationBuilder migrationBuilder) => throw new NotSupportedException("Do not discard device-bound refresh or crash recovery state.");
}
