using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;
using Npgsql;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611270014_AccountRemoval")]
public sealed class AccountRemovalMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        -- Historical MLS messages authenticate their original sender UUID. Keep that
        -- identifier unique without retaining a public key, credentials or account link.
        CREATE TABLE device_identifiers(id uuid PRIMARY KEY);
        INSERT INTO device_identifiers SELECT id FROM devices;
        CREATE FUNCTION reserve_device_identifier() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          INSERT INTO device_identifiers VALUES(NEW.id);
          RETURN NEW;
        END $$;
        CREATE TRIGGER reserve_device_identifier BEFORE INSERT ON devices
            FOR EACH ROW EXECUTE FUNCTION reserve_device_identifier();
        ALTER TABLE messages DROP CONSTRAINT messages_device_id_fkey,
            ADD FOREIGN KEY(device_id) REFERENCES device_identifiers(id);
        ALTER TABLE conversations ADD COLUMN account_removed boolean NOT NULL DEFAULT false;
        CREATE TABLE account_removal_receipts(proof bytea PRIMARY KEY CHECK(octet_length(proof)=32),
            expires_at timestamptz NOT NULL);
        CREATE INDEX account_removal_receipts_expiry ON account_removal_receipts(expires_at);
        """);
    protected override void Down(MigrationBuilder migrationBuilder) =>
        throw new NotSupportedException("Preserve non-reusable historical MLS sender identifiers.");
}

public sealed record RemoveLabAccount(Guid RequestId, string Password);

public static class AccountRemoval
{
    private const string Path = "/v1/users/me/removal";

    public static void MapAccountRemoval(this WebApplication app)
    {
        app.MapPost(Path, async (RemoveLabAccount input, HttpContext ctx, NpgsqlDataSource db, CancellationToken ct) =>
        {
            if (!app.Environment.IsDevelopment() || !app.Configuration.GetValue<bool>("EnableLabAccountRemoval"))
                throw new ApiError(404, "ACCOUNT_REMOVAL_UNAVAILABLE");
            if (input.RequestId == Guid.Empty || input.Password is null || input.Password.Length is < 1 or > 256)
                throw new ApiError(400, "REMOVAL_CONFIRMATION_REQUIRED");
            var auth = ctx.Request.Headers.Authorization.ToString();
            if (!auth.StartsWith("Bearer ", StringComparison.Ordinal) || auth.Length is <= 7 or > 200)
                throw new ApiError(401, "AUTH_REQUIRED");
            var token = auth[7..];
            for (int attempt=0; ; attempt++)
            {
                try { return await Remove(db, token, input, ct); }
                catch (PostgresException ex) when (ex.SqlState == PostgresErrorCodes.DeadlockDetected && attempt < 2) { }
            }
        });
    }

    private static async Task<IResult> Remove(NpgsqlDataSource db, string token, RemoveLabAccount input, CancellationToken ct)
    {
        var proof = Sql.Hash($"SecureMesh/removal/v1/{input.RequestId:D}/{token}");
        await using var c = await db.OpenConnectionAsync(ct);
        await using var tx = await c.BeginTransactionAsync(ct);
        async Task Run(string sql, params object[] args)
        {
            await using var command = Sql.Cmd(c, sql, args);
            await command.ExecuteNonQueryAsync(ct);
        }
        await Run("SELECT pg_advisory_xact_lock(hashtextextended(encode($1,'hex'),747931))", proof);
        await using (var retry = Sql.Cmd(c, "SELECT 1 FROM account_removal_receipts WHERE proof=$1 AND expires_at>now()", proof))
            if (await retry.ExecuteScalarAsync(ct) is not null) return Results.NoContent();

        Guid account;
        string name;
        await using (var confirm = Sql.Cmd(c, """
            SELECT u.id,u.username,u.password_hash,d.trusted FROM sessions s
            JOIN devices d ON d.id=s.device_id JOIN users u ON u.id=d.user_id
            WHERE s.access_hash=$1 AND NOT s.revoked AND NOT s.used AND s.expires_at>now()
                AND NOT d.revoked AND u.verified FOR UPDATE OF u FOR SHARE OF d,s
            """, Sql.Hash(token)))
        await using (var reader = await confirm.ExecuteReaderAsync(ct))
        {
            if (!await reader.ReadAsync(ct)) throw new ApiError(401,"AUTH_REQUIRED");
            if (!reader.GetBoolean(3)) throw new ApiError(403,"DEVICE_PENDING_TRUST");
            if (!await Passwords.Verify(input.Password, reader.GetString(2)))
                throw new ApiError(403,"REMOVAL_CONFIRMATION_FAILED");
            account = reader.GetGuid(0);
            name = reader.GetString(1);
        }
        // Lock the FK parents before collecting dependent rows. A concurrent write
        // either commits before this sweep or can no longer reference a live owner.
        await Run("SELECT id FROM devices WHERE user_id=$1 ORDER BY id FOR UPDATE",account);
        await Run("CREATE TEMP TABLE removed_devices(id uuid PRIMARY KEY) ON COMMIT DROP");
        await Run("INSERT INTO removed_devices SELECT id FROM devices WHERE user_id=$1",account);
        await Run("""
            UPDATE conversations SET account_removed=true WHERE id IN
                (SELECT conversation_id FROM members JOIN removed_devices ON device_id=removed_devices.id)
            """);
        await Run("""
            DELETE FROM conversation_bootstraps WHERE sender_device IN (TABLE removed_devices)
                OR recipient_device IN (TABLE removed_devices)
            """);
        await Run("""
            DELETE FROM key_packages WHERE device_id IN (TABLE removed_devices) OR leased_by IN (TABLE removed_devices)
                OR invitation_id IN (SELECT id FROM chat_requests WHERE recipient_user=$1 OR sender_device IN (TABLE removed_devices))
            """, account);
        await Run("DELETE FROM chat_requests WHERE recipient_user=$1 OR sender_device IN (TABLE removed_devices) OR recipient_device IN (TABLE removed_devices)", account);
        await Run("DELETE FROM device_enrollments WHERE user_id=$1 OR approver_id IN (TABLE removed_devices)",account);
        await Run("DELETE FROM device_enrollment_issuance WHERE device_id IN (TABLE removed_devices)");
        await Run("DELETE FROM cursors WHERE device_id IN (TABLE removed_devices)");
        await Run("DELETE FROM members WHERE device_id IN (TABLE removed_devices)");
        await Run("DELETE FROM auth_challenges WHERE username=$1 OR device_id IN (TABLE removed_devices)",name);
        await Run("DELETE FROM email_tokens WHERE user_id=$1",account);
        await Run("DELETE FROM sessions WHERE device_id IN (TABLE removed_devices)");
        await Run("DELETE FROM private_blob_uploads WHERE owner_id=$1",account);
        await Run("DELETE FROM private_blobs WHERE owner_id=$1",account);
        await Run("DELETE FROM channel_catalog WHERE owner_id=$1",account);
        await Run("DELETE FROM devices WHERE user_id=$1",account);
        // Profile photos, subscriptions, invitations and channel activity cascade.
        await Run("DELETE FROM users WHERE id=$1",account);
        await Run("DELETE FROM account_removal_receipts WHERE expires_at<=now()");
        await Run("INSERT INTO account_removal_receipts VALUES($1,now()+interval '24 hours')",proof);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }
}
