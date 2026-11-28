using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using Npgsql;

namespace SecureMesh;

public sealed record ChannelInput(Guid Id, string Slug, string Title, bool InviteOnly = false);
public sealed record ChannelInvite(string Username);
public sealed record PostEdit(int ExpectedRevision, string Body);
public sealed record PostInput(Guid RequestId, string Body);

public static class PublicChannels
{
    private static readonly Regex Slug = new("^[a-z0-9_]{3,32}\\z", RegexOptions.CultureInvariant);
    private static readonly Regex Prefix = new("^[a-z0-9_]{0,32}\\z", RegexOptions.CultureInvariant);

    public static void MapPublicChannels(this WebApplication app)
    {
        var routes = app.MapGroup("/v1/public-channels");
        routes.MapGet("", List);
        routes.MapGet("/feed", AggregateFeed);
        routes.MapPost("", CreatePublic);
        routes.MapPost("/invite-only", CreateRestricted);
        routes.MapDelete("/{id:guid}", Remove);
        routes.MapPut("/{id:guid}/subscription", Subscribe);
        routes.MapDelete("/{id:guid}/subscription", Unsubscribe);
        routes.MapPost("/{id:guid}/invitations", Invite);
        routes.MapPost("/{id:guid}/revoke-access", RevokeAccess);
        routes.MapGet("/{id:guid}/posts", Feed);
        routes.MapPut("/{id:guid}/posts/{seq:long}", Edit);
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
        await using (var user = Sql.Cmd(c,"SELECT id FROM users WHERE id=$1 FOR NO KEY UPDATE", a.UserId))
            await user.ExecuteScalarAsync();
        await using var current = Sql.Cmd(c, """
            SELECT 1 FROM sessions s JOIN devices d ON d.id=s.device_id
            WHERE s.id=$1 AND d.id=$2 AND d.user_id=$3 AND d.trusted AND NOT d.revoked
              AND NOT s.used AND NOT s.revoked AND s.expires_at>now()
              AND session_idle_active(s.last_interactive_at,s.idle_timeout_days)
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

    private sealed record ChannelAccess(bool Owner, bool Restricted, bool Subscribed, bool Invited);

    private static async Task<ChannelAccess> Access(NpgsqlConnection c, Guid id, Actor a, bool write = false)
    {
        var sql = """
            SELECT p.owner_id=$2,p.invite_only,
                EXISTS (SELECT 1 FROM public_channel_subscriptions s WHERE s.user_id=$2 AND s.channel_id=p.id),
                EXISTS (SELECT 1 FROM channel_invitations i WHERE i.user_id=$2 AND i.channel_id=p.id AND i.expires_at>now())
            FROM channel_catalog p WHERE p.id=$1
            """ + (write ? " FOR UPDATE OF p" : " FOR SHARE OF p");
        await using var cmd=Sql.Cmd(c,sql,id,a.UserId);
        await using var r=await cmd.ExecuteReaderAsync();
        if (!await r.ReadAsync()) throw new ApiError(404,"CHANNEL_NOT_FOUND");
        var access=new ChannelAccess(r.GetBoolean(0),r.GetBoolean(1),r.GetBoolean(2),r.GetBoolean(3));
        if(access.Restricted && !access.Owner && !access.Subscribed && !access.Invited)
            throw new ApiError(404,"CHANNEL_NOT_FOUND");
        return access;
    }

    private static async Task<int> Count(NpgsqlConnection c, string query, Guid id)
    {
        await using var cmd=Sql.Cmd(c,query,id);
        return Convert.ToInt32(await cmd.ExecuteScalarAsync());
    }

    private static async Task<IResult> List(string? q, string? after, bool? mine, bool? includeRestricted, HttpContext ctx, NpgsqlDataSource db)
    {
        var a=await Sql.Authenticate(ctx,db);
        q=(q??"").ToLowerInvariant();
        var parts=(after??"").Split('~',2);
        var afterSlug=parts[0];
        var afterId=Guid.Empty;
        if(!Prefix.IsMatch(q) || !Prefix.IsMatch(afterSlug) ||
            (parts.Length==2 && !Guid.TryParseExact(parts[1],"D",out afterId)))
            throw new ApiError(400,"INVALID_CHANNEL_FILTER");
        // A pre-migration cursor supplied only a slug and already consumed that row.
        if(parts.Length==1 && afterSlug.Length!=0) afterId=Guid.Parse("ffffffff-ffff-ffff-ffff-ffffffffffff");
        await using var c=await db.OpenConnectionAsync();
        await using var cmd=Sql.Cmd(c,"""
            SELECT p.id,p.slug,p.title,p.owner_id=$1,s.user_id IS NOT NULL,p.invite_only,i.user_id IS NOT NULL
            FROM channel_catalog p LEFT JOIN public_channel_subscriptions s ON s.channel_id=p.id AND s.user_id=$1
            LEFT JOIN channel_invitations i ON i.channel_id=p.id AND i.user_id=$1 AND i.expires_at>now()
            WHERE (p.slug,p.id)>($2,$3) AND p.slug >= $4 AND p.slug < $5
              AND (NOT p.invite_only OR $7)
              AND ((NOT $6 AND NOT p.invite_only) OR p.owner_id=$1 OR s.user_id IS NOT NULL OR i.user_id IS NOT NULL)
            ORDER BY p.slug,p.id LIMIT 26
            """,a.UserId,afterSlug,afterId,q,q+"{",mine??false,includeRestricted??false);
        await using var r=await cmd.ExecuteReaderAsync();
        var items=new List<object>(); string? last=null; bool more=false;
        while(await r.ReadAsync())
        {
            if(items.Count==25){more=true;break;}
            var id=r.GetGuid(0);
            var slug=r.GetString(1);
            last=$"{slug}~{id:D}";
            items.Add(new {id,slug,title=r.GetString(2),owner=r.GetBoolean(3),subscribed=r.GetBoolean(4),
                inviteOnly=r.GetBoolean(5),invited=r.GetBoolean(6)});
        }
        return Results.Ok(new {items, next=more?last:null});
    }

    private static Task<IResult> CreatePublic(ChannelInput input,HttpContext ctx,NpgsqlDataSource db) =>
        input.InviteOnly ? throw new ApiError(400,"USE_INVITE_ONLY_CHANNEL_ROUTE") : Create(input,ctx,db);
    private static Task<IResult> CreateRestricted(ChannelInput input,HttpContext ctx,NpgsqlDataSource db) =>
        Create(input with {InviteOnly=true},ctx,db);

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
        await using(var existing=Sql.Cmd(c,"SELECT owner_id,slug,title,invite_only FROM channel_catalog WHERE id=$1",input.Id))
        await using(var r=await existing.ExecuteReaderAsync())
        {
            if(await r.ReadAsync())
            {
                if(r.GetGuid(0)!=a.UserId || r.GetString(1)!=input.Slug || r.GetString(2)!=title || r.GetBoolean(3)!=input.InviteOnly)
                    throw new ApiError(409,"CHANNEL_CONFLICT");
                return Results.Ok(new{id=input.Id,inviteOnly=input.InviteOnly});
            }
        }
        if(await Count(c,"SELECT count(*) FROM channel_catalog WHERE owner_id=$1",a.UserId)>=8)
            throw new ApiError(409,"CHANNEL_OWNERSHIP_QUOTA");
        await Charge(c,a.UserId,"create",10);
        await using var insert=Sql.Cmd(c,"INSERT INTO channel_catalog(id,owner_id,slug,title,invite_only) VALUES($1,$2,$3,$4,$5) ON CONFLICT DO NOTHING",input.Id,a.UserId,input.Slug,title,input.InviteOnly);
        if(await insert.ExecuteNonQueryAsync()!=1) throw new ApiError(409,"CHANNEL_CONFLICT");
        await tx.CommitAsync();return Results.Created($"/v1/public-channels/{input.Id}",new{id=input.Id,inviteOnly=input.InviteOnly});
    }

    private static async Task<IResult> Remove(Guid id,HttpContext ctx,NpgsqlDataSource db)
    {
        var a=await Sql.Authenticate(ctx,db);
        await using var c=await db.OpenConnectionAsync(); await using var tx=await c.BeginTransactionAsync();
        await LockAccount(c,a);
        if(!(await Access(c,id,a,true)).Owner) throw new ApiError(403,"CHANNEL_OWNER_REQUIRED");
        await using (var mark=Sql.Cmd(c,"INSERT INTO public_channel_removed(owner_id,id) VALUES($1,$2)",a.UserId,id))
            await mark.ExecuteNonQueryAsync();
        await using var cmd=Sql.Cmd(c,"DELETE FROM channel_catalog WHERE id=$1",id);
        await cmd.ExecuteNonQueryAsync(); await tx.CommitAsync();return Results.NoContent();
    }

    private static Task<IResult> Subscribe(Guid id,HttpContext ctx,NpgsqlDataSource db) => Subscription(id,ctx,db,true);
    private static Task<IResult> Unsubscribe(Guid id,HttpContext ctx,NpgsqlDataSource db) => Subscription(id,ctx,db,false);
    private static async Task<IResult> Subscription(Guid id,HttpContext ctx,NpgsqlDataSource db,bool add)
    {
        var a=await Sql.Authenticate(ctx,db);
        await using var c=await db.OpenConnectionAsync();await using var tx=await c.BeginTransactionAsync();
        await LockAccount(c,a);
        var access=await Access(c,id,a,true);
        if(access.Owner) throw new ApiError(409,"CHANNEL_OWNER_ALREADY_HAS_ACCESS");
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
        if(access.Restricted)
        {
            await using var clear=Sql.Cmd(c,"DELETE FROM channel_invitations WHERE channel_id=$1 AND user_id=$2",id,a.UserId);
            await clear.ExecuteNonQueryAsync();
        }
        await tx.CommitAsync();return Results.NoContent();
    }

    private static async Task<IResult> Invite(Guid id,ChannelInvite input,HttpContext ctx,NpgsqlDataSource db)
    {
        var actor=await Sql.Authenticate(ctx,db);
        var name=input.Username?.Trim().ToLowerInvariant();
        if(name is null || !Slug.IsMatch(name)) throw new ApiError(400,"INVALID_USERNAME");
        await using var c=await db.OpenConnectionAsync();await using var tx=await c.BeginTransactionAsync();
        await LockAccount(c,actor);
        var access=await Access(c,id,actor,true);
        if(!access.Owner) throw new ApiError(403,"CHANNEL_OWNER_REQUIRED");
        if(!access.Restricted) throw new ApiError(409,"CHANNEL_PUBLIC");
        await using (var expire=Sql.Cmd(c,"DELETE FROM channel_invitations WHERE channel_id=$1 AND expires_at<=now()",id))
            await expire.ExecuteNonQueryAsync();
        // Unknown usernames, existing members and repeated invitations have the same response.
        // Charge all attempts to bound probing by owners, including unknown recipients.
        await Charge(c,actor.UserId,"invite",120);
        if(await Count(c,"SELECT count(*) FROM channel_invitations WHERE channel_id=$1",id)>=64)
            throw new ApiError(409,"CHANNEL_INVITATION_QUOTA");
        // Serialize inbound capacity across independent owners without locking the target account.
        await using (var gate=Sql.Cmd(c,"SELECT pg_advisory_xact_lock(hashtextextended('channel-invite:' || $1, 0))",name))
            await gate.ExecuteNonQueryAsync();
        await using var insert=Sql.Cmd(c,"""
            INSERT INTO channel_invitations(channel_id,user_id,expires_at)
            SELECT $1,u.id,now()+interval '7 days' FROM users u
            WHERE u.username=$2 AND u.verified AND u.id<>$3
              AND (SELECT count(*) FROM channel_invitations pending WHERE pending.user_id=u.id AND pending.expires_at>now())<128
              AND NOT EXISTS
              (SELECT 1 FROM public_channel_subscriptions s WHERE s.channel_id=$1 AND s.user_id=u.id)
            ON CONFLICT DO NOTHING
            """,id,name,actor.UserId);
        await insert.ExecuteNonQueryAsync();await tx.CommitAsync();return Results.NoContent();
    }

    private static async Task<IResult> RevokeAccess(Guid id,ChannelInvite input,HttpContext ctx,NpgsqlDataSource db)
    {
        var actor=await Sql.Authenticate(ctx,db);
        var name=input.Username?.Trim().ToLowerInvariant();
        if(name is null || !Slug.IsMatch(name)) throw new ApiError(400,"INVALID_USERNAME");
        await using var c=await db.OpenConnectionAsync();await using var tx=await c.BeginTransactionAsync();
        await LockAccount(c,actor);
        var access=await Access(c,id,actor,true);
        if(!access.Owner) throw new ApiError(403,"CHANNEL_OWNER_REQUIRED");
        if(!access.Restricted) throw new ApiError(409,"CHANNEL_PUBLIC");
        await Charge(c,actor.UserId,"revoke",240);
        await using(var invites=Sql.Cmd(c,"DELETE FROM channel_invitations i USING users u WHERE i.channel_id=$1 AND i.user_id=u.id AND u.username=$2",id,name))
            await invites.ExecuteNonQueryAsync();
        await using(var members=Sql.Cmd(c,"DELETE FROM public_channel_subscriptions s USING users u WHERE s.channel_id=$1 AND s.user_id=u.id AND u.username=$2",id,name))
            await members.ExecuteNonQueryAsync();
        await tx.CommitAsync();return Results.NoContent();
    }

    private static async Task<IResult> Edit(Guid id,long seq,PostEdit input,HttpContext ctx,NpgsqlDataSource db)
    {
        var actor=await Sql.Authenticate(ctx,db);
        if(input.ExpectedRevision<1) throw new ApiError(400,"INVALID_CHANNEL_REVISION");
        var body=Text(input.Body,2048,true);
        await using var c=await db.OpenConnectionAsync();await using var tx=await c.BeginTransactionAsync();
        await LockAccount(c,actor);
        if(!(await Access(c,id,actor,true)).Owner) throw new ApiError(403,"CHANNEL_OWNER_REQUIRED");
        await using(var current=Sql.Cmd(c,"SELECT body,revision FROM public_channel_posts WHERE channel_id=$1 AND seq=$2 AND body IS NOT NULL",id,seq))
        await using(var r=await current.ExecuteReaderAsync())
        {
            if(!await r.ReadAsync()) throw new ApiError(404,"CHANNEL_POST_NOT_FOUND");
            var revision=r.GetInt32(1);
            if(r.GetString(0)==body && (revision==input.ExpectedRevision || revision-1==input.ExpectedRevision))
                return Results.Ok(new{seq,revision});
            if(revision!=input.ExpectedRevision) throw new ApiError(409,"CHANNEL_POST_CHANGED");
        }
        await Charge(c,actor.UserId,"edit",240);
        await using var update=Sql.Cmd(c,"UPDATE public_channel_posts SET body=$1,revision=revision+1 WHERE channel_id=$2 AND seq=$3 RETURNING revision",body,id,seq);
        var next=(int)(await update.ExecuteScalarAsync())!;await tx.CommitAsync();
        return Results.Ok(new{seq,revision=next});
    }

    // Cursor contains the exact database timestamp and globally unique sequence as a tie breaker.
    private static async Task<IResult> AggregateFeed(string? before, HttpContext ctx, NpgsqlDataSource db)
    {
        var actor = await Sql.Authenticate(ctx, db);
        DateTime timestamp = DateTime.MaxValue.ToUniversalTime();
        long seq = long.MaxValue;
        if (before is not null)
        {
            var parts = before.Split('~');
            if (parts.Length != 2 || !long.TryParse(parts[0], out var ticks) ||
                !long.TryParse(parts[1], out seq) || seq <= 0 || ticks < DateTime.MinValue.Ticks || ticks > DateTime.MaxValue.Ticks)
                throw new ApiError(400, "INVALID_CHANNEL_CURSOR");
            timestamp = new DateTime(ticks, DateTimeKind.Utc);
        }
        await using var c = await db.OpenConnectionAsync();
        await using var cmd = Sql.Cmd(c, """
            SELECT p.seq,p.body,p.published_at,p.revision,ch.id,ch.slug,ch.title
            FROM public_channel_subscriptions s
            JOIN channel_catalog ch ON ch.id=s.channel_id AND NOT ch.invite_only
            JOIN public_channel_posts p ON p.channel_id=ch.id AND p.body IS NOT NULL
            WHERE s.user_id=$1 AND (p.published_at,p.seq)<($2,$3)
            ORDER BY p.published_at DESC,p.seq DESC LIMIT 21
            """, actor.UserId, timestamp, seq);
        await using var r = await cmd.ExecuteReaderAsync();
        var items = new List<object>(); string? last = null; bool more = false;
        while (await r.ReadAsync())
        {
            if (items.Count == 20) { more = true; break; }
            var published = r.GetDateTime(2); var postSeq = r.GetInt64(0);
            last = $"{published.Ticks}~{postSeq}";
            items.Add(new { seq = postSeq, body = r.GetString(1), publishedAt = published,
                revision = r.GetInt32(3), channelId = r.GetGuid(4), slug = r.GetString(5), title = r.GetString(6) });
        }
        return Results.Ok(new { items, next = more ? last : null });
    }

    private static async Task<IResult> Feed(Guid id,long? before,HttpContext ctx,NpgsqlDataSource db)
    {
        var a=await Sql.Authenticate(ctx,db);
        if(before<=0)throw new ApiError(400,"INVALID_CHANNEL_CURSOR");
        await using var c=await db.OpenConnectionAsync();
        await using var tx=await c.BeginTransactionAsync();
        var access=await Access(c,id,a);
        if(!access.Owner && !access.Subscribed) throw new ApiError(403,"CHANNEL_SUBSCRIPTION_REQUIRED");
        await using var cmd=Sql.Cmd(c,"SELECT seq,body,published_at,revision FROM public_channel_posts WHERE channel_id=$1 AND body IS NOT NULL AND seq<$2 ORDER BY seq DESC LIMIT 9",id,before??long.MaxValue);
        await using var r=await cmd.ExecuteReaderAsync();
        var items=new List<object>(); long? last=null; bool more=false;
        while(await r.ReadAsync())
        {
            if(items.Count==8){more=true;break;}
            last=r.GetInt64(0);items.Add(new{seq=last,body=r.GetString(1),publishedAt=r.GetDateTime(2),revision=r.GetInt32(3)});
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
        if(!(await Access(c,id,a,true)).Owner)throw new ApiError(403,"CHANNEL_OWNER_REQUIRED");
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
        if(!(await Access(c,id,a,true)).Owner)throw new ApiError(403,"CHANNEL_OWNER_REQUIRED");
        await using var cmd=Sql.Cmd(c,"UPDATE public_channel_posts SET body=NULL,deleted_at=now() WHERE channel_id=$1 AND seq=$2 AND body IS NOT NULL",id,seq);
        await cmd.ExecuteNonQueryAsync();await tx.CommitAsync();return Results.NoContent();
    }
}
