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

public static partial class PrivateBlobs
{
    private const string Route = "/v1/conversations/{group:guid}/blobs/{id:guid}";
    private const int MaxCiphertext = 4 * 1024 * 1024 + 16;
    private static readonly SemaphoreSlim UploadSlots = new(4);

    public static void MapPrivateBlobs(this WebApplication app)
    {
        app.MapPut(Route + "/parts", PutPart);
        app.MapGet(Route + "/parts", Progress);
        app.MapPut(Route, Put);
        app.MapGet(Route, Get);
        app.MapDelete(Route, Delete);
    }

    private static async Task RequireWritable(NpgsqlConnection c, Guid group, CancellationToken ct)
    {
        await using var cmd = Sql.Cmd(c, "SELECT account_removed FROM conversations WHERE id=$1 FOR SHARE", group);
        if (await cmd.ExecuteScalarAsync(ct) is not false) throw new ApiError(409, "CONVERSATION_READ_ONLY");
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
            await RequireWritable(c, group, ct);
            await LockUploads(c, ct);
            await using (var existing = Sql.Cmd(c, "SELECT owner_id,digest FROM private_blobs WHERE conversation_id=$1 AND blob_id=$2", group, id))
            await using (var reader = await existing.ExecuteReaderAsync(ct))
                if (await reader.ReadAsync(ct))
                {
                    if (reader.GetGuid(0) != actor.UserId || !CryptographicOperations.FixedTimeEquals(reader.GetFieldValue<byte[]>(1),digest))
                        throw new ApiError(409, "BLOB_ID_CONFLICT");
                    return Results.NoContent();
                }
            await using (var stage = Sql.Cmd(c, "SELECT 1 FROM private_blob_uploads WHERE conversation_id=$1 AND blob_id=$2", group, id))
                if (await stage.ExecuteScalarAsync(ct) is not null) throw new ApiError(409, "BLOB_ID_CONFLICT");
            await Reserve(c, actor.UserId, (int)size.Value, ct);
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
        // Use PostgreSQL's bytea slice for the bounded range used by native clients.
        // Other HTTP range forms retain the framework's standard file handling.
        if (System.Net.Http.Headers.RangeHeaderValue.TryParse(ctx.Request.Headers.Range, out var ranges) &&
            ranges.Unit == "bytes" && ranges.Ranges.Count == 1 &&
            ranges.Ranges.First() is { From: long start, To: long end } &&
            start >= 0 && end >= start && end < MaxCiphertext && end - start < Chunk)
        {
            await using var part = Sql.Cmd(c, """
                SELECT octet_length(ciphertext), substring(ciphertext FROM $3 FOR $4)
                FROM private_blobs WHERE conversation_id=$1 AND blob_id=$2
                """, group, id, (int)start + 1, (int)(end - start + 1));
            await using var reader = await part.ExecuteReaderAsync(ct);
            if (!await reader.ReadAsync(ct)) throw new ApiError(404, "BLOB_NOT_FOUND");
            var size = reader.GetInt32(0);
            if (start >= size)
            {
                ctx.Response.Headers.ContentRange = $"bytes */{size}";
                return Results.StatusCode(416);
            }
            var chunk = reader.GetFieldValue<byte[]>(1);
            ctx.Response.Headers.AcceptRanges = "bytes";
            ctx.Response.Headers.ContentRange = $"bytes {start}-{start + chunk.Length - 1}/{size}";
            ctx.Response.StatusCode = 206;
            return Results.Bytes(chunk, "application/octet-stream");
        }
        await using var select = Sql.Cmd(c, "SELECT ciphertext FROM private_blobs WHERE conversation_id=$1 AND blob_id=$2",group,id);
        var bytes = await select.ExecuteScalarAsync(ct) as byte[] ?? throw new ApiError(404, "BLOB_NOT_FOUND");
        await tx.CommitAsync(ct);
        return Results.Bytes(bytes, "application/octet-stream", enableRangeProcessing: true);
    }

    private static async Task<IResult> Delete(Guid group, Guid id, HttpContext ctx, NpgsqlDataSource db, CancellationToken ct)
    {
        var actor = await Sql.Authenticate(ctx, db);
        await using var c = await db.OpenConnectionAsync(ct);
        await using var tx = await c.BeginTransactionAsync(ct);
        await LockMember(c, group, actor.DeviceId, ct);
        await LockUploads(c, ct);
        await using var partial = Sql.Cmd(c, "DELETE FROM private_blob_uploads WHERE conversation_id=$1 AND blob_id=$2 AND owner_id=$3", group, id, actor.UserId);
        var removed = await partial.ExecuteNonQueryAsync(ct);
        await using var delete = Sql.Cmd(c, "DELETE FROM private_blobs WHERE conversation_id=$1 AND blob_id=$2 AND owner_id=$3",group,id,actor.UserId);
        if (await delete.ExecuteNonQueryAsync(ct) + removed == 0) throw new ApiError(404, "BLOB_NOT_FOUND");
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }
}
