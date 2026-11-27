using System.Text.Json.Serialization;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;
using Npgsql;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611270008_ProfilePhotos")]
public sealed class ProfilePhotoMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        CREATE TABLE profile_photos (
            user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
            version uuid UNIQUE NOT NULL,
            pixels bytea NOT NULL CHECK(octet_length(pixels) = 6912)
        );
        """);

    protected override void Down(MigrationBuilder migrationBuilder) =>
        throw new NotSupportedException("The additive table is safe to retain for older clients.");
}

public sealed record PhotoUpdate([property: JsonRequired] byte[]? Pixels);

public static class ProfilePhotos
{
    // Exactly 48 × 48 top-down RGB pixels. No image headers, metadata or decoder in the API.
    private const int PixelBytes = 48 * 48 * 3;

    public static void MapProfilePhotos(this WebApplication app)
    {
        app.MapPut("/v1/users/me/photo", async (PhotoUpdate input, HttpContext ctx, NpgsqlDataSource db) =>
        {
            var actor = await Sql.Authenticate(ctx, db);
            if (input.Pixels is not null && input.Pixels.Length != PixelBytes)
                throw new ApiError(400, "INVALID_PHOTO_SIZE");

            await using var c = await db.OpenConnectionAsync(ctx.RequestAborted);
            await using var tx = await c.BeginTransactionAsync(ctx.RequestAborted);
            // Serialize with device revocation, then recheck this session while it holds the account lock.
            await using (var owner = Sql.Cmd(c, "SELECT id FROM users WHERE id=$1 FOR UPDATE", actor.UserId))
                await owner.ExecuteScalarAsync(ctx.RequestAborted);
            await using (var session = Sql.Cmd(c, """
                SELECT 1 FROM sessions s JOIN devices d ON d.id=s.device_id
                WHERE s.id=$1 AND d.id=$2 AND d.user_id=$3 AND d.trusted AND NOT d.revoked
                    AND NOT s.used AND NOT s.revoked AND s.expires_at>now()
                """, actor.SessionId, actor.DeviceId, actor.UserId))
                if (await session.ExecuteScalarAsync(ctx.RequestAborted) is null)
                    throw new ApiError(401, "AUTH_REQUIRED");

            Guid? version = null;
            if (input.Pixels is null)
            {
                await using var remove = Sql.Cmd(c, "DELETE FROM profile_photos WHERE user_id=$1", actor.UserId);
                await remove.ExecuteNonQueryAsync(ctx.RequestAborted);
            }
            else
            {
                await using var save = Sql.Cmd(c, """
                    INSERT INTO profile_photos(user_id, version, pixels) VALUES ($1,$2,$3)
                    ON CONFLICT (user_id) DO UPDATE SET pixels=excluded.pixels,
                      version=CASE WHEN profile_photos.pixels=excluded.pixels THEN profile_photos.version ELSE excluded.version END
                    RETURNING version
                    """, actor.UserId, Guid.NewGuid(), input.Pixels);
                version = (Guid)(await save.ExecuteScalarAsync(ctx.RequestAborted))!;
            }
            await tx.CommitAsync(ctx.RequestAborted);
            return Results.Ok(new { photoVersion = version });
        });

        app.MapGet("/v1/users/me/photo", async (HttpContext ctx, NpgsqlDataSource db) =>
        {
            var actor = await Sql.Authenticate(ctx, db);
            await using var c = await db.OpenConnectionAsync(ctx.RequestAborted);
            await using var cmd = Sql.Cmd(c, "SELECT pixels FROM profile_photos WHERE user_id=$1", actor.UserId);
            return Results.Ok(new { pixels = await cmd.ExecuteScalarAsync(ctx.RequestAborted) as byte[] });
        });

        app.MapGet("/v1/conversations/{id:guid}/photo/{version:guid}", async (Guid id, Guid version, HttpContext ctx, NpgsqlDataSource db) =>
        {
            var actor = await Sql.Authenticate(ctx, db);
            await using var c = await db.OpenConnectionAsync(ctx.RequestAborted);
            await using var cmd = Sql.Cmd(c, """
                SELECT p.pixels FROM conversation_devices own JOIN members peer ON own.conversation_id=peer.conversation_id
                JOIN devices d ON d.id=peer.device_id JOIN profile_photos p ON p.user_id=d.user_id
                LEFT JOIN conversation_bootstraps b ON b.conversation_id=own.conversation_id
                WHERE own.device_id=$1 AND own.conversation_id=$2 AND d.user_id<>$4
                  AND p.version=$3 AND (b.conversation_id IS NULL OR b.sender_device=$1 OR b.received OR own.join_seq>0)
                  AND (SELECT count(*) FROM members WHERE conversation_id=$2)=2
                """, actor.DeviceId, id, version, actor.UserId);
            var pixels = await cmd.ExecuteScalarAsync(ctx.RequestAborted) as byte[];
            if (pixels is null) throw new ApiError(404, "PHOTO_NOT_FOUND");
            return Results.Ok(new { pixels });
        });
    }
}
