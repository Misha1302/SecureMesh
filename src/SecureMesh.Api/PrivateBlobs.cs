using System.Security.Cryptography;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;
using Npgsql;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611270010_PrivateBlobs")]
public sealed class PrivateBlobMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        CREATE TABLE private_blobs (
            conversation_id uuid NOT NULL REFERENCES conversations(id),
            blob_id uuid NOT NULL,
            owner_id uuid NOT NULL REFERENCES users(id),
            ciphertext bytea NOT NULL CHECK (octet_length(ciphertext) BETWEEN 17 AND 4194320),
            digest bytea NOT NULL CHECK (octet_length(digest)=32),
            PRIMARY KEY (conversation_id,blob_id)
        );
        CREATE INDEX private_blobs_owner ON private_blobs(owner_id);
        """);

    protected override void Down(MigrationBuilder migrationBuilder) =>
        throw new NotSupportedException("Restore a backup to preserve attachments.");
}

public static class PrivateBlobs
{
    private const string Route = "/v1/conversations/{group:guid}/blobs/{id:guid}";
    private const int MaxCiphertext = 4 * 1024 * 1024 + 16;
    private static readonly SemaphoreSlim UploadSlots = new(4);

    public static void MapPrivateBlobs(this WebApplication app)
    {
        app.MapPut(Route, Put);
        app.MapGet(Route, Get);
        app.MapDelete(Route, Delete);
    }

    private static async Task LockMember(NpgsqlConnection c, Guid group, Guid device, CancellationToken ct)
    {
        await using var cmd = Sql.Cmd(c, """
            SELECT 1 FROM members m JOIN devices d ON d.id=m.device_id
            WHERE m.conversation_id=$1 AND m.device_id=$2 AND d.trusted AND NOT d.revoked
            FOR SHARE OF m,d
            """, group, device);
        if (await cmd.ExecuteScalarAsync(ct) is null) throw new ApiError(403, "MEMBERSHIP_REQUIRED");
    }

    private static async Task<IResult> Put(Guid group, Guid id, HttpContext ctx, NpgsqlDataSource db, CancellationToken ct)
    {
        var actor = await Sql.Authenticate(ctx, db);
        var size = ctx.Request.ContentLength;
        if (size is null) throw new ApiError(411, "BLOB_LENGTH_REQUIRED");
        if (size is < 17 or > MaxCiphertext) throw new ApiError(413, "BLOB_SIZE");
        if (!string.Equals(ctx.Request.ContentType, "application/octet-stream", StringComparison.OrdinalIgnoreCase))
            throw new ApiError(415, "BLOB_CONTENT_TYPE");
        await using (var c = await db.OpenConnectionAsync(ct))
            await Sql.RequireMember(c, group, actor.DeviceId);

        if (!await UploadSlots.WaitAsync(0, ct)) throw new ApiError(429, "BLOB_UPLOAD_BUSY");
        try
        {
            var bodyLimit = ctx.Features.Get<IHttpMaxRequestBodySizeFeature>();
            if (bodyLimit is { IsReadOnly: false }) bodyLimit.MaxRequestBodySize = MaxCiphertext;
            var bytes = new byte[(int)size.Value];
            try { await ctx.Request.Body.ReadExactlyAsync(bytes, ct); }
            catch (EndOfStreamException) { throw new ApiError(400, "BLOB_INCOMPLETE"); }
            var digest = SHA256.HashData(bytes);
            await using var c = await db.OpenConnectionAsync(ct);
            await using var tx = await c.BeginTransactionAsync(ct);
            await LockMember(c, group, actor.DeviceId, ct);
            // One bounded quota check across all API instances, after upload completion.
            await using (var gate = Sql.Cmd(c, "SELECT pg_advisory_xact_lock(2445610010)"))
                await gate.ExecuteNonQueryAsync(ct);
            await using (var existing = Sql.Cmd(c, "SELECT owner_id,digest FROM private_blobs WHERE conversation_id=$1 AND blob_id=$2", group, id))
            await using (var reader = await existing.ExecuteReaderAsync(ct))
                if (await reader.ReadAsync(ct))
                {
                    if (reader.GetGuid(0) != actor.UserId || !CryptographicOperations.FixedTimeEquals(reader.GetFieldValue<byte[]>(1),digest))
                        throw new ApiError(409, "BLOB_ID_CONFLICT");
                    return Results.NoContent();
                }
            await using (var usage = Sql.Cmd(c, """
                SELECT count(*), coalesce(sum(octet_length(ciphertext)),0),
                       count(*) FILTER (WHERE owner_id=$1),
                       coalesce(sum(octet_length(ciphertext)) FILTER (WHERE owner_id=$1),0)
                FROM private_blobs
                """, actor.UserId))
            await using (var reader = await usage.ExecuteReaderAsync(ct))
            {
                await reader.ReadAsync(ct);
                if (reader.GetInt64(0) >= 8192 || reader.GetInt64(1) + size > 256L*1024*1024 ||
                    reader.GetInt64(2) >= 1024 || reader.GetInt64(3) + size > 64L*1024*1024)
                    throw new ApiError(507, "BLOB_QUOTA");
            }
            await using (var insert = Sql.Cmd(c, "INSERT INTO private_blobs VALUES($1,$2,$3,$4,$5)", group,id,actor.UserId,bytes,digest))
                await insert.ExecuteNonQueryAsync(ct);
            await tx.CommitAsync(ct);
            return Results.StatusCode(StatusCodes.Status201Created);
        }
        finally { UploadSlots.Release(); }
    }

    private static async Task<IResult> Get(Guid group, Guid id, HttpContext ctx, NpgsqlDataSource db, CancellationToken ct)
    {
        var actor = await Sql.Authenticate(ctx, db);
        await using var c = await db.OpenConnectionAsync(ct);
        await using var tx = await c.BeginTransactionAsync(ct);
        await LockMember(c, group, actor.DeviceId, ct);
        await using var select = Sql.Cmd(c, "SELECT ciphertext FROM private_blobs WHERE conversation_id=$1 AND blob_id=$2",group,id);
        var bytes = await select.ExecuteScalarAsync(ct) as byte[] ?? throw new ApiError(404, "BLOB_NOT_FOUND");
        await tx.CommitAsync(ct);
        return Results.Bytes(bytes, "application/octet-stream");
    }

    private static async Task<IResult> Delete(Guid group, Guid id, HttpContext ctx, NpgsqlDataSource db, CancellationToken ct)
    {
        var actor = await Sql.Authenticate(ctx, db);
        await using var c = await db.OpenConnectionAsync(ct);
        await using var tx = await c.BeginTransactionAsync(ct);
        await LockMember(c, group, actor.DeviceId, ct);
        await using var delete = Sql.Cmd(c, "DELETE FROM private_blobs WHERE conversation_id=$1 AND blob_id=$2 AND owner_id=$3",group,id,actor.UserId);
        if (await delete.ExecuteNonQueryAsync(ct) != 1) throw new ApiError(404, "BLOB_NOT_FOUND");
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }
}
