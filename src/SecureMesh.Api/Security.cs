using System.Security.Cryptography;
using System.Text;
using Konscious.Security.Cryptography;
using Npgsql;

namespace SecureMesh;

public static class Passwords
{
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

public sealed record Actor(Guid UserId, Guid DeviceId, Guid SessionId);
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
    public static async Task<Actor> Authenticate(HttpContext ctx, NpgsqlDataSource db)
    {
        var header = ctx.Request.Headers.Authorization.ToString();
        if (!header.StartsWith("Bearer ", StringComparison.Ordinal) || header.Length > 200) throw new ApiError(401, "AUTH_REQUIRED");
        await using var c = await db.OpenConnectionAsync(ctx.RequestAborted);
        await using var cmd = Cmd(c, """
            SELECT d.user_id,d.id,s.id FROM sessions s JOIN devices d ON d.id=s.device_id
            WHERE s.access_hash=$1 AND s.expires_at>now() AND NOT s.revoked AND NOT s.used AND NOT d.revoked
            """, Hash(header[7..]));
        await using var r = await cmd.ExecuteReaderAsync(ctx.RequestAborted);
        if (!await r.ReadAsync(ctx.RequestAborted)) throw new ApiError(401, "AUTH_REQUIRED");
        return new Actor(r.GetGuid(0), r.GetGuid(1), r.GetGuid(2));
    }
    public static async Task RequireMember(NpgsqlConnection c, Guid conversation, Guid device)
    {
        await using var cmd = Cmd(c, "SELECT 1 FROM members m JOIN devices d ON d.id=m.device_id WHERE conversation_id=$1 AND device_id=$2 AND NOT d.revoked", conversation, device);
        if (await cmd.ExecuteScalarAsync() is null) throw new ApiError(403, "MEMBERSHIP_REQUIRED");
    }
}
