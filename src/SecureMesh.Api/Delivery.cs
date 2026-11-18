using System.Globalization;
using System.Security.Cryptography;
using Microsoft.AspNetCore.DataProtection;
using Npgsql;

namespace SecureMesh;

public sealed record ConversationRequest(Guid Id, Guid[] DeviceIds, long InitialEpoch = 0);
public sealed record SendRequest(Guid ConversationId, Guid ClientMessageId, long MlsEpoch, int EnvelopeKind, byte[] Ciphertext);
public sealed record Saved(Guid ServerMessageId, long ServerSequence, bool AlreadyCommitted, bool Durable = true);
public sealed record Message(Guid ConversationId, Guid ClientMessageId, Guid SenderDeviceId, long MlsEpoch, int EnvelopeKind, byte[] Ciphertext, long ServerSequence, Guid ServerMessageId);
public sealed record Page(Guid ConversationId, List<Message> Messages, string NextCursor, bool HasMore);
public sealed record ProcessedAckRequest(Guid ConversationId, long Sequence);

public sealed class Delivery(NpgsqlDataSource db, IDataProtectionProvider protection)
{
    private readonly IDataProtector cursorProtector=protection.CreateProtector("SecureMesh.device-conversation-cursor.v1");
    public async Task<Saved> Send(Actor actor, SendRequest input, CancellationToken ct=default)
    {
        if(input.ConversationId==Guid.Empty || input.ClientMessageId==Guid.Empty || input.MlsEpoch<0 || input.EnvelopeKind is <1 or >4 || input.Ciphertext.Length is <1 or >32768)
            throw new ApiError(400,"INVALID_ENVELOPE");
        var digest=SHA256.HashData(input.Ciphertext);
        await using var c=await db.OpenConnectionAsync(ct);
        await using var tx=await c.BeginTransactionAsync(ct);
        long epoch,seq;
        // One conversation row serializes sequence allocation and MLS epoch compare-and-swap.
        await using(var cmd=Sql.Cmd(c,"SELECT epoch,next_seq FROM conversations WHERE id=$1 FOR UPDATE",input.ConversationId))
        await using(var r=await cmd.ExecuteReaderAsync(ct))
        {
            if(!await r.ReadAsync(ct)) throw new ApiError(403,"MEMBERSHIP_REQUIRED");
            epoch=r.GetInt64(0); seq=r.GetInt64(1);
        }
        await Sql.RequireMember(c,input.ConversationId,actor.DeviceId);
        Saved? existing=null;
        await using(var cmd=Sql.Cmd(c,"SELECT id,seq,digest,epoch,kind FROM messages WHERE conversation_id=$1 AND device_id=$2 AND client_id=$3",input.ConversationId,actor.DeviceId,input.ClientMessageId))
        await using(var r=await cmd.ExecuteReaderAsync(ct))
        {
            if(await r.ReadAsync(ct))
            {
                if(!CryptographicOperations.FixedTimeEquals((byte[])r[2],digest) || r.GetInt64(3)!=input.MlsEpoch || r.GetInt32(4)!=input.EnvelopeKind)
                    throw new ApiError(409,"IDEMPOTENCY_CONFLICT");
                existing=new Saved(r.GetGuid(0),r.GetInt64(1),true);
            }
        }
        if(existing is not null) {await tx.CommitAsync(ct); return existing;}
        if(input.MlsEpoch!=epoch) throw new ApiError(409,"MLS_EPOCH_CONFLICT");
        seq=checked(seq+1);
        var id=Guid.NewGuid();
        await using(var cmd=Sql.Cmd(c,"INSERT INTO messages(id,conversation_id,seq,device_id,client_id,ciphertext,digest,epoch,kind) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)",id,input.ConversationId,seq,actor.DeviceId,input.ClientMessageId,input.Ciphertext,digest,input.MlsEpoch,input.EnvelopeKind))
            await cmd.ExecuteNonQueryAsync(ct);
        await using(var cmd=Sql.Cmd(c,"INSERT INTO outbox(message_id) VALUES($1)",id)) await cmd.ExecuteNonQueryAsync(ct);
        await using(var cmd=Sql.Cmd(c,"UPDATE conversations SET next_seq=$2,epoch=$3 WHERE id=$1",input.ConversationId,seq,input.EnvelopeKind==3?checked(epoch+1):epoch))
            await cmd.ExecuteNonQueryAsync(ct);
        // The returned durable status cannot be constructed before the actual commit succeeds.
        await tx.CommitAsync(ct);
        return new Saved(id,seq,false);
    }
    public async Task<Page> Sync(Actor actor,Guid conversation,string? cursor,int limit,CancellationToken ct=default)
    {
        if(limit is <1 or >100) throw new ApiError(400,"INVALID_LIMIT");
        long after=0;
        if(!string.IsNullOrEmpty(cursor))
        {
            string value;
            try {value=cursorProtector.Unprotect(cursor);}
            catch(CryptographicException) {throw new ApiError(400,"INVALID_CURSOR");}
            var parts=value.Split('/');
            if(parts.Length!=3 || parts[0]!=actor.DeviceId.ToString("D") || parts[1]!=conversation.ToString("D") || !long.TryParse(parts[2],out after) || after<0) throw new ApiError(400,"INVALID_CURSOR");
        }
        await using var c=await db.OpenConnectionAsync(ct);
        await Sql.RequireMember(c,conversation,actor.DeviceId);
        await using var cmd=Sql.Cmd(c,"SELECT client_id,device_id,epoch,kind,ciphertext,seq,id FROM messages WHERE conversation_id=$1 AND seq>$2 ORDER BY seq LIMIT $3",conversation,after,limit+1);
        await using var r=await cmd.ExecuteReaderAsync(ct);
        var messages=new List<Message>(); var total=0; bool more=false;
        while(await r.ReadAsync(ct))
        {
            var ciphertext=(byte[])r[4];
            if(messages.Count==limit || total+ciphertext.Length>65536) {more=true;break;}
            messages.Add(new Message(conversation,r.GetGuid(0),r.GetGuid(1),r.GetInt64(2),r.GetInt32(3),ciphertext,r.GetInt64(5),r.GetGuid(6)));
            total+=ciphertext.Length;
        }
        var last=messages.Count==0?after:messages[^1].ServerSequence;
        var next=cursorProtector.Protect($"{actor.DeviceId:D}/{conversation:D}/{last.ToString(CultureInfo.InvariantCulture)}");
        return new Page(conversation,messages,next,more);
    }
    public async Task Ack(Actor actor,ProcessedAckRequest input)
    {
        await using var c=await db.OpenConnectionAsync(); await using var tx=await c.BeginTransactionAsync();
        await Sql.RequireMember(c,input.ConversationId,actor.DeviceId);
        await using(var cmd=Sql.Cmd(c,"SELECT next_seq FROM conversations WHERE id=$1",input.ConversationId))
        {var max=(long)(await cmd.ExecuteScalarAsync())!; if(input.Sequence<0 || input.Sequence>max) throw new ApiError(400,"INVALID_RECEIPT");}
        await using(var cmd=Sql.Cmd(c,"INSERT INTO cursors VALUES($1,$2,$3) ON CONFLICT(conversation_id,device_id) DO UPDATE SET seq=greatest(cursors.seq,excluded.seq)",input.ConversationId,actor.DeviceId,input.Sequence)) await cmd.ExecuteNonQueryAsync();
        await tx.CommitAsync();
    }
    public static void MapDelivery(WebApplication app)
    {
        app.MapPost("/v1/conversations",async(ConversationRequest input,HttpContext ctx,NpgsqlDataSource db)=>
        {
            var a=await Sql.Authenticate(ctx,db);
            if(input.Id==Guid.Empty || input.InitialEpoch<0 || input.DeviceIds.Length is <2 or >100 || !input.DeviceIds.Contains(a.DeviceId) || input.DeviceIds.Distinct().Count()!=input.DeviceIds.Length) throw new ApiError(400,"INVALID_MEMBERS");
            await using var c=await db.OpenConnectionAsync(); await using var tx=await c.BeginTransactionAsync();
            await using(var cmd=Sql.Cmd(c,"INSERT INTO conversations(id,epoch) VALUES($1,$2)",input.Id,input.InitialEpoch)) await cmd.ExecuteNonQueryAsync();
            foreach(var device in input.DeviceIds)
            {
                await using var cmd=Sql.Cmd(c,"INSERT INTO members SELECT $1,id FROM devices WHERE id=$2 AND NOT revoked",input.Id,device);
                if(await cmd.ExecuteNonQueryAsync()!=1) throw new ApiError(400,"INVALID_MEMBERS");
            }
            await tx.CommitAsync(); return Results.Created($"/v1/conversations/{input.Id}",new{id=input.Id});
        });
        app.MapPost("/v1/messages",async(SendRequest input,HttpContext ctx,NpgsqlDataSource db,Delivery delivery)=>
            Results.Ok(await delivery.Send(await Sql.Authenticate(ctx,db),input,ctx.RequestAborted)));
        app.MapGet("/v1/sync",async(Guid conversationId,string? cursor,int? limit,HttpContext ctx,NpgsqlDataSource db,Delivery delivery)=>
            Results.Ok(await delivery.Sync(await Sql.Authenticate(ctx,db),conversationId,cursor,limit??100,ctx.RequestAborted)));
        app.MapPost("/v1/acks",async(ProcessedAckRequest input,HttpContext ctx,NpgsqlDataSource db,Delivery delivery)=>
        {await delivery.Ack(await Sql.Authenticate(ctx,db),input);return Results.NoContent();});
    }
}
