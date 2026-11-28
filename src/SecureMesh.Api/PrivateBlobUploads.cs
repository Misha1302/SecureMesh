using System.Security.Cryptography;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;
using Npgsql;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611270012_ResumableBlobs")]
public sealed class ResumableBlobMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        CREATE TABLE private_blob_uploads (
            conversation_id uuid NOT NULL REFERENCES conversations(id),
            blob_id uuid NOT NULL,
            owner_id uuid NOT NULL REFERENCES users(id),
            size integer NOT NULL CHECK (size BETWEEN 17 AND 4194320),
            digest bytea NOT NULL CHECK (octet_length(digest)=32),
            prefix bytea NOT NULL CHECK (octet_length(prefix) < size),
            expires_at timestamptz NOT NULL,
            PRIMARY KEY (conversation_id,blob_id)
        );
        CREATE INDEX private_blob_uploads_expiry ON private_blob_uploads(expires_at);
        """);

    protected override void Down(MigrationBuilder migrationBuilder) =>
        throw new NotSupportedException("Restore a backup to preserve uploads.");
}

public static partial class PrivateBlobs
{
    private const int Chunk = 32768;

    private static async Task LockUploads(NpgsqlConnection c, CancellationToken ct)
    {
        // Serialize reservations, finish and delete across all API instances.
        await using var gate = Sql.Cmd(c, "SELECT pg_advisory_xact_lock(2445610010)");
        await gate.ExecuteNonQueryAsync(ct);
        await using var expire = Sql.Cmd(c, "DELETE FROM private_blob_uploads WHERE expires_at <= now()");
        await expire.ExecuteNonQueryAsync(ct);
    }

    private static async Task Reserve(NpgsqlConnection c, Guid owner, int size, CancellationToken ct)
    {
        await using var usage = Sql.Cmd(c, """
            SELECT count(*), coalesce(sum(size),0), count(*) FILTER (WHERE owner_id=$1),
                coalesce(sum(size) FILTER (WHERE owner_id=$1),0)
            FROM (SELECT owner_id, octet_length(ciphertext) AS size FROM private_blobs
                  UNION ALL SELECT owner_id,size FROM private_blob_uploads) objects
            """, owner);
        await using var reader = await usage.ExecuteReaderAsync(ct);
        await reader.ReadAsync(ct);
        if (reader.GetInt64(0) >= 8192 || reader.GetInt64(1) + size > 256L*1024*1024 ||
            reader.GetInt64(2) >= 1024 || reader.GetInt64(3) + size > 64L*1024*1024)
            throw new ApiError(507, "BLOB_QUOTA");
    }

    private sealed record Upload(Guid Owner, int Size, byte[] Digest, int Offset, bool Complete);

    private static async Task<Upload?> Lookup(NpgsqlConnection c, Guid group, Guid id, CancellationToken ct)
    {
        await using var cmd = Sql.Cmd(c, """
            SELECT owner_id, octet_length(ciphertext), digest, octet_length(ciphertext), true
                FROM private_blobs WHERE conversation_id=$1 AND blob_id=$2
            UNION ALL SELECT owner_id,size,digest,octet_length(prefix),false FROM private_blob_uploads
                WHERE conversation_id=$1 AND blob_id=$2 AND expires_at>now()
            """, group, id);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct)) return null;
        return new(reader.GetGuid(0), reader.GetInt32(1), reader.GetFieldValue<byte[]>(2), reader.GetInt32(3), reader.GetBoolean(4));
    }

    private static IResult Ack(int offset, bool complete, byte[] digest) =>
        Results.Ok(new { offset, complete, digest = Convert.ToHexStringLower(digest) });

    private static async Task<IResult> Progress(Guid group, Guid id, HttpContext ctx, NpgsqlDataSource db, CancellationToken ct)
    {
        var actor = await Sql.Authenticate(ctx, db);
        await using var c = await db.OpenConnectionAsync(ct);
        await using var tx = await c.BeginTransactionAsync(ct);
        await LockSessionAndMember(c, group, actor, ct);
        var upload = await Lookup(c, group, id, ct);
        if (upload is null || upload.Owner != actor.UserId) throw new ApiError(404, "BLOB_NOT_FOUND");
        return Ack(upload.Offset, upload.Complete, upload.Digest);
    }

    private static async Task<IResult> PutPart(Guid group, Guid id, int offset, HttpContext ctx, NpgsqlDataSource db, CancellationToken ct)
    {
        var actor = await Sql.Authenticate(ctx, db);
        if (!int.TryParse(ctx.Request.Headers["X-Blob-Length"], out var size) || size is < 17 or > MaxCiphertext)
            throw new ApiError(413, "BLOB_SIZE");
        var digestText = ctx.Request.Headers["X-Blob-SHA256"].ToString();
        if (digestText.Length != 64 || !digestText.All(Uri.IsHexDigit))
            throw new ApiError(400, "BLOB_DIGEST");
        var digest = Convert.FromHexString(digestText);
        if (offset < 0 || offset >= size || offset % Chunk != 0) throw new ApiError(400, "BLOB_OFFSET");
        var count = Math.Min(Chunk, size - offset);
        if (ctx.Request.ContentLength != count) throw new ApiError(400, "BLOB_PART_LENGTH");
        if (!string.Equals(ctx.Request.ContentType, "application/octet-stream", StringComparison.OrdinalIgnoreCase))
            throw new ApiError(415, "BLOB_CONTENT_TYPE");
        await using (var c = await db.OpenConnectionAsync(ct))
            await Sql.RequireMember(c, group, actor.DeviceId);
        if (!await UploadSlots.WaitAsync(0, ct)) throw new ApiError(429, "BLOB_UPLOAD_BUSY");
        try
        {
            var data = new byte[count];
            await ctx.Request.Body.ReadExactlyAsync(data, ct);
            await using var c = await db.OpenConnectionAsync(ct);
            await using var tx = await c.BeginTransactionAsync(ct);
            await LockSessionAndMember(c, group, actor, ct);
            await RequireWritable(c, group, ct);
            await LockUploads(c, ct);
            var upload = await Lookup(c, group, id, ct);
            int next = upload?.Offset ?? 0;
            if (upload is not null && (upload.Owner != actor.UserId || upload.Size != size ||
                !CryptographicOperations.FixedTimeEquals(digest, upload.Digest)))
                throw new ApiError(409, "BLOB_ID_CONFLICT");
            if (offset > next) throw new ApiError(409, "BLOB_OFFSET");
            if (offset < next)
            {
                var sql = upload!.Complete
                    ? "SELECT substring(ciphertext FROM $3 FOR $4) FROM private_blobs WHERE conversation_id=$1 AND blob_id=$2"
                    : "SELECT substring(prefix FROM $3 FOR $4) FROM private_blob_uploads WHERE conversation_id=$1 AND blob_id=$2";
                await using var match = Sql.Cmd(c, sql, group, id, offset+1, count);
                var existing = (byte[]?)await match.ExecuteScalarAsync(ct);
                if (existing is null || !CryptographicOperations.FixedTimeEquals(existing, data))
                    throw new ApiError(409, "BLOB_PART_CONFLICT");
                return Ack(next, upload.Complete, digest);
            }
            if (upload is null)
            {
                await Reserve(c, actor.UserId, size, ct);
                await using var insert = Sql.Cmd(c, """
                    INSERT INTO private_blob_uploads VALUES($1,$2,$3,$4,$5,''::bytea,now()+interval '24 hours')
                    """, group, id, actor.UserId, size, digest);
                await insert.ExecuteNonQueryAsync(ct);
            }
            next += count;
            if (next == size)
            {
                await using var finish = Sql.Cmd(c, """
                    DELETE FROM private_blob_uploads WHERE conversation_id=$1 AND blob_id=$2 RETURNING prefix
                    """, group, id);
                var prefix = (byte[])(await finish.ExecuteScalarAsync(ct))!;
                var payload = new byte[size];
                prefix.CopyTo(payload, 0);
                data.CopyTo(payload, offset);
                if (!CryptographicOperations.FixedTimeEquals(digest, SHA256.HashData(payload)))
                    throw new ApiError(409, "BLOB_DIGEST_MISMATCH");
                await using var publish = Sql.Cmd(c, "INSERT INTO private_blobs VALUES($1,$2,$3,$4,$5)", group, id, actor.UserId, payload, digest);
                await publish.ExecuteNonQueryAsync(ct);
            }
            else
            {
                await using var append = Sql.Cmd(c, """
                    UPDATE private_blob_uploads SET prefix=prefix || $3, expires_at=now()+interval '24 hours'
                    WHERE conversation_id=$1 AND blob_id=$2
                    """, group, id, data);
                await append.ExecuteNonQueryAsync(ct);
            }
            await tx.CommitAsync(ct);
            return Ack(next, next == size, digest);
        }
        finally { UploadSlots.Release(); }
    }
}
