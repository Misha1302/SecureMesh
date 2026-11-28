using System.Security.Cryptography;
using System.Text;
using Konscious.Security.Cryptography;
using Npgsql;

namespace SecureMesh;

public static class Passwords
{
    // The extra '$' also makes older six-component PHC parsers reject this row.
    public static string Marker(int version) => version == 2 ? "sm2$" : "";
    public static string? Input(int version, string? password, string? credential)
    {
        if (version == 1) return credential is null && password is { Length: >= 1 and <= 256 } ? password : null;
        if (version != 2 || password is not null || credential is not { Length: 44 }) return null;
        Span<byte> decoded = stackalloc byte[32];
        return Convert.TryFromBase64String(credential, decoded, out var len) && len == 32 &&
            Convert.ToBase64String(decoded) == credential ? credential : null;
    }
    public static async Task<bool> VerifyVersion(int version, string secret, string stored, string dummy)
    {
        bool matches = stored.StartsWith("sm2$", StringComparison.Ordinal) == (version == 2);
        return await Verify(secret, matches ? stored[Marker(version).Length..] : dummy) && matches;
    }

    private const int Memory = 65536;
    public static async Task<string> Hash(string password)
    {
        var salt = RandomNumberGenerator.GetBytes(16);
        var hash = await Derive(password, salt);
        return $"$argon2id$v=19$m={Memory},t=3,p=1${Convert.ToBase64String(salt)}${Convert.ToBase64String(hash)}";
    }
    private static async Task<byte[]> Derive(string password, byte[] salt)
    {
        using var argon = new Argon2id(Encoding.UTF8.GetBytes(password)) { Salt = salt, MemorySize = Memory, Iterations = 3, DegreeOfParallelism = 1 };
        return await argon.GetBytesAsync(32);
    }
    public static async Task<bool> Verify(string password, string phc)
    {
        var parts = phc.Split('$');
        if (parts.Length != 6 || parts[3] != $"m={Memory},t=3,p=1") return false;
        return CryptographicOperations.FixedTimeEquals(await Derive(password, Convert.FromBase64String(parts[4])), Convert.FromBase64String(parts[5]));
    }
}

public sealed record Actor(Guid UserId, Guid DeviceId, Guid SessionId, bool Trusted);
public sealed class ApiError(int status, string code) : Exception(code)
{
    public int Status { get; } = status;
    public string Code { get; } = code;
}
public static class Sql
{
    public static NpgsqlCommand Cmd(NpgsqlConnection c, string sql, params object[] values)
    {
        var cmd = new NpgsqlCommand(sql, c);
        foreach (var value in values) cmd.Parameters.AddWithValue(value);
        return cmd;
    }
    public static byte[] Hash(string token) => SHA256.HashData(Encoding.UTF8.GetBytes(token));
    public static string Token() => Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
    internal static async Task LockTrustedProfileOwner(NpgsqlConnection c, Actor actor, CancellationToken cancellationToken)
        => await LockAuthenticatedProfileOwner(c, actor, requireTrusted: true, cancellationToken: cancellationToken);

    internal static async Task LockAuthenticatedProfileOwner(NpgsqlConnection c, Actor actor,
        bool requireTrusted, CancellationToken cancellationToken)
    {
        // Serialize with device revocation, then recheck this session while it holds the account lock.
        await using (var owner = Sql.Cmd(c, "SELECT id FROM users WHERE id=$1 FOR UPDATE", actor.UserId))
            await owner.ExecuteScalarAsync(cancellationToken);
        await using (var session = Sql.Cmd(c, """
            SELECT 1 FROM sessions s JOIN devices d ON d.id=s.device_id
            WHERE s.id=$1 AND d.id=$2 AND d.user_id=$3 AND (NOT $4 OR d.trusted) AND NOT d.revoked
                AND NOT s.used AND NOT s.revoked AND s.expires_at>now()
                AND session_idle_active(s.last_interactive_at,s.idle_timeout_days)
            """, actor.SessionId, actor.DeviceId, actor.UserId, requireTrusted))
            if (await session.ExecuteScalarAsync(cancellationToken) is null)
                throw new ApiError(401, "AUTH_REQUIRED");
    }

    internal static async Task LockTrustedDeliverySession(NpgsqlConnection c, Actor actor,
        CancellationToken cancellationToken)
    {
        await using (var owner = Sql.Cmd(c, "SELECT id FROM users WHERE id=$1 FOR SHARE", actor.UserId))
            await owner.ExecuteScalarAsync(cancellationToken);
        await using (var session = Sql.Cmd(c, """
            SELECT 1 FROM sessions s JOIN devices d ON d.id=s.device_id
            WHERE s.id=$1 AND d.id=$2 AND d.user_id=$3 AND d.trusted AND NOT d.revoked
              AND NOT s.used AND NOT s.revoked AND s.expires_at>statement_timestamp()
              AND session_idle_active(s.last_interactive_at,s.idle_timeout_days)
            """, actor.SessionId, actor.DeviceId, actor.UserId))
            if (await session.ExecuteScalarAsync(cancellationToken) is null)
                throw new ApiError(401, "AUTH_REQUIRED");
    }

    public static async Task<Actor> Authenticate(HttpContext ctx, NpgsqlDataSource db, bool requireTrusted = true)
    {
        var header = ctx.Request.Headers.Authorization.ToString();
        if (!header.StartsWith("Bearer ", StringComparison.Ordinal) || header.Length > 200) throw new ApiError(401, "AUTH_REQUIRED");
        await using var c = await db.OpenConnectionAsync(ctx.RequestAborted);
        await using var cmd = Cmd(c, """
            SELECT d.user_id,d.id,s.id,d.trusted FROM sessions s JOIN devices d ON d.id=s.device_id
            WHERE s.access_hash=$1 AND s.expires_at>now() AND NOT s.revoked AND NOT s.used AND NOT d.revoked
              AND session_idle_active(s.last_interactive_at,s.idle_timeout_days)
            """, Hash(header[7..]));
        await using var r = await cmd.ExecuteReaderAsync(ctx.RequestAborted);
        if (!await r.ReadAsync(ctx.RequestAborted)) throw new ApiError(401, "AUTH_REQUIRED");
        var trusted = r.GetBoolean(3);
        if (requireTrusted && !trusted) throw new ApiError(403, "DEVICE_PENDING_TRUST");
        return new Actor(r.GetGuid(0), r.GetGuid(1), r.GetGuid(2), trusted);
    }
    public static async Task<long> DeliveryFloor(NpgsqlConnection c, Guid conversation, Guid device)
    {
        await using var cmd=Cmd(c,"SELECT m.join_seq FROM conversation_devices m JOIN devices d ON d.id=m.device_id WHERE m.conversation_id=$1 AND d.id=$2 AND d.trusted AND NOT d.revoked",conversation,device);
        return await cmd.ExecuteScalarAsync() is long floor ? floor : throw new ApiError(403,"MEMBERSHIP_REQUIRED");
    }
    public static async Task RequireMember(NpgsqlConnection c, Guid conversation, Guid device)
    {
        await using var cmd = Cmd(c, "SELECT 1 FROM members m JOIN devices d ON d.id=m.device_id WHERE conversation_id=$1 AND device_id=$2 AND NOT d.revoked AND d.trusted", conversation, device);
        if (await cmd.ExecuteScalarAsync() is null) throw new ApiError(403, "MEMBERSHIP_REQUIRED");
    }
}
