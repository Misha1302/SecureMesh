using System.Text;
using System.Text.Json.Serialization;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;
using Npgsql;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611270016_DeviceClientMetadata")]
public sealed class DeviceClientMetadataMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        ALTER TABLE devices
          ADD COLUMN client_os text CHECK (client_os IN ('android','ios','linux','windows','macos')),
          ADD COLUMN device_name text CHECK (char_length(device_name) BETWEEN 1 AND 64),
          ADD COLUMN last_login_at timestamptz;
        CREATE INDEX sessions_device_refreshable ON sessions(device_id,refresh_expires_at)
            WHERE NOT used AND NOT revoked;
        """);

    protected override void Down(MigrationBuilder migrationBuilder) =>
        throw new NotSupportedException("Older clients can retain this additive schema.");
}

public sealed record DeviceNameUpdate([property:JsonRequired] string? Name);

public static class DeviceMetadata
{
    public static void MapDeviceNames(this WebApplication app)
    {
        app.MapPut("/v1/devices/me/name", async (DeviceNameUpdate input,HttpContext ctx,NpgsqlDataSource db) =>
        {
            var actor=await Sql.Authenticate(ctx,db);
            var name=DisplayNames.Normalize(input.Name);
            if (name.EnumerateRunes().Count() > 64) throw new ApiError(400,"INVALID_DEVICE_NAME");
            await using var c=await db.OpenConnectionAsync(ctx.RequestAborted);
            await using var tx=await c.BeginTransactionAsync(ctx.RequestAborted);
            await Sql.LockTrustedProfileOwner(c,actor,ctx.RequestAborted);
            await using var cmd=Sql.Cmd(c,"UPDATE devices SET device_name=NULLIF($1,'') WHERE user_id=$2 AND id=$3",
                name,actor.UserId,actor.DeviceId);
            await cmd.ExecuteNonQueryAsync(ctx.RequestAborted);
            await tx.CommitAsync(ctx.RequestAborted);
            return Results.NoContent();
        });
    }
}
