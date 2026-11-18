using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace SecureMesh;
[DbContext(typeof(MeshDb))]
[Migration("202611180004_MlsDirectory")]
public sealed class DirectoryMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        CREATE TABLE chat_requests (
          id uuid PRIMARY KEY, sender_device uuid NOT NULL REFERENCES devices(id),
          recipient_user uuid NOT NULL REFERENCES users(id), recipient_device uuid REFERENCES devices(id),
          created_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL DEFAULT now()+interval '7 days');
        CREATE INDEX chat_requests_recipient ON chat_requests(recipient_user,created_at);
        CREATE INDEX chat_requests_sender ON chat_requests(sender_device,created_at);
        CREATE TABLE key_packages (
          reference bytea PRIMARY KEY CHECK(octet_length(reference)=32), device_id uuid NOT NULL REFERENCES devices(id),
          payload bytea NOT NULL CHECK(octet_length(payload) BETWEEN 1 AND 16384),
          expires_at timestamptz NOT NULL DEFAULT now()+interval '1 hour',
          lease_id uuid UNIQUE, leased_by uuid REFERENCES devices(id), invitation_id uuid UNIQUE REFERENCES chat_requests(id),
          lease_expires_at timestamptz, consumed_by uuid UNIQUE REFERENCES conversations(id));
        CREATE INDEX key_packages_available ON key_packages(device_id,expires_at) WHERE lease_id IS NULL;
        CREATE TABLE conversation_bootstraps (
          conversation_id uuid PRIMARY KEY REFERENCES conversations(id), invitation_id uuid UNIQUE NOT NULL REFERENCES chat_requests(id),
          lease_id uuid UNIQUE NOT NULL, sender_device uuid NOT NULL REFERENCES devices(id), recipient_device uuid NOT NULL REFERENCES devices(id),
          reference bytea NOT NULL REFERENCES key_packages(reference), welcome bytea NOT NULL CHECK(octet_length(welcome) BETWEEN 1 AND 32768),
          signature bytea NOT NULL CHECK(octet_length(signature)=64), received boolean NOT NULL DEFAULT false,
          created_at timestamptz NOT NULL DEFAULT now());
        CREATE INDEX bootstrap_inbox ON conversation_bootstraps(recipient_device,created_at) WHERE NOT received;
        """);
    protected override void Down(MigrationBuilder migrationBuilder) => throw new NotSupportedException("Keep cryptographic enrollment records; reviewed restore only.");
}
