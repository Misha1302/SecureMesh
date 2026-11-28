using System.Globalization;
using System.Net.Mail;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Npgsql;
using NSec.Cryptography;

namespace SecureMesh;

public sealed record Registration(string Username, string Email, string? Password = null, string? Credential = null, string? DisplayName = null);
public sealed record Verification(string Token);
public sealed record AccountRecoveryRequest(string Email);
public sealed record AccountRecoveryCompletion(string Token, string? Password = null, string? Credential = null, string? Username = null);
public sealed record VerificationResend(string Username, string? Password = null, string? Credential = null);
public sealed record Challenge(string Username, Guid DeviceId);
public sealed record Login(string Username, Guid DeviceId, string PublicKey, Guid ChallengeId, string Signature, string? ClientOs = null, string? Password = null, string? Credential = null, Guid? ExpectedUserId = null, string? ExpectedTrustState = null);
public sealed record Refresh(string Token);
public static class Identity
{
    internal static readonly string DummyPhc = Passwords.Hash(Sql.Token()).GetAwaiter().GetResult();
    public static void MapIdentity(this WebApplication app)
    {
        app.MapDeviceNames();
        foreach (var version in new[] {1, 2})
        app.MapPost($"/v{version}/auth/register", async (Registration input, NpgsqlDataSource db, VerificationEmailQueue email, CancellationToken cancellationToken) =>
        {
            var secret = Passwords.Input(version, input.Password, input.Credential) ?? throw new ApiError(400, "INVALID_REGISTRATION");
            var display = version == 2 ? DisplayNames.Normalize(input.DisplayName) : "";
            var username = input.Username.ToLowerInvariant();
            if (!Regex.IsMatch(username, "^[a-z0-9_]{3,32}$") || input.Email.Length > 254 || (version == 1 && new StringInfo(secret).LengthInTextElements < 16) || (version == 2 && display.Length == 0) || !MailAddress.TryCreate(input.Email, out var mail) || mail.Address != input.Email)
                throw new ApiError(400, "INVALID_REGISTRATION");
            var phc = Passwords.Marker(version) + await Passwords.Hash(secret);
            var user = Guid.NewGuid();
            await using var c = await db.OpenConnectionAsync(cancellationToken);
            await using var tx = await c.BeginTransactionAsync(cancellationToken);
            await using var insert = Sql.Cmd(c, """
                INSERT INTO users(id,username,email,password_hash,display_name)
                VALUES($1,$2,$3,$4,NULLIF($5,'')) ON CONFLICT DO NOTHING
                """, user, username, input.Email.ToLowerInvariant(), phc, display);
            if (await insert.ExecuteNonQueryAsync(cancellationToken) == 0)
                return Results.Accepted();

            await email.EnqueueAsync(c, user, input.Email, cancellationToken);
            await tx.CommitAsync(cancellationToken);
            return Results.Accepted();
        });
        foreach (var version in new[] {1, 2})
            app.MapPost($"/v{version}/auth/resend-verification", async (VerificationResend input, NpgsqlDataSource db,
                VerificationEmailQueue email, CancellationToken cancellationToken) =>
            {
                var username = input.Username?.ToLowerInvariant();
                var secret = Passwords.Input(version, input.Password, input.Credential);
                if (username is null || !Regex.IsMatch(username, "^[a-z0-9_]{3,32}$") || secret is null)
                    throw new ApiError(400, "INVALID_REGISTRATION");
                string? phc;
                await using (var lookup = db.CreateCommand("SELECT password_hash FROM users WHERE username=$1"))
                {
                    lookup.Parameters.AddWithValue(username);
                    phc = await lookup.ExecuteScalarAsync(cancellationToken) as string;
                }
                if (!await Passwords.VerifyVersion(version, secret, phc ?? DummyPhc, DummyPhc) || phc is null)
                    return Results.Accepted();

                await using var c = await db.OpenConnectionAsync(cancellationToken);
                await using var tx = await c.BeginTransactionAsync(cancellationToken);
                await using var owner = Sql.Cmd(c, """
                    SELECT id,email FROM users WHERE username=$1 AND password_hash=$2 AND NOT verified FOR UPDATE
                    """, username, phc);
                Guid user;
                string recipient;
                await using (var row = await owner.ExecuteReaderAsync(cancellationToken))
                {
                    if (!await row.ReadAsync(cancellationToken)) return Results.Accepted();
                    user = row.GetGuid(0);
                    recipient = row.GetString(1);
                }

                // A freshly issued token blocks additional sends for five minutes.
                await using var recent = Sql.Cmd(c, """
                    SELECT 1 FROM email_tokens WHERE user_id=$1 AND purpose='verification'
                      AND expires_at>now()+interval '25 minutes' LIMIT 1
                    """, user);
                if (await recent.ExecuteScalarAsync(cancellationToken) is not null)
                    return Results.Accepted();
                // Require at most five explicit resends in each account's 24-hour window.
                await using var budget = Sql.Cmd(c, """
                    UPDATE users SET
                        verification_resends=CASE WHEN verification_resend_window > now()-interval '24 hours'
                            THEN verification_resends+1 ELSE 1 END,
                        verification_resend_window=CASE WHEN verification_resend_window > now()-interval '24 hours'
                            THEN verification_resend_window ELSE now() END
                    WHERE id=$1 AND (verification_resend_window IS NULL
                        OR verification_resend_window <= now()-interval '24 hours' OR verification_resends < 5)
                    """, user);
                if (await budget.ExecuteNonQueryAsync(cancellationToken) == 0)
                    return Results.Accepted();

                await using var invalidate = Sql.Cmd(c, "DELETE FROM email_tokens WHERE user_id=$1 AND purpose='verification'", user);
                await invalidate.ExecuteNonQueryAsync(cancellationToken);
                await email.EnqueueAsync(c, user, recipient, cancellationToken);
                await tx.CommitAsync(cancellationToken);
                return Results.Accepted();
            });

        app.MapPost("/v1/auth/verify-email", async (Verification input, NpgsqlDataSource db, CancellationToken cancellationToken) =>
        {
            await using var c = await db.OpenConnectionAsync(cancellationToken);
            await using var tx = await c.BeginTransactionAsync(cancellationToken);
            var hash = Sql.Hash(input.Token);
            // Lock the account before touching tokens, matching the resend path.
            await using var owner = Sql.Cmd(c, """
                SELECT u.id FROM users u JOIN email_tokens t ON t.user_id=u.id
                WHERE t.hash=$1 AND t.purpose='verification' AND NOT u.verified FOR UPDATE OF u,t
                """, hash);
            if (await owner.ExecuteScalarAsync(cancellationToken) is not Guid user)
                throw new ApiError(400, "INVALID_TOKEN");
            await using var verify = Sql.Cmd(c, """
                UPDATE users SET verified=true WHERE id=$1 AND EXISTS (
                    SELECT 1 FROM email_tokens WHERE hash=$2 AND user_id=$1
                      AND purpose='verification' AND expires_at>statement_timestamp()
                )
                """, user, hash);
            if (await verify.ExecuteNonQueryAsync(cancellationToken) != 1) throw new ApiError(400, "INVALID_TOKEN");
            await using var consume = Sql.Cmd(c, "DELETE FROM email_tokens WHERE user_id=$1 AND purpose='verification'", user);
            await consume.ExecuteNonQueryAsync(cancellationToken);
            await tx.CommitAsync(cancellationToken);
            return Results.NoContent();
        });

        app.MapPost("/v1/auth/recovery/request", async (AccountRecoveryRequest input,
            NpgsqlDataSource db, VerificationEmailQueue email, CancellationToken cancellationToken) =>
        {
            // Keep the response indistinguishable for absent, unverified and rate-limited accounts.
            if (input.Email is null || input.Email.Length > 254 ||
                !MailAddress.TryCreate(input.Email, out var address) || address.Address != input.Email)
                return Results.Accepted();
            await using var c = await db.OpenConnectionAsync(cancellationToken);
            await using var tx = await c.BeginTransactionAsync(cancellationToken);
            Guid user;
            string recipient;
            await using (var owner = Sql.Cmd(c, "SELECT id,email FROM users WHERE email=$1 AND verified FOR UPDATE", input.Email.ToLowerInvariant()))
            await using (var row = await owner.ExecuteReaderAsync(cancellationToken))
            {
                if (!await row.ReadAsync(cancellationToken)) return Results.Accepted();
                user = row.GetGuid(0);
                recipient = row.GetString(1);
            }

            // One message per five minutes, at most five requests in the rolling day.
            await using (var recent = Sql.Cmd(c, """
                SELECT 1 FROM email_tokens WHERE user_id=$1 AND purpose='account_recovery'
                  AND expires_at>statement_timestamp()+interval '25 minutes' LIMIT 1
                """, user))
                if (await recent.ExecuteScalarAsync(cancellationToken) is not null)
                    return Results.Accepted();
            await using (var budget = Sql.Cmd(c, """
                UPDATE users SET
                    recovery_requests=CASE WHEN recovery_window>statement_timestamp()-interval '24 hours'
                        THEN recovery_requests+1 ELSE 1 END,
                    recovery_window=CASE WHEN recovery_window>statement_timestamp()-interval '24 hours'
                        THEN recovery_window ELSE statement_timestamp() END
                WHERE id=$1 AND (recovery_window IS NULL
                    OR recovery_window<=statement_timestamp()-interval '24 hours' OR recovery_requests<5)
                """, user))
                if (await budget.ExecuteNonQueryAsync(cancellationToken) != 1)
                    return Results.Accepted();
            await email.EnqueueAsync(c, user, recipient, cancellationToken, "account_recovery");
            await tx.CommitAsync(cancellationToken);
            return Results.Accepted();
        });

        foreach (var version in new[] { 1, 2 })
            app.MapPost($"/v{version}/auth/recovery/complete", (AccountRecoveryCompletion input,
                NpgsqlDataSource db, CancellationToken cancellationToken) => CompleteRecovery(input, db, version, cancellationToken));

        async Task<IResult> CompleteRecovery(AccountRecoveryCompletion input, NpgsqlDataSource db,
            int version, CancellationToken cancellationToken)
        {
            var secret = Passwords.Input(version, input.Password, input.Credential);
            if (secret is null || input.Token is null || input.Username is null ||
                !Regex.IsMatch(input.Username, "^[a-z0-9_]{3,32}$") ||
                !Regex.IsMatch(input.Token, "^[a-f0-9]{64}$") ||
                (version == 1 && new StringInfo(secret).LengthInTextElements < 16))
                throw new ApiError(400, "INVALID_RECOVERY");
            var tokenHash = Sql.Hash(input.Token);
            Guid user;
            string username;
            string originalHash;
            await using (var lookup = db.CreateCommand("""
                SELECT u.id,u.username,u.password_hash FROM users u
                JOIN email_tokens t ON t.user_id=u.id
                WHERE t.hash=$1 AND t.purpose='account_recovery' AND t.expires_at>statement_timestamp()
                  AND u.verified AND u.username=$2
                """))
            {
                lookup.Parameters.AddWithValue(tokenHash);
                lookup.Parameters.AddWithValue(input.Username);
                await using var row = await lookup.ExecuteReaderAsync(cancellationToken);
                if (!await row.ReadAsync(cancellationToken)) throw new ApiError(400, "INVALID_RECOVERY");
                user = row.GetGuid(0);
                username = row.GetString(1);
                originalHash = row.GetString(2);
            }
            if (originalHash.StartsWith("sm2$", StringComparison.Ordinal) != (version == 2))
                throw new ApiError(400, "INVALID_RECOVERY");
            var newHash = Passwords.Marker(version) + await Passwords.Hash(secret);

            await using var c = await db.OpenConnectionAsync(cancellationToken);
            await using var tx = await c.BeginTransactionAsync(cancellationToken);
            await using (var owner = Sql.Cmd(c, "SELECT id FROM users WHERE id=$1 FOR UPDATE", user))
                await owner.ExecuteScalarAsync(cancellationToken);
            await using (var current = Sql.Cmd(c, """
                SELECT 1 FROM users u JOIN email_tokens t ON t.user_id=u.id
                WHERE u.id=$1 AND u.username=$2 AND u.verified AND t.hash=$3
                  AND t.purpose='account_recovery' AND t.expires_at>statement_timestamp()
                  AND (u.password_hash LIKE 'sm2$%')=$4
                FOR UPDATE OF t
                """, user, username, tokenHash, version == 2))
                if (await current.ExecuteScalarAsync(cancellationToken) is null)
                    throw new ApiError(400, "INVALID_RECOVERY");

            await using (var update = Sql.Cmd(c, "UPDATE users SET password_hash=$1 WHERE id=$2", newHash, user))
                if (await update.ExecuteNonQueryAsync(cancellationToken) != 1)
                    throw new ApiError(400, "INVALID_RECOVERY");
            // Revoke bearer grants and one-time proofs before returning. Device trust and MLS keys are untouched.
            await using (var revoke = Sql.Cmd(c, """
                UPDATE sessions SET revoked=true
                WHERE device_id IN (SELECT id FROM devices WHERE user_id=$1)
                """, user))
                await revoke.ExecuteNonQueryAsync(cancellationToken);
            await using (var challenges = Sql.Cmd(c, "DELETE FROM auth_challenges WHERE username=$1", username))
                await challenges.ExecuteNonQueryAsync(cancellationToken);
            await using (var enrollments = Sql.Cmd(c, "DELETE FROM device_enrollments WHERE user_id=$1 AND activated_at IS NULL", user))
                await enrollments.ExecuteNonQueryAsync(cancellationToken);
            await using (var tokens = Sql.Cmd(c, "DELETE FROM email_tokens WHERE user_id=$1", user))
                await tokens.ExecuteNonQueryAsync(cancellationToken);
            await tx.CommitAsync(cancellationToken);
            return Results.NoContent();
        }
        app.MapPost("/v1/auth/challenge", async (Challenge input, NpgsqlDataSource db) =>
        {
            if (!Regex.IsMatch(input.Username,"^[a-z0-9_]{3,32}$") || input.DeviceId == Guid.Empty) throw new ApiError(400,"INVALID_CHALLENGE");
            var id=Guid.NewGuid();
            var payload=Encoding.UTF8.GetBytes($"SecureMesh/device/v1\n{id:D}\n{input.DeviceId:D}\n{input.Username}\n{Sql.Token()}");
            await using var c=await db.OpenConnectionAsync();
            await using var cmd=Sql.Cmd(c,"""
                WITH owner AS (SELECT id FROM users WHERE username=$2 FOR SHARE)
                INSERT INTO auth_challenges SELECT $1,$2,$3,$4,now()+interval '2 minutes' FROM owner
                """,id,input.Username,input.DeviceId,payload);
            await cmd.ExecuteNonQueryAsync();
            return Results.Ok(new { challengeId=id, payload=Convert.ToBase64String(payload) });
        });
        foreach (var version in new[] {1, 2})
        {
            app.MapPost($"/v{version}/auth/login", (Login input, NpgsqlDataSource db) => SignIn(input, db, version, existingDeviceOnly: false));
            app.MapPost($"/v{version}/auth/reauthenticate", (Login input, NpgsqlDataSource db) => SignIn(input, db, version, existingDeviceOnly: true));
        }
        async Task<IResult> SignIn(Login input, NpgsqlDataSource db, int version, bool existingDeviceOnly)
        {
            if (existingDeviceOnly && (input.ExpectedUserId is null || input.ExpectedUserId == Guid.Empty ||
                input.ExpectedTrustState is not ("DEVICE_TRUSTED" or "DEVICE_PENDING_TRUST")))
                throw new ApiError(400, "INVALID_REAUTHENTICATION");
            var secret = Passwords.Input(version, input.Password, input.Credential) ?? throw new ApiError(401,"INVALID_CREDENTIALS");
            await using var c=await db.OpenConnectionAsync();
            Guid user=Guid.Empty; string phc=DummyPhc; bool verified=false;
            await using(var cmd=Sql.Cmd(c,"SELECT id,password_hash,verified FROM users WHERE username=$1",input.Username))
            await using(var r=await cmd.ExecuteReaderAsync())
                if(await r.ReadAsync()) { user=r.GetGuid(0); phc=r.GetString(1); verified=r.GetBoolean(2); }
            if(!await Passwords.VerifyVersion(version,secret,phc,DummyPhc) || user==Guid.Empty || !verified) throw new ApiError(401,"INVALID_CREDENTIALS");
            await using var tx=await c.BeginTransactionAsync();
            if (existingDeviceOnly && input.ExpectedUserId != user) throw new ApiError(403, "REAUTHENTICATION_MISMATCH");
            // Serialize device enrollment for the account; concurrent first-login cannot enroll hidden devices.
            await using(var cmd=Sql.Cmd(c,"SELECT id FROM users WHERE id=$1 AND username=$2 AND verified AND password_hash=$3 FOR UPDATE",user,input.Username,phc))
                if(await cmd.ExecuteScalarAsync() is null) throw new ApiError(401,"INVALID_CREDENTIALS");
            byte[] payload;
            await using(var cmd=Sql.Cmd(c,"DELETE FROM auth_challenges WHERE id=$1 AND username=$2 AND device_id=$3 AND expires_at>statement_timestamp() RETURNING payload",input.ChallengeId,input.Username,input.DeviceId))
                payload=await cmd.ExecuteScalarAsync() as byte[] ?? throw new ApiError(401,"DEVICE_PROOF_REQUIRED");
            var publicKey=Convert.FromBase64String(input.PublicKey);
            var key=PublicKey.Import(SignatureAlgorithm.Ed25519,publicKey,KeyBlobFormat.RawPublicKey);
            if(!SignatureAlgorithm.Ed25519.Verify(key,payload,Convert.FromBase64String(input.Signature))) throw new ApiError(401,"DEVICE_PROOF_REQUIRED");
            byte[]? existing=null; Guid owner=Guid.Empty; bool revoked=false, trusted=false;
            await using(var cmd=Sql.Cmd(c,"SELECT user_id,public_key,revoked,trusted FROM devices WHERE id=$1 FOR UPDATE",input.DeviceId))
            await using(var r=await cmd.ExecuteReaderAsync())
                if(await r.ReadAsync()) { owner=r.GetGuid(0); existing=(byte[])r[1]; revoked=r.GetBoolean(2); trusted=r.GetBoolean(3); }
            if(existing is not null && (owner!=user || revoked || !CryptographicOperations.FixedTimeEquals(existing,publicKey))) throw new ApiError(403,"DEVICE_KEY_CHANGED");
            if(existingDeviceOnly && input.ExpectedTrustState != (trusted ? "DEVICE_TRUSTED" : "DEVICE_PENDING_TRUST"))
                throw new ApiError(403,"REAUTHENTICATION_MISMATCH");
            if(existing is null)
            {
                if(existingDeviceOnly) throw new ApiError(403, "REAUTHENTICATION_MISMATCH");
                await using var retired=Sql.Cmd(c,"SELECT 1 FROM device_identifiers WHERE id=$1",input.DeviceId);
                if(await retired.ExecuteScalarAsync() is not null) throw new ApiError(403,"DEVICE_KEY_CHANGED");
                await using var count=Sql.Cmd(c,"SELECT count(*) FROM devices WHERE user_id=$1",user);
                var first = (long)(await count.ExecuteScalarAsync())! == 0;
                await using var quota=Sql.Cmd(c,"SELECT count(*) FROM devices WHERE user_id=$1 AND NOT revoked",user);
                if((long)(await quota.ExecuteScalarAsync())! >= 20) throw new ApiError(429,"DEVICE_LIMIT");
                await using var insert=Sql.Cmd(c,"INSERT INTO devices(id,user_id,public_key,trusted) VALUES($1,$2,$3,$4)",input.DeviceId,user,publicKey,first);
                await insert.ExecuteNonQueryAsync();
            }
            // OS is a bounded client assertion. Preserve the previous observation on legacy login.
            var os = input.ClientOs is "android" or "ios" or "linux" or "windows" or "macos" ? input.ClientOs : "";
            await using(var details=Sql.Cmd(c,"UPDATE devices SET last_login_at=now(),client_os=coalesce(NULLIF($1,''),client_os) WHERE id=$2",os,input.DeviceId))
                await details.ExecuteNonQueryAsync();
            var result=await NewSession(c,input.DeviceId,Guid.NewGuid());
            await tx.CommitAsync();
            return Results.Ok(result);
        }
        app.MapPost("/v1/auth/refresh", async (Refresh input,NpgsqlDataSource db) =>
        {
            await using var c=await db.OpenConnectionAsync(); await using var tx=await c.BeginTransactionAsync();
            Guid id,device,family; bool used,revoked;
            var refreshHash = Sql.Hash(input.Token);
            Guid owner;
            await using (var lookup = Sql.Cmd(c, "SELECT d.user_id FROM sessions s JOIN devices d ON d.id=s.device_id WHERE s.refresh_hash=$1", refreshHash))
                owner = await lookup.ExecuteScalarAsync() as Guid? ?? throw new ApiError(401, "INVALID_REFRESH");
            await using (var account = Sql.Cmd(c, "SELECT id FROM users WHERE id=$1 FOR UPDATE", owner))
                if (await account.ExecuteScalarAsync() is null) throw new ApiError(401, "INVALID_REFRESH");
            await using(var cmd=Sql.Cmd(c,"SELECT id,device_id,family,used,revoked FROM sessions WHERE refresh_hash=$1 AND refresh_expires_at>statement_timestamp() FOR UPDATE",refreshHash))
            await using(var r=await cmd.ExecuteReaderAsync())
            {
                if(!await r.ReadAsync()) throw new ApiError(401,"INVALID_REFRESH");
                id=r.GetGuid(0); device=r.GetGuid(1); family=r.GetGuid(2); used=r.GetBoolean(3); revoked=r.GetBoolean(4);
            }
            if(used || revoked)
            {
                await using var revoke=Sql.Cmd(c,"UPDATE sessions SET revoked=true WHERE family=$1",family); await revoke.ExecuteNonQueryAsync();
                await tx.CommitAsync(); throw new ApiError(401,"REFRESH_REUSE");
            }
            await using(var cmd=Sql.Cmd(c,"SELECT id FROM devices WHERE id=$1 AND user_id=$2 AND NOT revoked FOR UPDATE",device,owner))
                if(await cmd.ExecuteScalarAsync() is null) throw new ApiError(401,"DEVICE_REVOKED");
            await using(var cmd=Sql.Cmd(c,"""
                UPDATE sessions SET used=true WHERE id=$1 AND refresh_expires_at>statement_timestamp()
                  AND session_idle_active(last_interactive_at,idle_timeout_days)
                """,id))
                if(await cmd.ExecuteNonQueryAsync()!=1) throw new ApiError(401,"INVALID_REFRESH");
            var result=await NewSession(c,device,family,id); await tx.CommitAsync(); return Results.Ok(result);
        });
        app.MapPost("/v1/auth/logout",async(HttpContext ctx,NpgsqlDataSource db)=>
        {
            var actor=await Sql.Authenticate(ctx,db,false); await using var c=await db.OpenConnectionAsync();
            await using var cmd=Sql.Cmd(c,"UPDATE sessions SET revoked=true WHERE id=$1",actor.SessionId); await cmd.ExecuteNonQueryAsync(); return Results.NoContent();
        });
        app.MapGet("/v1/users/me",async(HttpContext ctx,NpgsqlDataSource db)=>
        {
            var actor = await Sql.Authenticate(ctx, db, false);
            await using var c = await db.OpenConnectionAsync();
            await using var cmd = Sql.Cmd(c, "SELECT display_name FROM users WHERE id=$1", actor.UserId);
            await using var user = await cmd.ExecuteReaderAsync();
            if (!await user.ReadAsync()) throw new ApiError(401,"AUTH_REQUIRED");
            var name = user.IsDBNull(0) ? null : user.GetString(0);
            var labAccountRemoval = actor.Trusted && app.Environment.IsDevelopment()
                && app.Configuration.GetValue<bool>("EnableLabAccountRemoval");
            return Results.Ok(new { userId=actor.UserId, deviceId=actor.DeviceId,
                trustState=actor.Trusted ? "DEVICE_TRUSTED" : "DEVICE_PENDING_TRUST", displayName=name, labAccountRemoval });
        });
        app.MapPut("/v1/users/me/display-name", async (DisplayNameUpdate input, HttpContext ctx, NpgsqlDataSource db) =>
        {
            var actor = await Sql.Authenticate(ctx, db);
            var name = DisplayNames.Normalize(input.DisplayName);
            await using var c = await db.OpenConnectionAsync();
            await using var cmd = Sql.Cmd(c, """
                UPDATE users u SET display_name=NULLIF($1,'')
                FROM devices d JOIN sessions s ON s.device_id=d.id
                WHERE u.id=$2 AND d.user_id=u.id AND d.id=$3 AND d.trusted AND NOT d.revoked
                  AND s.id=$4 AND NOT s.revoked AND NOT s.used AND s.expires_at>now()
                  AND session_idle_active(s.last_interactive_at,s.idle_timeout_days)
                """, name, actor.UserId, actor.DeviceId, actor.SessionId);
            if (await cmd.ExecuteNonQueryAsync() != 1) throw new ApiError(401, "AUTH_REQUIRED");
            return Results.Ok(new { displayName = name.Length == 0 ? null : name });
        });
        app.MapGet("/v1/devices",async(HttpContext ctx,NpgsqlDataSource db)=>
        {
            var a=await Sql.Authenticate(ctx,db); await using var c=await db.OpenConnectionAsync();
            await using var cmd=Sql.Cmd(c,"""
                SELECT d.id,d.public_key,d.revoked,d.trusted,d.created_at,d.last_login_at,d.client_os,d.device_name,
                    NOT d.revoked AND EXISTS(SELECT 1 FROM sessions s WHERE s.device_id=d.id
                      AND NOT s.used AND NOT s.revoked AND s.refresh_expires_at>now()
                      AND session_idle_active(s.last_interactive_at,s.idle_timeout_days))
                FROM devices d WHERE d.user_id=$1 ORDER BY (d.id=$2) DESC,d.created_at,d.id
                """,a.UserId,a.DeviceId);
            await using var r=await cmd.ExecuteReaderAsync(); var devices=new List<object>();
            while(await r.ReadAsync()) devices.Add(new {
                id=r.GetGuid(0),publicKey=Convert.ToBase64String((byte[])r[1]),revoked=r.GetBoolean(2),
                trustState=r.GetBoolean(3)?"DEVICE_TRUSTED":"DEVICE_PENDING_TRUST",
                isCurrent=r.GetGuid(0)==a.DeviceId,createdAt=r.GetDateTime(4),
                lastLoginAt=r.IsDBNull(5)?(DateTime?)null:r.GetDateTime(5),
                clientOs=r.IsDBNull(6)?null:r.GetString(6),name=r.IsDBNull(7)?null:r.GetString(7),
                hasRefreshableSession=r.GetBoolean(8)
            });
            return Results.Ok(devices);
        });
        app.MapDelete("/v1/devices/{id:guid}",async(Guid id,HttpContext ctx,NpgsqlDataSource db)=>
        {
            var a=await Sql.Authenticate(ctx,db); await using var c=await db.OpenConnectionAsync();
            await using var tx=await c.BeginTransactionAsync();
            await Sql.LockTrustedProfileOwner(c,a,ctx.RequestAborted);
            await using var cmd=Sql.Cmd(c,"UPDATE devices SET revoked=true WHERE id=$1 AND user_id=$2",id,a.UserId);
            if(await cmd.ExecuteNonQueryAsync()!=1) throw new ApiError(404,"DEVICE_NOT_FOUND");
            await tx.CommitAsync(); return Results.NoContent();
        });
    }
    private static async Task<object> NewSession(NpgsqlConnection c,Guid device,Guid family,Guid? previousSession=null)
    {
        var access=Sql.Token(); var refresh=Sql.Token();
        await using var cmd=Sql.Cmd(c,"""
            INSERT INTO sessions(id,family,device_id,access_hash,refresh_hash,expires_at,refresh_expires_at,
                                 last_interactive_at,idle_timeout_days)
            SELECT $1,$2,$3,$4,$5,now()+interval '15 minutes',now()+interval '30 days',
                coalesce(s.last_interactive_at,statement_timestamp()),
                CASE WHEN s.id IS NULL THEN 7 ELSE s.idle_timeout_days END
            FROM (SELECT $6::uuid AS id) previous LEFT JOIN sessions s ON s.id=previous.id
            """,Guid.NewGuid(),family,device,Sql.Hash(access),Sql.Hash(refresh),(object?)previousSession ?? DBNull.Value);
        await cmd.ExecuteNonQueryAsync();
        await using var state=Sql.Cmd(c,"SELECT trusted FROM devices WHERE id=$1",device);
        var trusted=(bool)(await state.ExecuteScalarAsync())!;
        return new {accessToken=access,refreshToken=refresh,expiresIn=900,deviceId=device,trustState=trusted?"DEVICE_TRUSTED":"DEVICE_PENDING_TRUST"};
    }
}
