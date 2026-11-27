using System.Text;
using Npgsql;
using NSec.Cryptography;

namespace SecureMesh;

public sealed record EnrollmentSignature(byte[] Signature);

public static class DeviceTrust
{
    internal static byte[] GrantPayload(Guid approver, byte[] payload, byte[] candidateSignature) =>
        Encoding.UTF8.GetBytes($"SecureMesh/enrollment-grant/v1\n{approver:D}\n{Convert.ToBase64String(payload)}\n{Convert.ToBase64String(candidateSignature)}");

    internal static bool Verify(byte[] publicKey, byte[] payload, byte[] signature) =>
        publicKey.Length == 32 && signature.Length == 64 && SignatureAlgorithm.Ed25519.Verify(
            PublicKey.Import(SignatureAlgorithm.Ed25519, publicKey, KeyBlobFormat.RawPublicKey), payload, signature);

    public static void MapDeviceTrust(this WebApplication app)
    {
        app.MapPost("/v1/devices/enrollment", async (HttpContext ctx, NpgsqlDataSource db) =>
        {
            var actor = await Sql.Authenticate(ctx, db, false);
            await using var c = await db.OpenConnectionAsync();
            await using var tx = await c.BeginTransactionAsync();
            await LockAccount(c, actor.UserId);
            byte[] key;
            await using (var cmd = Sql.Cmd(c, "SELECT public_key FROM devices WHERE id=$1 AND NOT trusted AND NOT revoked", actor.DeviceId))
                key = await cmd.ExecuteScalarAsync() as byte[] ?? throw new ApiError(409, "DEVICE_NOT_PENDING");
            await using (var expired = Sql.Cmd(c, "DELETE FROM device_enrollments WHERE device_id=$1 AND approved_at IS NULL AND expires_at<=now()", actor.DeviceId))
                await expired.ExecuteNonQueryAsync();
            await using (var existing = Sql.Cmd(c, "SELECT id,payload FROM device_enrollments WHERE device_id=$1 AND approved_at IS NULL", actor.DeviceId))
            await using (var r = await existing.ExecuteReaderAsync())
                if (await r.ReadAsync())
                    return Results.Ok(new { id = r.GetGuid(0), payload = Convert.ToBase64String((byte[])r[1]) });
            await using(var quota=Sql.Cmd(c,"SELECT count(*) FROM device_enrollment_issuance WHERE device_id=$1 AND created_at>now()-interval '1 day'",actor.DeviceId))
                if((long)(await quota.ExecuteScalarAsync())!>=32) throw new ApiError(429,"ENROLLMENT_LIMIT");
            var id = Guid.NewGuid();
            var issued = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            var expires = issued + 300;
            var payload = Encoding.UTF8.GetBytes($"SecureMesh/enrollment-request/v1\n{actor.UserId:D}\n{actor.DeviceId:D}\n{Convert.ToBase64String(key)}\n{id:D}\n{Sql.Token()}\n{issued}\n{expires}");
            await using (var cmd = Sql.Cmd(c, "INSERT INTO device_enrollments(id,user_id,device_id,payload,expires_at) VALUES($1,$2,$3,$4,$5)", id, actor.UserId, actor.DeviceId, payload, DateTimeOffset.FromUnixTimeSeconds(expires)))
                await cmd.ExecuteNonQueryAsync();
            await using(var cmd=Sql.Cmd(c,"INSERT INTO device_enrollment_issuance(id,device_id) VALUES($1,$2)",id,actor.DeviceId))
                await cmd.ExecuteNonQueryAsync();
            await tx.CommitAsync();
            return Results.Ok(new { id, payload = Convert.ToBase64String(payload) });
        });

        app.MapPost("/v1/devices/enrollment/{id:guid}/proof", async (Guid id, EnrollmentSignature input, HttpContext ctx, NpgsqlDataSource db) =>
        {
            var actor = await Sql.Authenticate(ctx, db, false);
            await using var c = await db.OpenConnectionAsync();
            await using var tx = await c.BeginTransactionAsync();
            await LockAccount(c, actor.UserId);
            byte[] payload, key;
            await using (var cmd = Sql.Cmd(c, """
                SELECT e.payload,d.public_key FROM device_enrollments e JOIN devices d ON d.id=e.device_id
                WHERE e.id=$1 AND e.device_id=$2 AND e.user_id=$3 AND e.expires_at>now() AND e.approved_at IS NULL AND NOT d.revoked AND NOT d.trusted FOR UPDATE OF e
                """, id, actor.DeviceId, actor.UserId))
            await using (var r = await cmd.ExecuteReaderAsync())
            {
                if (!await r.ReadAsync()) throw new ApiError(404, "ENROLLMENT_NOT_PENDING");
                payload = (byte[])r[0]; key = (byte[])r[1];
            }
            if (!Verify(key, payload, input.Signature)) throw new ApiError(403, "INVALID_DEVICE_PROOF");
            await using (var cmd = Sql.Cmd(c, "UPDATE device_enrollments SET candidate_signature=$2 WHERE id=$1", id, input.Signature))
                await cmd.ExecuteNonQueryAsync();
            await tx.CommitAsync();
            return Results.NoContent();
        });

        app.MapGet("/v1/devices/enrollment/{id:guid}", async (Guid id, HttpContext ctx, NpgsqlDataSource db) =>
        {
            var actor = await Sql.Authenticate(ctx, db, false);
            await using var c = await db.OpenConnectionAsync();
            await using var cmd = Sql.Cmd(c, """
                SELECT e.payload,e.candidate_signature,e.approver_id,e.grant_signature,d.public_key,e.approved_at IS NOT NULL,
                       CASE WHEN e.device_id=$3 OR e.approver_id=$3 THEN e.activation_signature END
                FROM device_enrollments e LEFT JOIN devices d ON d.id=e.approver_id
                WHERE e.id=$1 AND e.user_id=$2 AND (e.device_id=$3 OR $4) AND (e.expires_at>now() OR e.approved_at IS NOT NULL)
                """, id, actor.UserId, actor.DeviceId, actor.Trusted);
            await using var r = await cmd.ExecuteReaderAsync();
            if (!await r.ReadAsync()) throw new ApiError(404, "ENROLLMENT_NOT_FOUND");
            return Results.Ok(new {
                id, payload = Convert.ToBase64String((byte[])r[0]),
                candidateSignature = r.IsDBNull(1) ? null : Convert.ToBase64String((byte[])r[1]),
                approverId = r.IsDBNull(2) ? (Guid?)null : r.GetGuid(2),
                grantSignature = r.IsDBNull(3) ? null : Convert.ToBase64String((byte[])r[3]),
                approverKey = r.IsDBNull(4) ? null : Convert.ToBase64String((byte[])r[4]),
                approved = r.GetBoolean(5),
                activationSignature = r.IsDBNull(6) ? null : Convert.ToBase64String((byte[])r[6])
            });
        });

        app.MapPost("/v1/devices/enrollment/{id:guid}/approve", async (Guid id, EnrollmentSignature input, HttpContext ctx, NpgsqlDataSource db) =>
        {
            var actor = await Sql.Authenticate(ctx, db);
            await using var c = await db.OpenConnectionAsync();
            await using var tx = await c.BeginTransactionAsync();
            await LockAccount(c, actor.UserId);
            byte[] approverKey;
            await using (var cmd = Sql.Cmd(c, "SELECT public_key FROM devices WHERE id=$1 AND user_id=$2 AND trusted AND NOT revoked", actor.DeviceId, actor.UserId))
                approverKey = await cmd.ExecuteScalarAsync() as byte[] ?? throw new ApiError(403, "APPROVER_NOT_TRUSTED");
            Guid candidate;
            byte[] payload, proof, candidateKey;
            await using (var cmd = Sql.Cmd(c, """
                SELECT e.device_id,e.payload,e.candidate_signature,d.public_key
                FROM device_enrollments e JOIN devices d ON d.id=e.device_id
                WHERE e.id=$1 AND e.user_id=$2 AND e.expires_at>now() AND e.approved_at IS NULL
                  AND e.candidate_signature IS NOT NULL AND NOT d.revoked AND NOT d.trusted FOR UPDATE OF e
                """, id, actor.UserId))
            await using (var r = await cmd.ExecuteReaderAsync())
            {
                if (!await r.ReadAsync()) throw new ApiError(409, "ENROLLMENT_NOT_PENDING");
                candidate = r.GetGuid(0); payload = (byte[])r[1]; proof = (byte[])r[2]; candidateKey = (byte[])r[3];
            }
            if (!Verify(candidateKey, payload, proof) || !Verify(approverKey, GrantPayload(actor.DeviceId, payload, proof), input.Signature))
                throw new ApiError(403, "INVALID_ENROLLMENT_GRANT");
            await using (var cmd = Sql.Cmd(c, "UPDATE device_enrollments SET approver_id=$2,grant_signature=$3,approved_at=now() WHERE id=$1", id, actor.DeviceId, input.Signature))
                await cmd.ExecuteNonQueryAsync();
            await tx.CommitAsync();
            return Results.NoContent();
        });

        app.MapPost("/v1/devices/enrollment/{id:guid}/activate",async(Guid id,EnrollmentSignature input,HttpContext ctx,NpgsqlDataSource db)=>
        {
            var actor=await Sql.Authenticate(ctx,db,false);
            await using var c=await db.OpenConnectionAsync();await using var tx=await c.BeginTransactionAsync();
            await LockAccount(c,actor.UserId);
            byte[] grant,key;bool activated;
            await using(var cmd=Sql.Cmd(c,"""
                SELECT e.grant_signature,d.public_key,e.activated_at IS NOT NULL
                FROM device_enrollments e JOIN devices d ON d.id=e.device_id JOIN devices a ON a.id=e.approver_id
                WHERE e.id=$1 AND e.device_id=$2 AND e.user_id=$3 AND e.approved_at IS NOT NULL
                  AND (e.expires_at>now() OR e.activated_at IS NOT NULL) AND NOT d.revoked AND a.trusted AND NOT a.revoked FOR UPDATE OF e
                """,id,actor.DeviceId,actor.UserId))
            await using(var r=await cmd.ExecuteReaderAsync())
            {
                if(!await r.ReadAsync()) throw new ApiError(409,"ACTIVATION_NOT_AVAILABLE");
                grant=(byte[])r[0];key=(byte[])r[1];activated=r.GetBoolean(2);
            }
            var payload=Encoding.UTF8.GetBytes($"SecureMesh/enrollment-activate/v1\n{id:D}\n{Convert.ToBase64String(grant)}");
            if(!Verify(key,payload,input.Signature)) throw new ApiError(403,"INVALID_ACTIVATION_PROOF");
            if(!activated)
            {
                await using(var cmd=Sql.Cmd(c,"UPDATE device_enrollments SET activation_signature=$2,activated_at=now() WHERE id=$1",id,input.Signature)) await cmd.ExecuteNonQueryAsync();
                await using(var cmd=Sql.Cmd(c,"UPDATE devices SET trusted=true WHERE id=$1 AND NOT revoked",actor.DeviceId))
                    if(await cmd.ExecuteNonQueryAsync()!=1) throw new ApiError(409,"DEVICE_REVOKED");
            }
            await tx.CommitAsync();return Results.NoContent();
        });
    }

    private static async Task LockAccount(NpgsqlConnection c, Guid user)
    {
        await using var cmd = Sql.Cmd(c, "SELECT id FROM users WHERE id=$1 FOR UPDATE", user);
        await cmd.ExecuteScalarAsync();
    }
}
