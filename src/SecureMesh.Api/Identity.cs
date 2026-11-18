using System.Net.Mail;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Npgsql;
using NSec.Cryptography;

namespace SecureMesh;

public sealed record Registration(string Username, string Email, string Password);
public sealed record Verification(string Token);
public sealed record Challenge(string Username, Guid DeviceId);
public sealed record Login(string Username, string Password, Guid DeviceId, string PublicKey, Guid ChallengeId, string Signature);
public sealed record Refresh(string Token);
public static class Identity
{
    private static readonly string DummyPhc = Passwords.Hash(Sql.Token()).GetAwaiter().GetResult();
    public static void MapIdentity(this WebApplication app)
    {
        app.MapPost("/v1/auth/register", async (Registration input, NpgsqlDataSource db) =>
        {
            var username = input.Username.ToLowerInvariant();
            if (!Regex.IsMatch(username, "^[a-z0-9_]{3,32}$") || input.Email.Length > 254 || input.Password.Length is < 12 or > 256 || !MailAddress.TryCreate(input.Email, out var mail) || mail.Address != input.Email)
                throw new ApiError(400, "INVALID_REGISTRATION");
            var phc = await Passwords.Hash(input.Password);
            var token = Sql.Token(); var user = Guid.NewGuid();
            await using var c = await db.OpenConnectionAsync();
            await using var tx = await c.BeginTransactionAsync();
            try
            {
                await using var insert = Sql.Cmd(c, "INSERT INTO users(id,username,email,password_hash) VALUES($1,$2,$3,$4)", user, username, input.Email.ToLowerInvariant(), phc);
                await insert.ExecuteNonQueryAsync();
                await using var verify = Sql.Cmd(c, "INSERT INTO email_tokens VALUES($1,$2,now()+interval '30 minutes')", Sql.Hash(token), user);
                await verify.ExecuteNonQueryAsync();
            }
            catch (PostgresException e) when (e.SqlState == "23505") { return Results.Accepted(); }
            // Hard-coded loopback development sink; never sends to an external mail relay.
            using var smtp = new SmtpClient("127.0.0.1", 51028);
            using var message = new MailMessage("no-reply@securemesh.test", input.Email, "SecureMesh verification", token);
            await smtp.SendMailAsync(message);
            await tx.CommitAsync();
            return Results.Accepted();
        });
        app.MapPost("/v1/auth/verify-email", async (Verification input, NpgsqlDataSource db) =>
        {
            await using var c = await db.OpenConnectionAsync();
            await using var cmd = Sql.Cmd(c, """
                WITH consumed AS (DELETE FROM email_tokens WHERE hash=$1 AND expires_at>now() RETURNING user_id)
                UPDATE users SET verified=true WHERE id IN (SELECT user_id FROM consumed)
                """, Sql.Hash(input.Token));
            if (await cmd.ExecuteNonQueryAsync() != 1) throw new ApiError(400, "INVALID_TOKEN");
            return Results.NoContent();
        });
        app.MapPost("/v1/auth/challenge", async (Challenge input, NpgsqlDataSource db) =>
        {
            if (!Regex.IsMatch(input.Username,"^[a-z0-9_]{3,32}$") || input.DeviceId == Guid.Empty) throw new ApiError(400,"INVALID_CHALLENGE");
            var id=Guid.NewGuid();
            var payload=Encoding.UTF8.GetBytes($"SecureMesh/device/v1\n{id:D}\n{input.DeviceId:D}\n{input.Username}\n{Sql.Token()}");
            await using var c=await db.OpenConnectionAsync();
            await using var cmd=Sql.Cmd(c,"INSERT INTO auth_challenges VALUES($1,$2,$3,$4,now()+interval '2 minutes')",id,input.Username,input.DeviceId,payload);
            await cmd.ExecuteNonQueryAsync();
            return Results.Ok(new { challengeId=id, payload=Convert.ToBase64String(payload) });
        });
        app.MapPost("/v1/auth/login", async (Login input, NpgsqlDataSource db) =>
        {
            if(input.Password.Length>256) throw new ApiError(401,"INVALID_CREDENTIALS");
            await using var c=await db.OpenConnectionAsync();
            Guid user=Guid.Empty; string phc=DummyPhc; bool verified=false;
            await using(var cmd=Sql.Cmd(c,"SELECT id,password_hash,verified FROM users WHERE username=$1",input.Username))
            await using(var r=await cmd.ExecuteReaderAsync())
                if(await r.ReadAsync()) { user=r.GetGuid(0); phc=r.GetString(1); verified=r.GetBoolean(2); }
            if(!await Passwords.Verify(input.Password,phc) || user==Guid.Empty || !verified) throw new ApiError(401,"INVALID_CREDENTIALS");
            await using var tx=await c.BeginTransactionAsync();
            // Serialize device enrollment for the account; concurrent first-login cannot enroll hidden devices.
            await using(var cmd=Sql.Cmd(c,"SELECT id FROM users WHERE id=$1 FOR UPDATE",user)) await cmd.ExecuteScalarAsync();
            byte[] payload;
            await using(var cmd=Sql.Cmd(c,"DELETE FROM auth_challenges WHERE id=$1 AND username=$2 AND device_id=$3 AND expires_at>now() RETURNING payload",input.ChallengeId,input.Username,input.DeviceId))
                payload=await cmd.ExecuteScalarAsync() as byte[] ?? throw new ApiError(401,"DEVICE_PROOF_REQUIRED");
            var publicKey=Convert.FromBase64String(input.PublicKey);
            var key=PublicKey.Import(SignatureAlgorithm.Ed25519,publicKey,KeyBlobFormat.RawPublicKey);
            if(!SignatureAlgorithm.Ed25519.Verify(key,payload,Convert.FromBase64String(input.Signature))) throw new ApiError(401,"DEVICE_PROOF_REQUIRED");
            byte[]? existing=null; Guid owner=Guid.Empty; bool revoked=false;
            await using(var cmd=Sql.Cmd(c,"SELECT user_id,public_key,revoked FROM devices WHERE id=$1",input.DeviceId))
            await using(var r=await cmd.ExecuteReaderAsync())
                if(await r.ReadAsync()) { owner=r.GetGuid(0); existing=(byte[])r[1]; revoked=r.GetBoolean(2); }
            if(existing is not null && (owner!=user || revoked || !CryptographicOperations.FixedTimeEquals(existing,publicKey))) throw new ApiError(403,"DEVICE_KEY_CHANGED");
            if(existing is null)
            {
                await using var count=Sql.Cmd(c,"SELECT count(*) FROM devices WHERE user_id=$1",user);
                var first = (long)(await count.ExecuteScalarAsync())! == 0;
                await using var quota=Sql.Cmd(c,"SELECT count(*) FROM devices WHERE user_id=$1 AND NOT revoked",user);
                if((long)(await quota.ExecuteScalarAsync())! >= 20) throw new ApiError(429,"DEVICE_LIMIT");
                await using var insert=Sql.Cmd(c,"INSERT INTO devices(id,user_id,public_key,trusted) VALUES($1,$2,$3,$4)",input.DeviceId,user,publicKey,first);
                await insert.ExecuteNonQueryAsync();
            }
            var result=await NewSession(c,input.DeviceId,Guid.NewGuid());
            await tx.CommitAsync();
            return Results.Ok(result);
        });
        app.MapPost("/v1/auth/refresh", async (Refresh input,NpgsqlDataSource db) =>
        {
            await using var c=await db.OpenConnectionAsync(); await using var tx=await c.BeginTransactionAsync();
            Guid id,device,family; bool used,revoked;
            await using(var cmd=Sql.Cmd(c,"SELECT id,device_id,family,used,revoked FROM sessions WHERE refresh_hash=$1 AND refresh_expires_at>now() FOR UPDATE",Sql.Hash(input.Token)))
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
            await using(var cmd=Sql.Cmd(c,"SELECT id FROM devices WHERE id=$1 AND NOT revoked FOR UPDATE",device))
                if(await cmd.ExecuteScalarAsync() is null) throw new ApiError(401,"DEVICE_REVOKED");
            await using(var cmd=Sql.Cmd(c,"UPDATE sessions SET used=true WHERE id=$1",id)) await cmd.ExecuteNonQueryAsync();
            var result=await NewSession(c,device,family); await tx.CommitAsync(); return Results.Ok(result);
        });
        app.MapPost("/v1/auth/logout",async(HttpContext ctx,NpgsqlDataSource db)=>
        {
            var actor=await Sql.Authenticate(ctx,db,false); await using var c=await db.OpenConnectionAsync();
            await using var cmd=Sql.Cmd(c,"UPDATE sessions SET revoked=true WHERE id=$1",actor.SessionId); await cmd.ExecuteNonQueryAsync(); return Results.NoContent();
        });
        app.MapGet("/v1/users/me",async(HttpContext ctx,NpgsqlDataSource db)=>
        {var a=await Sql.Authenticate(ctx,db,false); return Results.Ok(new {userId=a.UserId,deviceId=a.DeviceId,trustState=a.Trusted?"DEVICE_TRUSTED":"DEVICE_PENDING_TRUST"});});
        app.MapGet("/v1/devices",async(HttpContext ctx,NpgsqlDataSource db)=>
        {
            var a=await Sql.Authenticate(ctx,db); await using var c=await db.OpenConnectionAsync();
            await using var cmd=Sql.Cmd(c,"SELECT id,public_key,revoked,trusted FROM devices WHERE user_id=$1 ORDER BY created_at",a.UserId);
            await using var r=await cmd.ExecuteReaderAsync(); var devices=new List<object>();
            while(await r.ReadAsync()) devices.Add(new {id=r.GetGuid(0),publicKey=Convert.ToBase64String((byte[])r[1]),revoked=r.GetBoolean(2),trustState=r.GetBoolean(3)?"DEVICE_TRUSTED":"DEVICE_PENDING_TRUST"});
            return Results.Ok(devices);
        });
        app.MapDelete("/v1/devices/{id:guid}",async(Guid id,HttpContext ctx,NpgsqlDataSource db)=>
        {
            var a=await Sql.Authenticate(ctx,db); await using var c=await db.OpenConnectionAsync();
            await using var tx=await c.BeginTransactionAsync();
            await using(var accountLock=Sql.Cmd(c,"SELECT id FROM users WHERE id=$1 FOR UPDATE",a.UserId)) await accountLock.ExecuteScalarAsync();
            await using var cmd=Sql.Cmd(c,"UPDATE devices SET revoked=true WHERE id=$1 AND user_id=$2",id,a.UserId);
            if(await cmd.ExecuteNonQueryAsync()!=1) throw new ApiError(404,"DEVICE_NOT_FOUND");
            await tx.CommitAsync(); return Results.NoContent();
        });
    }
    private static async Task<object> NewSession(NpgsqlConnection c,Guid device,Guid family)
    {
        var access=Sql.Token(); var refresh=Sql.Token();
        await using var cmd=Sql.Cmd(c,"INSERT INTO sessions(id,family,device_id,access_hash,refresh_hash,expires_at,refresh_expires_at) VALUES($1,$2,$3,$4,$5,now()+interval '15 minutes',now()+interval '30 days')",Guid.NewGuid(),family,device,Sql.Hash(access),Sql.Hash(refresh));
        await cmd.ExecuteNonQueryAsync();
        await using var state=Sql.Cmd(c,"SELECT trusted FROM devices WHERE id=$1",device);
        var trusted=(bool)(await state.ExecuteScalarAsync())!;
        return new {accessToken=access,refreshToken=refresh,expiresIn=900,deviceId=device,trustState=trusted?"DEVICE_TRUSTED":"DEVICE_PENDING_TRUST"};
    }
}
