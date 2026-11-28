using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Npgsql;

namespace SecureMesh;

public sealed record ChatRequestInput(Guid Id,string Username);
public sealed record KeyPackageInput(byte[] Payload, Guid? InvitationId = null);
public sealed record LeaseInput(Guid InvitationId,Guid RequestId);
public sealed record EstablishInput(Guid Id,Guid InvitationId,Guid LeaseId,byte[] Welcome,byte[] Signature);

public static class MlsDirectory
{
    public static void MapMlsDirectory(this WebApplication app)
    {
        app.MapContactBlocks();
        app.MapPost("/v1/chat-requests",async(ChatRequestInput input,HttpContext ctx,NpgsqlDataSource db)=>
        {
            var actor=await Sql.Authenticate(ctx,db);
            if(input.Id==Guid.Empty || !Regex.IsMatch(input.Username,"^[a-z0-9_]{3,32}$")) throw new ApiError(400,"INVALID_CHAT_REQUEST");
            await using var c=await db.OpenConnectionAsync();await using var tx=await c.BeginTransactionAsync();
            Guid recipient;
            await using(var cmd=Sql.Cmd(c,"SELECT id FROM users WHERE username=$1 AND verified",input.Username))
                recipient=await cmd.ExecuteScalarAsync() is Guid id?id:throw new ApiError(404,"USER_NOT_FOUND");
            if(recipient==actor.UserId) throw new ApiError(400,"SELF_REQUEST_NOT_SUPPORTED");
            // Existing pair quota/block locks must stay in canonical order; validate the session after acquiring them.
            await using(var cmd=Sql.Cmd(c,"SELECT id FROM users WHERE id=ANY($1) ORDER BY id FOR UPDATE",new Guid[]{actor.UserId,recipient}))
                await cmd.ExecuteNonQueryAsync(ctx.RequestAborted);
            await Sql.LockTrustedDeliverySession(c,actor,ctx.RequestAborted);
            await using(var old=Sql.Cmd(c,"SELECT 1 FROM chat_requests WHERE id=$1 AND sender_device=$2 AND recipient_user=$3",input.Id,actor.DeviceId,recipient))
                if(await old.ExecuteScalarAsync() is not null) return Results.Ok(new{id=input.Id});
            await using (var blocked = Sql.Cmd(c, "SELECT 1 FROM contact_blocks WHERE owner_id=$1 AND blocked_id=$2", recipient, actor.UserId))
                if (await blocked.ExecuteScalarAsync(ctx.RequestAborted) is not null)
                    throw new ApiError(404, "USER_NOT_FOUND");
            await using(var pair=Sql.Cmd(c,"""
                SELECT count(*) FROM chat_requests q JOIN devices d ON d.id=q.sender_device
                WHERE d.user_id=$1 AND q.recipient_user=$2 AND q.created_at>now()-interval '1 day'
                """,actor.UserId,recipient))
                if((long)(await pair.ExecuteScalarAsync())!>=5) throw new ApiError(429,"CONTACT_REQUEST_LIMIT");
            await using(var count=Sql.Cmd(c,"SELECT count(*) FROM chat_requests WHERE (sender_device=$1 OR recipient_user=$2) AND expires_at>now()",actor.DeviceId,recipient))
                if((long)(await count.ExecuteScalarAsync())!>=100) throw new ApiError(429,"CHAT_REQUEST_LIMIT");
            await using(var cmd=Sql.Cmd(c,"INSERT INTO chat_requests(id,sender_device,recipient_user) VALUES($1,$2,$3)",input.Id,actor.DeviceId,recipient))
                try {await cmd.ExecuteNonQueryAsync();} catch(PostgresException e) when(e.SqlState=="23505") {throw new ApiError(409,"REQUEST_ID_CONFLICT");}
            await tx.CommitAsync();return Results.Created($"/v1/chat-requests/{input.Id}",new{id=input.Id});
        });
        app.MapGet("/v1/chat-requests",async(HttpContext ctx,NpgsqlDataSource db)=>
        {
            var actor=await Sql.Authenticate(ctx,db);await using var c=await db.OpenConnectionAsync();
            await using var cmd=Sql.Cmd(c,"""
                SELECT q.id,CASE WHEN q.sender_device=$2 THEN target.username ELSE u.username END,q.sender_device,d.public_key,q.recipient_device,receiver.public_key,q.sender_device=$2,
                       EXISTS (SELECT 1 FROM conversation_bootstraps b WHERE b.invitation_id=q.id)
                FROM chat_requests q JOIN devices d ON d.id=q.sender_device JOIN users u ON u.id=d.user_id
                JOIN users target ON target.id=q.recipient_user LEFT JOIN devices receiver ON receiver.id=q.recipient_device
                WHERE (q.recipient_user=$1 OR q.sender_device=$2) AND q.expires_at>now() AND NOT d.revoked AND d.trusted
                ORDER BY q.created_at,q.id LIMIT 100
                """,actor.UserId,actor.DeviceId);
            await using var r=await cmd.ExecuteReaderAsync();var rows=new List<object>();
            while(await r.ReadAsync()) rows.Add(new{id=r.GetGuid(0),username=r.GetString(1),senderDevice=r.GetGuid(2),senderKey=Convert.ToBase64String((byte[])r[3]),recipientDevice=r.IsDBNull(4)?(Guid?)null:r.GetGuid(4),recipientKey=r.IsDBNull(5)?null:Convert.ToBase64String((byte[])r[5]),accepted=!r.IsDBNull(4),outgoing=r.GetBoolean(6),established=r.GetBoolean(7)});
            return Results.Ok(rows);
        });
        app.MapPost("/v1/chat-requests/{id:guid}/dismiss",async(Guid id,HttpContext ctx,NpgsqlDataSource db)=>
        {
            var actor=await Sql.Authenticate(ctx,db);
            await using var c=await db.OpenConnectionAsync(ctx.RequestAborted);
            await using var tx=await c.BeginTransactionAsync(ctx.RequestAborted);
            await Sql.LockTrustedDeliverySession(c,actor,ctx.RequestAborted);
            // Retain the request ID for retry deduplication. An accepted request may
            // already have an MLS lease, so its identity binding must stay intact.
            await using var cmd=Sql.Cmd(c,"""
                UPDATE chat_requests SET expires_at=LEAST(expires_at,now())
                WHERE id=$1 AND (recipient_user=$2 OR sender_device=$3) AND recipient_device IS NULL
                """,id,actor.UserId,actor.DeviceId);
            if(await cmd.ExecuteNonQueryAsync(ctx.RequestAborted)!=1) throw new ApiError(404,"PENDING_REQUEST_NOT_FOUND");
            await tx.CommitAsync(ctx.RequestAborted);
            return Results.NoContent();
        });
        app.MapPost("/v1/chat-requests/{id:guid}/accept",async(Guid id,HttpContext ctx,NpgsqlDataSource db)=>
        {
            var actor=await Sql.Authenticate(ctx,db);await using var c=await db.OpenConnectionAsync(ctx.RequestAborted);
            await using var tx=await c.BeginTransactionAsync(ctx.RequestAborted);
            await Sql.LockTrustedDeliverySession(c,actor,ctx.RequestAborted);
            await using var cmd=Sql.Cmd(c,"""
                UPDATE chat_requests SET recipient_device=$3 WHERE id=$1 AND recipient_user=$2 AND expires_at>now()
                AND (recipient_device IS NULL OR recipient_device=$3)
                """,id,actor.UserId,actor.DeviceId);
            if(await cmd.ExecuteNonQueryAsync(ctx.RequestAborted)!=1) throw new ApiError(404,"CHAT_REQUEST_NOT_FOUND");
            await tx.CommitAsync(ctx.RequestAborted);
            return Results.NoContent();
        });
        app.MapGet("/v1/chat-requests/{id:guid}",async(Guid id,HttpContext ctx,NpgsqlDataSource db)=>
        {
            var actor=await Sql.Authenticate(ctx,db);await using var c=await db.OpenConnectionAsync();
            await using var cmd=Sql.Cmd(c,"""
                SELECT q.sender_device,s.public_key,q.recipient_device,d.public_key
                FROM chat_requests q JOIN devices s ON s.id=q.sender_device LEFT JOIN devices d ON d.id=q.recipient_device
                WHERE q.id=$1 AND (s.user_id=$2 OR q.recipient_user=$2) AND q.expires_at>now() AND NOT s.revoked AND s.trusted
                """,id,actor.UserId);
            await using var r=await cmd.ExecuteReaderAsync();if(!await r.ReadAsync()) throw new ApiError(404,"CHAT_REQUEST_NOT_FOUND");
            return Results.Ok(new{id,senderDevice=r.GetGuid(0),senderKey=Convert.ToBase64String((byte[])r[1]),recipientDevice=r.IsDBNull(2)?(Guid?)null:r.GetGuid(2),recipientKey=r.IsDBNull(3)?null:Convert.ToBase64String((byte[])r[3])});
        });
        app.MapPost("/v1/crypto/keypackages",Publish);
        app.MapPost("/v1/crypto/keypackages/lease",Lease);
        app.MapPost("/v1/conversations/establish",Establish);
        app.MapGet("/v1/conversations",async(HttpContext ctx,NpgsqlDataSource db)=>
        {
            var actor=await Sql.Authenticate(ctx,db);await using var c=await db.OpenConnectionAsync();
            await using var cmd=Sql.Cmd(c,"""
                SELECT c.id,d.id,d.public_key,u.username,u.display_name,p.version FROM conversation_devices own JOIN conversations c ON c.id=own.conversation_id
                JOIN members peer ON peer.conversation_id=c.id
                JOIN devices d ON d.id=peer.device_id JOIN users u ON u.id=d.user_id
                LEFT JOIN profile_photos p ON p.user_id=u.id
                LEFT JOIN conversation_bootstraps b ON b.conversation_id=c.id
                WHERE own.device_id=$1 AND d.user_id<>$2 AND (SELECT count(*) FROM members WHERE conversation_id=c.id)=2
                  AND (b.conversation_id IS NULL OR b.sender_device=$1 OR b.received OR own.join_seq>0)
                ORDER BY c.id LIMIT 100
                """,actor.DeviceId,actor.UserId);
            await using var r=await cmd.ExecuteReaderAsync();var rows=new List<object>();
            while(await r.ReadAsync()) rows.Add(new{id=r.GetGuid(0),peerDevice=r.GetGuid(1),peerKey=Convert.ToBase64String((byte[])r[2]),peerName=r.GetString(3),peerDisplayName=r.IsDBNull(4)?null:r.GetString(4),peerPhotoVersion=r.IsDBNull(5)?(Guid?)null:r.GetGuid(5),mode="E2EE_PRIVATE"});
            return Results.Ok(rows);
        });
        app.MapGet("/v1/crypto/welcomes",async(HttpContext ctx,NpgsqlDataSource db)=>
        {
            var actor=await Sql.Authenticate(ctx,db);await using var c=await db.OpenConnectionAsync();
            await using var cmd=Sql.Cmd(c,"""
                SELECT b.conversation_id,b.invitation_id,b.lease_id,b.sender_device,b.reference,b.welcome,b.signature,d.public_key
                FROM conversation_bootstraps b JOIN devices d ON d.id=b.sender_device
                WHERE b.recipient_device=$1 AND NOT b.received ORDER BY b.created_at,b.conversation_id LIMIT 20
                """,actor.DeviceId);
            await using var r=await cmd.ExecuteReaderAsync();var rows=new List<object>();var bytes=0;
            while(await r.ReadAsync())
            {
                var welcome=(byte[])r[5];
                if(bytes+welcome.Length>65536) break;
                bytes+=welcome.Length;
                rows.Add(new {group=r.GetGuid(0),invitation=r.GetGuid(1),lease=r.GetGuid(2),sender=r.GetGuid(3),recipient=actor.DeviceId,reference=Convert.ToBase64String((byte[])r[4]),welcome=Convert.ToBase64String(welcome),signature=Convert.ToBase64String((byte[])r[6]),senderKey=Convert.ToBase64String((byte[])r[7])});
            }
            return Results.Ok(rows);
        });
        app.MapPost("/v1/crypto/welcomes/{id:guid}/ack",async(Guid id,HttpContext ctx,NpgsqlDataSource db)=>
        {
            var actor=await Sql.Authenticate(ctx,db);await using var c=await db.OpenConnectionAsync(ctx.RequestAborted);
            await using var tx=await c.BeginTransactionAsync(ctx.RequestAborted);
            await Sql.LockTrustedDeliverySession(c,actor,ctx.RequestAborted);
            await using var cmd=Sql.Cmd(c,"UPDATE conversation_bootstraps SET received=true WHERE conversation_id=$1 AND recipient_device=$2",id,actor.DeviceId);
            if(await cmd.ExecuteNonQueryAsync(ctx.RequestAborted)!=1) throw new ApiError(404,"WELCOME_NOT_FOUND");
            await tx.CommitAsync(ctx.RequestAborted);
            return Results.NoContent();
        });
    }

    private static async Task<IResult> Publish(KeyPackageInput input,HttpContext ctx,NpgsqlDataSource db,PublicKeyPackageValidator validator)
    {
        var actor = await Sql.Authenticate(ctx, db);
        await using var c = await db.OpenConnectionAsync(ctx.RequestAborted);
        byte[] key;
        await using (var cmd = Sql.Cmd(c, "SELECT public_key FROM devices WHERE id=$1 AND trusted AND NOT revoked", actor.DeviceId))
            key = await cmd.ExecuteScalarAsync(ctx.RequestAborted) as byte[] ?? throw new ApiError(403, "DEVICE_NOT_TRUSTED");
        byte[]? reference = input.InvitationId is null
            ? await validator.Validate(input.Payload, actor.DeviceId, key, ctx.RequestAborted) : null;
        await using var tx = await c.BeginTransactionAsync(ctx.RequestAborted);
        await Sql.LockTrustedDeliverySession(c,actor,ctx.RequestAborted);
        if (input.InvitationId is Guid invitation)
        {
            // Serialize publication with leasing and establishment for this invitation.
            await using var request = Sql.Cmd(c, """
                SELECT 1 FROM chat_requests
                WHERE id=$1 AND recipient_user=$2 AND (recipient_device IS NULL OR recipient_device=$3)
                  AND expires_at>statement_timestamp()
                FOR UPDATE
                """, invitation, actor.UserId, actor.DeviceId);
            if (await request.ExecuteScalarAsync(ctx.RequestAborted) is null)
                throw new ApiError(404, "CHAT_REQUEST_NOT_FOUND");
        }
        await using (var cmd = Sql.Cmd(c, "SELECT id FROM devices WHERE id=$1 AND trusted AND NOT revoked FOR UPDATE", actor.DeviceId))
            if (await cmd.ExecuteScalarAsync(ctx.RequestAborted) is null)
                throw new ApiError(403, "DEVICE_NOT_TRUSTED");

        if (input.InvitationId is Guid offeredFor)
        {
            await using (var lease = Sql.Cmd(c, """
                SELECT reference, consumed_by IS NOT NULL OR lease_expires_at>statement_timestamp()
                FROM key_packages WHERE invitation_id=$1 AND device_id=$2
                """, offeredFor, actor.DeviceId))
            await using (var row = await lease.ExecuteReaderAsync(ctx.RequestAborted))
            {
                if (await row.ReadAsync(ctx.RequestAborted))
                {
                    if (!row.GetBoolean(1)) throw new ApiError(409, "KEYPACKAGE_LEASE_EXPIRED");
                    return Results.Ok(new { reference = Convert.ToBase64String(row.GetFieldValue<byte[]>(0)) });
                }
            }

            // A saved usable offer makes a lost publication response safe to retry.
            await using var existing = Sql.Cmd(c, """
                SELECT reference FROM key_packages
                WHERE offered_for=$1 AND device_id=$2 AND lease_id IS NULL AND expires_at>statement_timestamp()
                LIMIT 1
                """, offeredFor, actor.DeviceId);
            if (await existing.ExecuteScalarAsync(ctx.RequestAborted) is byte[] available)
                return Results.Ok(new { reference = Convert.ToBase64String(available) });
        }

        reference ??= await validator.Validate(input.Payload, actor.DeviceId, key, ctx.RequestAborted);
        await using (var old = Sql.Cmd(c, "SELECT 1 FROM key_packages WHERE reference=$1 AND device_id=$2 AND payload=$3",
            reference, actor.DeviceId, input.Payload))
        {
            if (await old.ExecuteScalarAsync(ctx.RequestAborted) is not null)
            {
                if (input.InvitationId is not null) throw new ApiError(409, "KEYPACKAGE_UNAVAILABLE");
                return Results.Ok(new { reference = Convert.ToBase64String(reference) });
            }
        }
        await using (var count = Sql.Cmd(c, "SELECT count(*) FROM key_packages WHERE device_id=$1 AND lease_id IS NULL AND expires_at>now()", actor.DeviceId))
            if ((long)(await count.ExecuteScalarAsync(ctx.RequestAborted))! >= 64)
                throw new ApiError(429, "KEYPACKAGE_LIMIT");

        await using var insert = Sql.Cmd(c, "INSERT INTO key_packages(reference,device_id,payload,offered_for) VALUES($1,$2,$3,NULLIF($4,'00000000-0000-0000-0000-000000000000'::uuid))",
            reference, actor.DeviceId, input.Payload, input.InvitationId ?? Guid.Empty);
        await insert.ExecuteNonQueryAsync(ctx.RequestAborted);
        await tx.CommitAsync(ctx.RequestAborted);
        return Results.Created("/v1/crypto/keypackages", new { reference = Convert.ToBase64String(reference) });
    }

    private static async Task<IResult> Lease(LeaseInput input,HttpContext ctx,NpgsqlDataSource db,PublicKeyPackageValidator validator)
    {
        var actor=await Sql.Authenticate(ctx,db);
        if(input.RequestId==Guid.Empty) throw new ApiError(400,"INVALID_LEASE_ID");
        await using var c=await db.OpenConnectionAsync(ctx.RequestAborted);await using var tx=await c.BeginTransactionAsync(ctx.RequestAborted);
        await Sql.LockTrustedDeliverySession(c,actor,ctx.RequestAborted);
        Guid target;byte[] key;
        await using(var cmd=Sql.Cmd(c,"""
            SELECT d.id,d.public_key FROM chat_requests q JOIN devices d ON d.id=q.recipient_device
            WHERE q.id=$1 AND q.sender_device=$2 AND q.expires_at>now() AND d.trusted AND NOT d.revoked FOR UPDATE OF q
            """,input.InvitationId,actor.DeviceId))
        await using(var r=await cmd.ExecuteReaderAsync())
        {if(!await r.ReadAsync()) throw new ApiError(403,"ACCEPTED_INVITATION_REQUIRED");target=r.GetGuid(0);key=(byte[])r[1];}
        byte[] reference,payload;bool existing=false;
        await using(var cmd=Sql.Cmd(c,"""
            SELECT reference,payload,lease_id,lease_expires_at>now() FROM key_packages WHERE invitation_id=$1 FOR UPDATE
            """,input.InvitationId))
        await using(var r=await cmd.ExecuteReaderAsync())
        {
            if(await r.ReadAsync())
            {
                if(r.GetGuid(2)!=input.RequestId || !r.GetBoolean(3)) throw new ApiError(409,"KEYPACKAGE_ALREADY_LEASED");
                reference=(byte[])r[0];payload=(byte[])r[1];existing=true;
            } else {reference=[];payload=[];}
        }
        if(!existing)
        {
            await using(var cmd=Sql.Cmd(c,"""
                SELECT reference,payload FROM key_packages
                WHERE device_id=$1 AND lease_id IS NULL AND expires_at>now()
                  AND (offered_for=$2 OR offered_for IS NULL)
                ORDER BY (offered_for IS NULL),expires_at,reference LIMIT 1 FOR UPDATE SKIP LOCKED
                """,target,input.InvitationId))
            await using(var r=await cmd.ExecuteReaderAsync())
            {if(!await r.ReadAsync()) throw new ApiError(409,"NO_FRESH_KEYPACKAGE");reference=(byte[])r[0];payload=(byte[])r[1];}
        }
        var validated=await validator.Validate(payload,target,key,ctx.RequestAborted);
        if(!CryptographicOperations.FixedTimeEquals(reference,validated)) throw new ApiError(409,"KEYPACKAGE_CHANGED");
        if(!existing)
        {
            await using var cmd=Sql.Cmd(c,"UPDATE key_packages SET lease_id=$2,leased_by=$3,invitation_id=$4,lease_expires_at=least(expires_at,now()+interval '10 minutes') WHERE reference=$1",reference,input.RequestId,actor.DeviceId,input.InvitationId);
            try {await cmd.ExecuteNonQueryAsync();} catch(PostgresException e) when(e.SqlState=="23505") {throw new ApiError(409,"LEASE_ID_CONFLICT");}
        }
        await tx.CommitAsync();return Results.Ok(new{lease=input.RequestId,recipient=target,publicKey=Convert.ToBase64String(key),reference=Convert.ToBase64String(reference),keypackage=Convert.ToBase64String(payload)});
    }

    private static byte[] EstablishPayload(EstablishInput input,Guid sender,Guid recipient,byte[] reference) => Encoding.UTF8.GetBytes(
        $"SecureMesh/conversation-establish/v1\n{input.Id:D}\n{input.InvitationId:D}\n{input.LeaseId:D}\n{sender:D}\n{recipient:D}\n{Convert.ToBase64String(reference)}\n{Convert.ToBase64String(SHA256.HashData(input.Welcome))}\n1");

    private static async Task<IResult> Establish(EstablishInput input,HttpContext ctx,NpgsqlDataSource db)
    {
        var actor=await Sql.Authenticate(ctx,db);
        if(input.Id==Guid.Empty || input.Welcome.Length is <1 or >32768 || input.Signature.Length!=64) throw new ApiError(400,"INVALID_WELCOME");
        await using var c=await db.OpenConnectionAsync(ctx.RequestAborted);await using var tx=await c.BeginTransactionAsync(ctx.RequestAborted);
        await Sql.LockTrustedDeliverySession(c,actor,ctx.RequestAborted);
        var committed=await ExistingBootstrap(c,input,actor);
        if(committed is not null) return committed;
        Guid recipient;byte[] reference,key;
        await using(var cmd=Sql.Cmd(c,"""
            SELECT k.device_id,k.reference,s.public_key FROM key_packages k
            JOIN chat_requests q ON q.id=k.invitation_id JOIN devices d ON d.id=k.device_id JOIN devices s ON s.id=k.leased_by
            WHERE k.lease_id=$1 AND q.id=$2 AND k.leased_by=$3 AND q.sender_device=$3 AND q.recipient_device=k.device_id
              AND k.lease_expires_at>now() AND q.expires_at>now() AND d.trusted AND NOT d.revoked AND s.trusted AND NOT s.revoked FOR UPDATE OF q,k
            """,input.LeaseId,input.InvitationId,actor.DeviceId))
        await using(var r=await cmd.ExecuteReaderAsync())
        {if(!await r.ReadAsync()) throw new ApiError(403,"VALID_LEASE_REQUIRED");recipient=r.GetGuid(0);reference=(byte[])r[1];key=(byte[])r[2];}
        if(!DeviceTrust.Verify(key,EstablishPayload(input,actor.DeviceId,recipient,reference),input.Signature)) throw new ApiError(403,"INVALID_WELCOME_SIGNATURE");
        committed=await ExistingBootstrap(c,input,actor);
        if(committed is not null) return committed;
        await using(var cmd=Sql.Cmd(c,"INSERT INTO conversations(id,epoch) VALUES($1,1)",input.Id))
            try {await cmd.ExecuteNonQueryAsync();} catch(PostgresException e) when(e.SqlState=="23505") {throw new ApiError(409,"CONVERSATION_EXISTS");}
        foreach(var device in new[]{actor.DeviceId,recipient})
        {await using var cmd=Sql.Cmd(c,"INSERT INTO members VALUES($1,$2)",input.Id,device);await cmd.ExecuteNonQueryAsync();}
        await using(var cmd=Sql.Cmd(c,"INSERT INTO conversation_bootstraps(conversation_id,invitation_id,lease_id,sender_device,recipient_device,reference,welcome,signature) VALUES($1,$2,$3,$4,$5,$6,$7,$8)",input.Id,input.InvitationId,input.LeaseId,actor.DeviceId,recipient,reference,input.Welcome,input.Signature)) await cmd.ExecuteNonQueryAsync();
        await using(var cmd=Sql.Cmd(c,"UPDATE key_packages SET consumed_by=$2 WHERE lease_id=$1",input.LeaseId,input.Id)) await cmd.ExecuteNonQueryAsync();
        await tx.CommitAsync();return Results.Created($"/v1/conversations/{input.Id}",new{id=input.Id,alreadyCommitted=false});
    }

    private static async Task<IResult?> ExistingBootstrap(NpgsqlConnection c,EstablishInput input,Actor actor)
    {
        await using var cmd=Sql.Cmd(c,"SELECT conversation_id,lease_id,welcome,signature FROM conversation_bootstraps WHERE invitation_id=$1 AND sender_device=$2",input.InvitationId,actor.DeviceId);
        await using var r=await cmd.ExecuteReaderAsync();
        if(!await r.ReadAsync()) return null;
        if(r.GetGuid(0)!=input.Id || r.GetGuid(1)!=input.LeaseId || !CryptographicOperations.FixedTimeEquals((byte[])r[2],input.Welcome) || !CryptographicOperations.FixedTimeEquals((byte[])r[3],input.Signature)) throw new ApiError(409,"BOOTSTRAP_CONFLICT");
        return Results.Ok(new{id=input.Id,alreadyCommitted=true});
    }
}
