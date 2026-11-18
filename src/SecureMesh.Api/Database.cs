using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace SecureMesh;

public sealed class MeshDb(DbContextOptions<MeshDb> options) : DbContext(options);

[DbContext(typeof(MeshDb))]
[Migration("202611180001_Foundation")]
public sealed class Foundation : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        CREATE TABLE users (
          id uuid PRIMARY KEY, username text UNIQUE NOT NULL, email text UNIQUE NOT NULL,
          password_hash text NOT NULL, verified boolean NOT NULL DEFAULT false,
          created_at timestamptz NOT NULL DEFAULT now());
        CREATE TABLE email_tokens (
          hash bytea PRIMARY KEY, user_id uuid NOT NULL REFERENCES users(id),
          expires_at timestamptz NOT NULL);
        CREATE TABLE devices (
          id uuid PRIMARY KEY, user_id uuid NOT NULL REFERENCES users(id),
          public_key bytea NOT NULL CHECK(octet_length(public_key)=32),
          revoked boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now());
        CREATE TABLE sessions (
          id uuid PRIMARY KEY, family uuid NOT NULL, device_id uuid NOT NULL REFERENCES devices(id),
          access_hash bytea UNIQUE NOT NULL, refresh_hash bytea UNIQUE NOT NULL,
          expires_at timestamptz NOT NULL, refresh_expires_at timestamptz NOT NULL,
          used boolean NOT NULL DEFAULT false, revoked boolean NOT NULL DEFAULT false);
        CREATE TABLE conversations (
          id uuid PRIMARY KEY, next_seq bigint NOT NULL DEFAULT 0,
          epoch bigint NOT NULL DEFAULT 0);
        CREATE TABLE members (
          conversation_id uuid NOT NULL REFERENCES conversations(id),
          device_id uuid NOT NULL REFERENCES devices(id),
          PRIMARY KEY(conversation_id,device_id));
        CREATE TABLE messages (
          id uuid PRIMARY KEY, conversation_id uuid NOT NULL REFERENCES conversations(id),
          seq bigint NOT NULL, device_id uuid NOT NULL REFERENCES devices(id),
          client_id uuid NOT NULL, ciphertext bytea NOT NULL, digest bytea NOT NULL,
          epoch bigint NOT NULL, kind integer NOT NULL CHECK(kind BETWEEN 1 AND 4),
          created_at timestamptz NOT NULL DEFAULT now(),
          UNIQUE(conversation_id,seq), UNIQUE(conversation_id,device_id,client_id));
        CREATE TABLE outbox (
          message_id uuid PRIMARY KEY REFERENCES messages(id),
          created_at timestamptz NOT NULL DEFAULT now());
        CREATE TABLE cursors (
          conversation_id uuid NOT NULL REFERENCES conversations(id),
          device_id uuid NOT NULL REFERENCES devices(id), seq bigint NOT NULL,
          PRIMARY KEY(conversation_id,device_id));
        """);
    protected override void Down(MigrationBuilder migrationBuilder) => throw new NotSupportedException("Restore a backup; destructive rollback requires operator review.");
}
