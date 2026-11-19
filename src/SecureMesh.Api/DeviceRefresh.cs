using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.DataProtection;
using Npgsql;
using NSec.Cryptography;

namespace SecureMesh;

public sealed record DeviceRefreshInput(Guid DeviceId, Guid RequestId, string Token, string Signature);
public sealed record DeviceRefreshResult(Guid RequestId, string AccessToken, string RefreshToken, int ExpiresIn, Guid DeviceId, string TrustState, string RefreshBinding);

public sealed class RefreshResponseProtection
{
    public IDataProtector Protector { get; }
    public RefreshResponseProtection(string stateDirectory)
    {
        // Stable across dotnet run / direct DLL launch. Keep the incumbent
        // cursor protector/application discriminator unchanged.
        var provider = DataProtectionProvider.Create(new DirectoryInfo(Path.Combine(stateDirectory, "refresh-keys")),
            options => options.SetApplicationName("SecureMesh.DeviceRefresh.v1"));
        Protector = provider.CreateProtector("SecureMesh.DeviceRefresh.Response.v1");
    }
}

public static class DeviceRefresh
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public static void MapDeviceRefresh(this WebApplication app) =>
        app.MapPost("/v1/auth/refresh/device", Rotate);

    private static async Task<IResult> Rotate(DeviceRefreshInput input, NpgsqlDataSource db, RefreshResponseProtection protection)
    {
        if (input.DeviceId == Guid.Empty || input.RequestId == Guid.Empty || string.IsNullOrEmpty(input.Token) || input.Token.Length != 64 ||
            !Regex.IsMatch(input.Token, "^[0-9a-f]{64}$") || string.IsNullOrEmpty(input.Signature) || input.Signature.Length > 128)
            throw new ApiError(401, "DEVICE_PROOF_REQUIRED");
        var payload = Encoding.UTF8.GetBytes($"SecureMesh/refresh/v1\n{input.RequestId:D}\n{input.DeviceId:D}\n{Convert.ToHexString(Sql.Hash(input.Token)).ToLowerInvariant()}");
        byte[] signature;
        try { signature = Convert.FromBase64String(input.Signature); }
        catch (FormatException) { throw new ApiError(401, "DEVICE_PROOF_REQUIRED"); }
        if (signature.Length != 64) throw new ApiError(401, "DEVICE_PROOF_REQUIRED");
        var digest = SHA256.HashData([.. payload, .. signature]);
        var protector = protection.Protector;

        await using var c = await db.OpenConnectionAsync();
        await using var tx = await c.BeginTransactionAsync();
        Guid oldId, family;
        bool used, revoked;
        await using (var cmd = Sql.Cmd(c, "SELECT id,family,used,revoked FROM sessions WHERE refresh_hash=$1 AND device_id=$2 AND refresh_expires_at>now() FOR UPDATE", Sql.Hash(input.Token), input.DeviceId))
        await using (var reader = await cmd.ExecuteReaderAsync())
        {
            if (!await reader.ReadAsync()) throw new ApiError(401, "INVALID_REFRESH");
            oldId = reader.GetGuid(0); family = reader.GetGuid(1); used = reader.GetBoolean(2); revoked = reader.GetBoolean(3);
        }
        // Prove the current device before revealing replay state or mutating a
        // family. A stolen bearer alone cannot retrieve a cached response/DoS it.
        byte[] key;
        bool trusted;
        await using (var cmd = Sql.Cmd(c, "SELECT public_key,trusted FROM devices WHERE id=$1 AND NOT revoked FOR UPDATE", input.DeviceId))
        await using (var reader = await cmd.ExecuteReaderAsync())
        {
            if (!await reader.ReadAsync()) throw new ApiError(401, "DEVICE_REVOKED");
            key = (byte[])reader[0]; trusted = reader.GetBoolean(1);
        }
        if (!SignatureAlgorithm.Ed25519.Verify(PublicKey.Import(SignatureAlgorithm.Ed25519, key, KeyBlobFormat.RawPublicKey), payload, signature))
            throw new ApiError(401, "DEVICE_PROOF_REQUIRED");
        if (revoked) throw new ApiError(401, "INVALID_REFRESH");

        if (used)
        {
            Guid requestId = Guid.Empty;
            byte[]? storedDigest = null;
            string? protectedResponse = null;
            bool live = false;
            int expiresIn = 0;
            await using (var cmd = Sql.Cmd(c, """
                SELECT r.request_id,r.request_digest,r.protected_response,
                  r.expires_at>now() AND NOT s.revoked AND NOT s.used AND s.refresh_expires_at>now(),
                  greatest(0,extract(epoch FROM s.expires_at-now())::int)
                FROM refresh_rotations r JOIN sessions s ON s.id=r.new_session_id
                WHERE r.old_session_id=$1
                """, oldId))
            await using (var reader = await cmd.ExecuteReaderAsync())
            {
                if (await reader.ReadAsync())
                {
                    requestId = reader.GetGuid(0); storedDigest = (byte[])reader[1]; protectedResponse = reader.GetString(2);
                    live = reader.GetBoolean(3); expiresIn = reader.GetInt32(4);
                }
            }
            if (requestId == input.RequestId && storedDigest is not null && CryptographicOperations.FixedTimeEquals(storedDigest, digest))
            {
                if (!live) throw new ApiError(401, "REFRESH_RECOVERY_EXPIRED");
                DeviceRefreshResult recovered;
                try
                {
                    recovered = JsonSerializer.Deserialize<DeviceRefreshResult>(protector.Unprotect(protectedResponse!), Json)
                        ?? throw new CryptographicException();
                }
                catch (Exception error) when (error is CryptographicException or JsonException)
                { throw new ApiError(503, "REFRESH_STATE_UNAVAILABLE"); }
                if (recovered.DeviceId != input.DeviceId || recovered.RequestId != input.RequestId)
                    throw new ApiError(503, "REFRESH_STATE_UNAVAILABLE");
                await tx.CommitAsync();
                // Never extend the access deadline just because a reply was lost.
                return Results.Ok(recovered with { ExpiresIn = expiresIn, TrustState = trusted ? "DEVICE_TRUSTED" : "DEVICE_PENDING_TRUST" });
            }
            await using (var cmd = Sql.Cmd(c, "UPDATE sessions SET revoked=true WHERE family=$1", family)) await cmd.ExecuteNonQueryAsync();
            await tx.CommitAsync();
            throw new ApiError(401, "REFRESH_REUSE");
        }

        await using (var cmd = Sql.Cmd(c, "DELETE FROM refresh_rotations WHERE device_id=$1 AND expires_at<=now()", input.DeviceId)) await cmd.ExecuteNonQueryAsync();
        await using (var cmd = Sql.Cmd(c, "SELECT 1 FROM refresh_rotations WHERE device_id=$1 AND request_id=$2", input.DeviceId, input.RequestId))
            if (await cmd.ExecuteScalarAsync() is not null) throw new ApiError(409, "REFRESH_REQUEST_CONFLICT");
        await using (var cmd = Sql.Cmd(c, "SELECT count(*) FROM refresh_rotations WHERE device_id=$1 AND created_at>now()-interval '1 day'", input.DeviceId))
            if ((long)(await cmd.ExecuteScalarAsync())! >= 512) throw new ApiError(429, "REFRESH_LIMIT");
        await using (var cmd = Sql.Cmd(c, "UPDATE sessions SET used=true,device_bound_refresh=true WHERE id=$1", oldId)) await cmd.ExecuteNonQueryAsync();
        var next = await Identity.NewSession(c, input.DeviceId, family, true);
        var result = new DeviceRefreshResult(input.RequestId, next.AccessToken, next.RefreshToken, next.ExpiresIn, input.DeviceId, next.TrustState, next.RefreshBinding);
        await using (var cmd = Sql.Cmd(c, """
            INSERT INTO refresh_rotations(old_session_id,new_session_id,device_id,request_id,request_digest,protected_response)
              SELECT $1,id,$2,$3,$4,$5 FROM sessions WHERE refresh_hash=$6
            """, oldId, input.DeviceId, input.RequestId, digest, protector.Protect(JsonSerializer.Serialize(result, Json)), Sql.Hash(next.RefreshToken)))
            if (await cmd.ExecuteNonQueryAsync() != 1) throw new ApiError(503, "REFRESH_STATE_UNAVAILABLE");
        await tx.CommitAsync();
        return Results.Ok(result);
    }
}
