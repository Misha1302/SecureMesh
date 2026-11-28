using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Npgsql;

namespace SecureMesh;

public sealed record RosterTransition(Guid Group, Guid Id, Guid Device, Guid Committer, string Action,
    long Epoch, long Seq, byte[] Commit, byte[] Welcome, byte[] Signature, byte[] Digest);

public static class Roster
{
    public static void MapRoster(this WebApplication app)
    {
        app.MapPost("/v1/roster/transitions", Commit);
        app.MapPost("/v1/conversations/{group:guid}/roster-packages/{device:guid}/{id:guid}", Lease);
        app.MapGet("/v1/roster/welcomes", async (HttpContext ctx,NpgsqlDataSource db) =>
        {
            var a=await Sql.Authenticate(ctx,db);
            await using var c=await db.OpenConnectionAsync();
            await using var cmd=Sql.Cmd(c,"""
                SELECT r.transition::text FROM conversation_links l JOIN roster_changes r
                  ON r.conversation_id=l.conversation_id AND r.seq=l.join_seq
                LEFT JOIN cursors cur ON cur.conversation_id=l.conversation_id AND cur.device_id=l.device_id
                WHERE l.device_id=$1 AND COALESCE(cur.seq,0)<l.join_seq
                ORDER BY l.conversation_id LIMIT 8
                """,a.DeviceId);
            await using var reader=await cmd.ExecuteReaderAsync();
            var rows=new List<JsonElement>();
            while(await reader.ReadAsync()) rows.Add(JsonSerializer.Deserialize<JsonElement>(reader.GetString(0)));
            return Results.Ok(rows);
        });
        app.MapGet("/v1/conversations/{group:guid}/roster/{seq:long}", async(Guid group,long seq,HttpContext ctx,NpgsqlDataSource db)=>
        {
            var a=await Sql.Authenticate(ctx,db);
            await using var c=await db.OpenConnectionAsync();
            await using var cmd=Sql.Cmd(c,"""
                SELECT r.transition::text FROM roster_changes r JOIN conversation_devices m
                  ON m.conversation_id=r.conversation_id AND m.device_id=$3 AND m.join_seq<=r.seq
                JOIN devices d ON d.id=m.device_id AND d.trusted AND NOT d.revoked
                WHERE r.conversation_id=$1 AND r.seq=$2
                """,group,seq,a.DeviceId);
            var json=await cmd.ExecuteScalarAsync() as string ?? throw new ApiError(404,"ROSTER_CHANGE_NOT_FOUND");
            await using var cert=Sql.Cmd(c,"""
                SELECT e.user_id,e.payload,e.candidate_signature,e.grant_signature,e.activation_signature
                FROM roster_changes r JOIN device_enrollments e ON e.device_id=r.device_id AND e.approver_id=r.committer
                WHERE r.conversation_id=$1 AND r.seq=$2 AND r.transition->>'action'='add' AND e.activated_at IS NOT NULL
                ORDER BY e.activated_at DESC LIMIT 1
                """,group,seq);
            await using var reader=await cert.ExecuteReaderAsync();
            object? certificate=await reader.ReadAsync()? new{account=reader.GetGuid(0),payload=(byte[])reader[1],candidate_signature=(byte[])reader[2],grant_signature=(byte[])reader[3],activation_signature=(byte[])reader[4]}:null;
            return Results.Ok(new{transition=JsonSerializer.Deserialize<JsonElement>(json),certificate});
        });
    }

    private static async Task<IResult> Lease(Guid group,Guid device,Guid id,HttpContext ctx,NpgsqlDataSource db)
    {
        var a=await Sql.Authenticate(ctx,db);
        if(id==Guid.Empty) throw new ApiError(400,"INVALID_LEASE_ID");
        await using var c=await db.OpenConnectionAsync();
        await using var tx=await c.BeginTransactionAsync();
        await using(var check=Sql.Cmd(c,"""
            SELECT d.id FROM devices d JOIN device_enrollments e ON e.device_id=d.id
              JOIN members m ON m.device_id=e.approver_id JOIN devices s ON s.id=m.device_id
            WHERE m.conversation_id=$1 AND s.id=$2 AND d.id=$3 AND d.user_id=s.user_id
              AND d.trusted AND NOT d.revoked AND s.trusted AND NOT s.revoked AND e.activated_at IS NOT NULL
            FOR UPDATE OF d
            """,group,a.DeviceId,device))
            if(await check.ExecuteScalarAsync() is null) throw new ApiError(403,"ACTIVATED_ENROLLMENT_REQUIRED");
        await using(var old=Sql.Cmd(c,"SELECT payload FROM key_packages WHERE roster_group=$1 AND lease_id=$2 AND device_id=$3 AND leased_by=$4 AND lease_expires_at>now()",group,id,device,a.DeviceId))
            if(await old.ExecuteScalarAsync() is byte[] previous) return Results.Ok(new{keypackage=previous});
        await using(var count=Sql.Cmd(c,"SELECT count(*) FROM key_packages WHERE leased_by=$1 AND roster_group IS NOT NULL AND lease_expires_at>now()",a.DeviceId))
            if((long)(await count.ExecuteScalarAsync())!>=16) throw new ApiError(429,"ROSTER_LEASE_LIMIT");
        await using var cmd=Sql.Cmd(c,"""
            UPDATE key_packages SET roster_group=$1,lease_id=$2,leased_by=$3,lease_expires_at=least(expires_at,now()+interval '5 minutes')
              WHERE reference=(SELECT reference FROM key_packages WHERE device_id=$4 AND lease_id IS NULL AND offered_for IS NULL AND expires_at>now()
              ORDER BY expires_at,reference LIMIT 1 FOR UPDATE SKIP LOCKED) RETURNING payload
            """,group,id,a.DeviceId,device);
        byte[] package;
        try { package=await cmd.ExecuteScalarAsync() as byte[] ?? throw new ApiError(409,"NO_FRESH_KEYPACKAGE"); }
        catch(PostgresException e) when(e.SqlState=="23505") {throw new ApiError(409,"LEASE_ID_CONFLICT");}
        await tx.CommitAsync();
        return Results.Ok(new{keypackage=package});
    }

    private static readonly JsonSerializerOptions Json=new(JsonSerializerDefaults.Web);
    private static string Hash(byte[] bytes)=>Convert.ToBase64String(SHA256.HashData(bytes));

    private static async Task<IResult> Commit(RosterTransition t,HttpContext ctx,NpgsqlDataSource db)
    {
        var a=await Sql.Authenticate(ctx,db);
        if(t.Committer!=a.DeviceId || t.Device==a.DeviceId || t.Device==Guid.Empty || t.Group==Guid.Empty ||
            t.Id==Guid.Empty || t.Epoch<1 || t.Epoch==long.MaxValue || t.Seq<1 || t.Seq==long.MaxValue ||
            t.Action is not ("add" or "remove") || t.Commit is not { Length: >0 and <=32768 } ||
            t.Welcome is not { Length: <=32768 } || (t.Action=="add")!=(t.Welcome.Length>0) ||
            t.Signature is not {Length:64} || t.Digest is not {Length:32})
            throw new ApiError(400,"INVALID_ROSTER_CHANGE");
        await using var c=await db.OpenConnectionAsync();
        await using var tx=await c.BeginTransactionAsync();
        long epoch,last;
        await using(var cmd=Sql.Cmd(c,"""
            SELECT epoch,next_seq FROM conversations c WHERE id=$1
              AND COALESCE((to_jsonb(c)->>'account_removed')::boolean,false)=false FOR UPDATE
            """,t.Group))
        await using(var r=await cmd.ExecuteReaderAsync())
        {
            if(!await r.ReadAsync()) throw new ApiError(403,"MEMBERSHIP_REQUIRED");
            epoch=r.GetInt64(0);last=r.GetInt64(1);
        }
        await Sql.DeliveryFloor(c,t.Group,a.DeviceId);
        // Only the original account device can register or remove its own additional leaf.
        byte[] candidateKey,signerKey;
        bool eligible;
        await using(var cmd=Sql.Cmd(c,"""
            SELECT d.public_key,s.public_key,d.trusted AND NOT d.revoked
            FROM devices d JOIN devices s ON s.user_id=d.user_id JOIN members m ON m.device_id=s.id
            WHERE d.id=$1 AND s.id=$2 AND m.conversation_id=$3 AND s.trusted AND NOT s.revoked
            FOR SHARE OF s,d
            """,t.Device,a.DeviceId,t.Group))
        await using(var r=await cmd.ExecuteReaderAsync())
        {
            if(!await r.ReadAsync()) throw new ApiError(403,"DEVICE_OWNER_REQUIRED");
            candidateKey=(byte[])r[0];signerKey=(byte[])r[1];eligible=r.GetBoolean(2);
        }
        var transcript=Encoding.UTF8.GetBytes(FormattableString.Invariant(
            $"SecureMesh/roster-transition/v2\n{t.Group:D}\n{t.Id:D}\n{a.DeviceId:D}\n{t.Device:D}\n{t.Action}\n{t.Epoch}\n{t.Seq}\n{Hash(candidateKey)}\n{Hash(t.Commit)}\n{Hash(t.Welcome)}"));
        if(!CryptographicOperations.FixedTimeEquals(SHA256.HashData(transcript),t.Digest) ||
            !DeviceTrust.Verify(signerKey,transcript,t.Signature)) throw new ApiError(403,"INVALID_ROSTER_SIGNATURE");
        await using(var cmd=Sql.Cmd(c,"SELECT digest FROM roster_changes WHERE conversation_id=$1 AND id=$2",t.Group,t.Id))
        {
            if(await cmd.ExecuteScalarAsync() is byte[] saved)
            {
                if(!CryptographicOperations.FixedTimeEquals(saved,t.Digest)) throw new ApiError(409,"IDEMPOTENCY_CONFLICT");
                await tx.CommitAsync();return Results.Ok(new{durable=true,seq=t.Seq,digest=t.Digest,alreadySaved=true});
            }
        }
        await ConversationMessageBlocks.RequireOpen(c,t.Group,ctx.RequestAborted);
        if(epoch!=t.Epoch || last!=t.Seq-1) throw new ApiError(409,"ROSTER_POSITION_CONFLICT");
        if(t.Action=="add")
        {
            await using(var check=Sql.Cmd(c,"SELECT 1 FROM key_packages WHERE roster_group=$1 AND lease_id=$2 AND device_id=$3 AND leased_by=$4 AND lease_expires_at>now()",t.Group,t.Id,t.Device,a.DeviceId))
                if(await check.ExecuteScalarAsync() is null) throw new ApiError(409,"ROSTER_LEASE_REQUIRED");
            if(!eligible) throw new ApiError(403,"DEVICE_NOT_TRUSTED");
            await using(var check=Sql.Cmd(c,"""
                SELECT 1 FROM device_enrollments
                WHERE device_id=$1 AND approver_id=$2 AND activated_at IS NOT NULL
                  AND user_id=$3 AND activation_signature IS NOT NULL
                """,t.Device,a.DeviceId,a.UserId))
                if(await check.ExecuteScalarAsync() is null) throw new ApiError(403,"ACTIVATED_ENROLLMENT_REQUIRED");
            // The current client starts one lineage per installation and conversation.
            // An evicted device must use a fresh installation before receiving a new Welcome.
            await using(var check=Sql.Cmd(c,"""
                SELECT 1 FROM conversation_devices WHERE conversation_id=$1 AND device_id=$2
                UNION ALL SELECT 1 FROM roster_changes WHERE conversation_id=$1 AND device_id=$2
                LIMIT 1
                """,t.Group,t.Device))
                if(await check.ExecuteScalarAsync() is not null) throw new ApiError(409,"DEVICE_ALREADY_MEMBER");
            await using(var check=Sql.Cmd(c,"SELECT count(*) FROM conversation_links WHERE conversation_id=$1",t.Group))
                if((long)(await check.ExecuteScalarAsync())!>=8) throw new ApiError(429,"ROSTER_LIMIT");
            await using var add=Sql.Cmd(c,"INSERT INTO conversation_links VALUES($1,$2,$3)",t.Group,t.Device,t.Seq);
            await add.ExecuteNonQueryAsync();
        }
        else
        {
            await using var remove=Sql.Cmd(c,"DELETE FROM conversation_links WHERE conversation_id=$1 AND device_id=$2",t.Group,t.Device);
            if(await remove.ExecuteNonQueryAsync()!=1) throw new ApiError(409,"LINK_NOT_FOUND");
        }
        await using(var members=Sql.Cmd(c,"""
            SELECT d.trusted AND NOT d.revoked FROM conversation_devices m JOIN devices d ON d.id=m.device_id
            WHERE m.conversation_id=$1 ORDER BY d.id FOR SHARE OF d
            """,t.Group))
        await using(var rows=await members.ExecuteReaderAsync())
            while(await rows.ReadAsync())
                if(!rows.GetBoolean(0) && t.Action=="add") throw new ApiError(409,"MLS_ROSTER_REKEY_REQUIRED");
        await using(var cmd=Sql.Cmd(c,"INSERT INTO roster_changes VALUES($1,$2,$3,$4,$5,$6,$7::jsonb)",t.Group,t.Id,a.DeviceId,t.Device,t.Seq,t.Digest,JsonSerializer.Serialize(t,Json)))
            await cmd.ExecuteNonQueryAsync();
        var message=Guid.NewGuid();
        await using(var cmd=Sql.Cmd(c,"""
            INSERT INTO messages(id,conversation_id,seq,device_id,client_id,ciphertext,digest,epoch,kind)
            VALUES($1,$2,$3,$4,$5,$6,$7,$8,3) ON CONFLICT DO NOTHING
            """,message,t.Group,t.Seq,a.DeviceId,t.Id,t.Commit,SHA256.HashData(t.Commit),epoch))
            if(await cmd.ExecuteNonQueryAsync()!=1) throw new ApiError(409,"IDEMPOTENCY_CONFLICT");
        await using(var cmd=Sql.Cmd(c,"INSERT INTO outbox(message_id) VALUES($1)",message)) await cmd.ExecuteNonQueryAsync();
        await using(var cmd=Sql.Cmd(c,"UPDATE conversations SET next_seq=$2,epoch=$3 WHERE id=$1",t.Group,t.Seq,epoch+1)) await cmd.ExecuteNonQueryAsync();
        await tx.CommitAsync();
        return Results.Ok(new{durable=true,seq=t.Seq,digest=t.Digest,alreadySaved=false});
    }
}
