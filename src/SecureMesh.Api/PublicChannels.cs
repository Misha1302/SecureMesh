using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using Npgsql;

namespace SecureMesh;

public sealed record ChannelInput(Guid Id, string Slug, string Title);
public sealed record PostInput(Guid RequestId, string Body);

public static class PublicChannels
{
    private static readonly Regex Slug = new("^[a-z0-9_]{3,32}\\z", RegexOptions.CultureInvariant);
    private static readonly Regex Prefix = new("^[a-z0-9_]{0,32}\\z", RegexOptions.CultureInvariant);

    public static void MapPublicChannels(this WebApplication app)
    {
        var routes = app.MapGroup("/v1/public-channels");
        routes.MapGet("", List);
        routes.MapPost("", Create);
        routes.MapDelete("/{id:guid}", Remove);
        routes.MapPut("/{id:guid}/subscription", Subscribe);
        routes.MapDelete("/{id:guid}/subscription", Unsubscribe);
        routes.MapGet("/{id:guid}/posts", Feed);
        routes.MapPost("/{id:guid}/posts", Publish);
        routes.MapDelete("/{id:guid}/posts/{seq:long}", RemovePost);
    }

    private static string Text(string? value, int limit, bool multiline = false)
    {
        if (value is null || value.Length > limit * 2) throw new ApiError(400, "INVALID_CHANNEL_TEXT");
        var text = value.Trim().Normalize(NormalizationForm.FormC);
        if (text.Length == 0 || text.EnumerateRunes().Count() > limit) throw new ApiError(400, "INVALID_CHANNEL_TEXT");
        foreach (var r in text.EnumerateRunes())
        {
            if (multiline && r.Value == '\n') continue;
            if (Rune.GetUnicodeCategory(r) is UnicodeCategory.Control or UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator ||
                (Rune.GetUnicodeCategory(r) == UnicodeCategory.Format && r.Value != 0x200D))
                throw new ApiError(400, "INVALID_CHANNEL_TEXT");
        }
        return text;
    }

    // Serialize quotas across multiple devices of the same account and order writes with revocation.
    private static async Task LockAccount(NpgsqlConnection c, Actor a)
    {
        await using (var user = Sql.Cmd(c,"SELECT id FROM users WHERE id=$1 FOR UPDATE", a.UserId))
            await user.ExecuteScalarAsync();
        await using var current = Sql.Cmd(c, """
            SELECT 1 FROM sessions s JOIN devices d ON d.id=s.device_id
            WHERE s.id=$1 AND d.id=$2 AND d.user_id=$3 AND d.trusted AND NOT d.revoked
              AND NOT s.used AND NOT s.revoked AND s.expires_at>now()
            """, a.SessionId, a.DeviceId, a.UserId);
        if (await current.ExecuteScalarAsync() is null) throw new ApiError(401,"AUTH_REQUIRED");
    }

    private static async Task Charge(NpgsqlConnection c, Guid user, string action, int limit)
    {
        await using var cmd = Sql.Cmd(c, """
            INSERT INTO public_channel_activity(user_id,action,window_start,count) VALUES($1,$2,now(),1)
            ON CONFLICT(user_id,action) DO UPDATE SET
              count=CASE WHEN public_channel_activity.window_start <= now()-interval '1 hour' THEN 1 ELSE public_channel_activity.count+1 END,
              window_start=CASE WHEN public_channel_activity.window_start <= now()-interval '1 hour' THEN now() ELSE public_channel_activity.window_start END
            WHERE public_channel_activity.count < $3 OR public_channel_activity.window_start <= now()-interval '1 hour'
            RETURNING count
            """, user, action, limit);
        if (await cmd.ExecuteScalarAsync() is null) throw new ApiError(429,"CHANNEL_RATE_LIMIT");
    }

    private static async Task<Guid> Owner(NpgsqlConnection c, Guid id, bool write = false)
    {
        var sql = "SELECT owner_id FROM public_channels WHERE id=$1" + (write ? " FOR UPDATE" : "");
        await using var cmd=Sql.Cmd(c,sql,id);
        return await cmd.ExecuteScalarAsync() is Guid owner ? owner : throw new ApiError(404,"CHANNEL_NOT_FOUND");
    }

    private static async Task<int> Count(NpgsqlConnection c, string query, Guid id)
    {
        await using var cmd=Sql.Cmd(c,query,id);
        return Convert.ToInt32(await cmd.ExecuteScalarAsync());
    }

    private static async Task<IResult> List(string? q, string? after, bool? mine, HttpContext ctx, NpgsqlDataSource db)
    {
        var a=await Sql.Authenticate(ctx,db);
        q=(q??"").ToLowerInvariant(); after??="";
        if (!Prefix.IsMatch(q) || !Prefix.IsMatch(after)) throw new ApiError(400,"INVALID_CHANNEL_FILTER");
        await using var c=await db.OpenConnectionAsync();
        // C collation and the bounded ASCII alphabet make the prefix interval indexable,
        // including literal underscores. One extra row distinguishes a full last page.
        await using var cmd=Sql.Cmd(c,"""
            SELECT p.id,p.slug,p.title,p.owner_id=$1,s.user_id IS NOT NULL
            FROM public_channels p LEFT JOIN public_channel_subscriptions s ON s.channel_id=p.id AND s.user_id=$1
            WHERE p.slug > $2 AND p.slug >= $3 AND p.slug < $4 AND (NOT $5 OR p.owner_id=$1 OR s.user_id IS NOT NULL)
            ORDER BY p.slug LIMIT 26
            """,a.UserId,after,q,q+"{",mine??false);
        await using var r=await cmd.ExecuteReaderAsync();
        var items=new List<object>(); string? last=null; bool more=false;
        while(await r.ReadAsync())
        {
            if(items.Count==25){more=true;break;}
            last=r.GetString(1);
            items.Add(new {id=r.GetGuid(0),slug=last,title=r.GetString(2),owner=r.GetBoolean(3),subscribed=r.GetBoolean(4)});
        }
        return Results.Ok(new {items, next=more?last:null});
    }

    private static async Task<IResult> Create(ChannelInput input,HttpContext ctx,NpgsqlDataSource db)
    {
        var a=await Sql.Authenticate(ctx,db);
        if(input.Id==Guid.Empty || input.Slug is null || !Slug.IsMatch(input.Slug)) throw new ApiError(400,"INVALID_CHANNEL_SLUG");
        var title=Text(input.Title,80);
        await using var c=await db.OpenConnectionAsync(); await using var tx=await c.BeginTransactionAsync();
        await LockAccount(c,a);
        await using(var expire=Sql.Cmd(c,"DELETE FROM public_channel_removed WHERE owner_id=$1 AND deleted_at < now()-interval '1 day'",a.UserId))
            await expire.ExecuteNonQueryAsync();
        await using(var removed=Sql.Cmd(c,"SELECT 1 FROM public_channel_removed WHERE owner_id=$1 AND id=$2",a.UserId,input.Id))
            if(await removed.ExecuteScalarAsync() is not null) throw new ApiError(409,"CHANNEL_REMOVED");
        await using(var existing=Sql.Cmd(c,"SELECT owner_id,slug,title FROM public_channels WHERE id=$1",input.Id))
        await using(var r=await existing.ExecuteReaderAsync())
        {
            if(await r.ReadAsync())
            {
                if(r.GetGuid(0)!=a.UserId || r.GetString(1)!=input.Slug || r.GetString(2)!=title)
                    throw new ApiError(409,"CHANNEL_CONFLICT");
                return Results.Ok(new{id=input.Id});
            }
        }
        if(await Count(c,"SELECT count(*) FROM public_channels WHERE owner_id=$1",a.UserId)>=8)
            throw new ApiError(409,"CHANNEL_OWNERSHIP_QUOTA");
        await Charge(c,a.UserId,"create",10);
        await using var insert=Sql.Cmd(c,"INSERT INTO public_channels(id,owner_id,slug,title) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING",input.Id,a.UserId,input.Slug,title);
        if(await insert.ExecuteNonQueryAsync()!=1) throw new ApiError(409,"CHANNEL_CONFLICT");
        await tx.CommitAsync();return Results.Created($"/v1/public-channels/{input.Id}",new{id=input.Id});
    }

    private static async Task<IResult> Remove(Guid id,HttpContext ctx,NpgsqlDataSource db)
    {
        var a=await Sql.Authenticate(ctx,db);
        await using var c=await db.OpenConnectionAsync(); await using var tx=await c.BeginTransactionAsync();
        await LockAccount(c,a);
        if(await Owner(c,id,true)!=a.UserId) throw new ApiError(403,"CHANNEL_OWNER_REQUIRED");
        await using (var mark=Sql.Cmd(c,"INSERT INTO public_channel_removed(owner_id,id) VALUES($1,$2)",a.UserId,id))
            await mark.ExecuteNonQueryAsync();
        await using var cmd=Sql.Cmd(c,"DELETE FROM public_channels WHERE id=$1",id);
        await cmd.ExecuteNonQueryAsync(); await tx.CommitAsync();return Results.NoContent();
    }

    private static Task<IResult> Subscribe(Guid id,HttpContext ctx,NpgsqlDataSource db) => Subscription(id,ctx,db,true);
    private static Task<IResult> Unsubscribe(Guid id,HttpContext ctx,NpgsqlDataSource db) => Subscription(id,ctx,db,false);
    private static async Task<IResult> Subscription(Guid id,HttpContext ctx,NpgsqlDataSource db,bool add)
    {
        var a=await Sql.Authenticate(ctx,db);
        await using var c=await db.OpenConnectionAsync();await using var tx=await c.BeginTransactionAsync();
        await LockAccount(c,a);
        if(await Owner(c,id,true)==a.UserId) throw new ApiError(409,"CHANNEL_OWNER_ALREADY_HAS_ACCESS");
        if(add)
        {
            await using var cmd=Sql.Cmd(c,"INSERT INTO public_channel_subscriptions(user_id,channel_id) VALUES($1,$2) ON CONFLICT DO NOTHING",a.UserId,id);
            if(await cmd.ExecuteNonQueryAsync()!=0)
            {
                if(await Count(c,"SELECT count(*) FROM public_channel_subscriptions WHERE user_id=$1",a.UserId)>128)
                    throw new ApiError(409,"CHANNEL_SUBSCRIPTION_QUOTA");
                await Charge(c,a.UserId,"subscribe",180);
            }
        }
        else
        {
            await using var cmd=Sql.Cmd(c,"DELETE FROM public_channel_subscriptions WHERE user_id=$1 AND channel_id=$2",a.UserId,id);
            await cmd.ExecuteNonQueryAsync();
        }
        await tx.CommitAsync();return Results.NoContent();
    }

    private static async Task<IResult> Feed(Guid id,long? before,HttpContext ctx,NpgsqlDataSource db)
    {
        var a=await Sql.Authenticate(ctx,db);
        if(before<=0)throw new ApiError(400,"INVALID_CHANNEL_CURSOR");
        await using var c=await db.OpenConnectionAsync();
        var owner=await Owner(c,id);
        if (owner!=a.UserId)
        {
            await using var check=Sql.Cmd(c,"SELECT 1 FROM public_channel_subscriptions WHERE user_id=$1 AND channel_id=$2",a.UserId,id);
            if(await check.ExecuteScalarAsync() is null) throw new ApiError(403,"CHANNEL_SUBSCRIPTION_REQUIRED");
        }
        await using var cmd=Sql.Cmd(c,"SELECT seq,body,published_at FROM public_channel_posts WHERE channel_id=$1 AND body IS NOT NULL AND seq<$2 ORDER BY seq DESC LIMIT 9",id,before??long.MaxValue);
        await using var r=await cmd.ExecuteReaderAsync();
        var items=new List<object>(); long? last=null; bool more=false;
        while(await r.ReadAsync())
        {
            if(items.Count==8){more=true;break;}
            last=r.GetInt64(0);items.Add(new{seq=last,body=r.GetString(1),publishedAt=r.GetDateTime(2)});
        }
        return Results.Ok(new{items,next=more?last:null});
    }

    private static async Task<IResult> Publish(Guid id,PostInput input,HttpContext ctx,NpgsqlDataSource db)
    {
        var a=await Sql.Authenticate(ctx,db);
        if(input.RequestId==Guid.Empty)throw new ApiError(400,"INVALID_CHANNEL_REQUEST");
        var body=Text(input.Body,2048,true);
        await using var c=await db.OpenConnectionAsync();await using var tx=await c.BeginTransactionAsync();
        await LockAccount(c,a);
        if(await Owner(c,id,true)!=a.UserId)throw new ApiError(403,"CHANNEL_OWNER_REQUIRED");
        await using(var expire=Sql.Cmd(c,"DELETE FROM public_channel_posts WHERE channel_id=$1 AND deleted_at < now()-interval '1 day'",id))
            await expire.ExecuteNonQueryAsync();
        await using(var old=Sql.Cmd(c,"SELECT seq,body FROM public_channel_posts WHERE channel_id=$1 AND request_id=$2",id,input.RequestId))
        await using(var r=await old.ExecuteReaderAsync())
        {
            if(await r.ReadAsync())
            {
                if(r.IsDBNull(1) || r.GetString(1)!=body)throw new ApiError(409,"CHANNEL_POST_CONFLICT");
                return Results.Ok(new{seq=r.GetInt64(0)});
            }
        }
        if(await Count(c,"SELECT count(*) FROM public_channel_posts WHERE channel_id=$1 AND body IS NOT NULL",id)>=2000)
            throw new ApiError(409,"CHANNEL_POST_QUOTA");
        await Charge(c,a.UserId,"publish",120);
        await using var insert=Sql.Cmd(c,"INSERT INTO public_channel_posts(channel_id,request_id,body) VALUES($1,$2,$3) RETURNING seq",id,input.RequestId,body);
        var seq=(long)(await insert.ExecuteScalarAsync())!;await tx.CommitAsync();return Results.Created($"/v1/public-channels/{id}/posts/{seq}",new{seq});
    }

    private static async Task<IResult> RemovePost(Guid id,long seq,HttpContext ctx,NpgsqlDataSource db)
    {
        var a=await Sql.Authenticate(ctx,db);
        await using var c=await db.OpenConnectionAsync();await using var tx=await c.BeginTransactionAsync();
        await LockAccount(c,a);
        if(await Owner(c,id,true)!=a.UserId)throw new ApiError(403,"CHANNEL_OWNER_REQUIRED");
        await using var cmd=Sql.Cmd(c,"UPDATE public_channel_posts SET body=NULL,deleted_at=now() WHERE channel_id=$1 AND seq=$2 AND body IS NOT NULL",id,seq);
        await cmd.ExecuteNonQueryAsync();await tx.CommitAsync();return Results.NoContent();
    }
}
