using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using System.Text.Json.Serialization;
using Npgsql;

namespace SecureMesh;

public sealed record ChannelInput(Guid Id, string Slug, string Title, bool InviteOnly = false);
public sealed record ChannelInvite(string Username);
public sealed record ChannelPin([property: JsonRequired] long ExpectedRevision, [property: JsonRequired] long? Seq);
public sealed record PostEdit(int ExpectedRevision, string Body);
public sealed record PostInput(Guid RequestId, string Body);
public sealed record PostReaction(string Kind);

public static partial class PublicChannels
{
    private static readonly Regex Slug = new("^[a-z0-9_]{3,32}\\z", RegexOptions.CultureInvariant);
    private static readonly Regex Prefix = new("^[a-z0-9_]{0,32}\\z", RegexOptions.CultureInvariant);

    private const int ReactionLimit = 4096;
    private const string ReactionProjection = """
        count(*) FILTER (WHERE r.kind='like'),
        count(*) FILTER (WHERE r.kind='heart'),
        count(*) FILTER (WHERE r.kind='smile'),
        max(r.kind) FILTER (WHERE r.user_id=$1)
        """;

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
        routes.MapPut("/{id:guid}/pin", SetPin);
        routes.MapGet("/{id:guid}/posts", Feed);
        routes.MapPut("/{id:guid}/posts/{seq:long}", Edit);
        routes.MapPut("/{id:guid}/posts/{seq:long}/reaction", PutReaction);
        routes.MapDelete("/{id:guid}/posts/{seq:long}/reaction", DeleteReaction);
        var comments = routes.MapGroup("/{id:guid}/posts/{seq:long}/comments");
        comments.MapGet("", ListComments);
        comments.MapPost("", AddComment);
        comments.MapDelete("/{comment:long}", DeleteComment);
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
              AND NOT s.used AND NOT s.revoked AND s.expires_at>statement_timestamp()
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
        // ACL reads need a fresh statement after waiting on a membership or removal writer.
        var lockMode = write ? "FOR UPDATE" : "FOR SHARE";
        await using (var gate = Sql.Cmd(c, $"SELECT id FROM channel_catalog WHERE id=$1 {lockMode}",id))
            if(await gate.ExecuteScalarAsync() is null) throw new ApiError(404,"CHANNEL_NOT_FOUND");
        await using var cmd=Sql.Cmd(c,"""
            SELECT p.owner_id=$2,p.invite_only,
                EXISTS (SELECT 1 FROM public_channel_subscriptions s WHERE s.user_id=$2 AND s.channel_id=p.id),
                EXISTS (SELECT 1 FROM channel_invitations i WHERE i.user_id=$2 AND i.channel_id=p.id AND i.expires_at>statement_timestamp())
            FROM channel_catalog p WHERE p.id=$1
            """,id,a.UserId);
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
            await ClearAccountReactions(c,id,a.UserId);
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
        await using(var members=Sql.Cmd(c,"""
            DELETE FROM public_channel_subscriptions s USING users u
            WHERE s.channel_id=$1 AND s.user_id=u.id AND u.username=$2 RETURNING s.user_id
            """,id,name))
            if(await members.ExecuteScalarAsync() is Guid member)
                await ClearAccountReactions(c,id,member);
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
        await using(var current=Sql.Cmd(c,"SELECT body,revision,edited_at FROM public_channel_posts WHERE channel_id=$1 AND seq=$2 AND body IS NOT NULL",id,seq))
        await using(var r=await current.ExecuteReaderAsync())
        {
            if(!await r.ReadAsync()) throw new ApiError(404,"CHANNEL_POST_NOT_FOUND");
            var revision=r.GetInt32(1);
            if(r.GetString(0)==body && (revision==input.ExpectedRevision || revision-1==input.ExpectedRevision))
                return Results.Ok(new{seq,revision,editedAt=ReadEditTime(r,2)});
            if(revision!=input.ExpectedRevision) throw new ApiError(409,"CHANNEL_POST_CHANGED");
        }
        await Charge(c,actor.UserId,"edit",240);
        await using var update=Sql.Cmd(c,"""
            UPDATE public_channel_posts SET body=$1,revision=revision+1,edited_at=statement_timestamp()
            WHERE channel_id=$2 AND seq=$3 RETURNING revision,edited_at
            """,body,id,seq);
        int next; DateTime editedAt;
        await using(var row=await update.ExecuteReaderAsync())
        {
            if(!await row.ReadAsync()) throw new ApiError(404,"CHANNEL_POST_NOT_FOUND");
            next=row.GetInt32(0); editedAt=row.GetDateTime(1);
        }
        await tx.CommitAsync();
        return Results.Ok(new{seq,revision=next,editedAt});
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
        await using var c = await db.OpenConnectionAsync(ctx.RequestAborted);
        await using var tx = await c.BeginTransactionAsync(ctx.RequestAborted);
        await Sql.LockTrustedDeliverySession(c, actor, ctx.RequestAborted);
        await using var cmd = Sql.Cmd(c, $$"""
            WITH page AS MATERIALIZED (
                SELECT p.seq,p.body,p.published_at,p.revision,ch.id,ch.slug,ch.title,p.edited_at
                FROM public_channel_subscriptions s
                JOIN channel_catalog ch ON ch.id=s.channel_id AND NOT ch.invite_only
                JOIN public_channel_posts p ON p.channel_id=ch.id AND p.body IS NOT NULL
                WHERE s.user_id=$1 AND (p.published_at,p.seq)<($2,$3)
                ORDER BY p.published_at DESC,p.seq DESC LIMIT 9
            )
            SELECT p.*, reactions.* FROM page p
            CROSS JOIN LATERAL (
                SELECT {{ReactionProjection}} FROM public_channel_reactions r WHERE r.post_seq=p.seq
            ) reactions
            ORDER BY p.published_at DESC,p.seq DESC
            """, actor.UserId, timestamp, seq);
        await using var r = await cmd.ExecuteReaderAsync(ctx.RequestAborted);
        var items = new List<object>(); string? last = null; bool more = false;
        while (await r.ReadAsync(ctx.RequestAborted))
        {
            // Eight maximum-length Unicode posts fit the native transport’s 256 KiB limit.
            if (items.Count == 8) { more = true; break; }
            var published = r.GetDateTime(2); var postSeq = r.GetInt64(0);
            last = $"{published.Ticks}~{postSeq}";
            items.Add(new { seq = postSeq, body = r.GetString(1), publishedAt = published,
                revision = r.GetInt32(3), channelId = r.GetGuid(4), slug = r.GetString(5), title = r.GetString(6),
                editedAt = ReadEditTime(r,7), reactions = ReadReactions(r,8) });
        }
        return Results.Ok(new { items, next = more ? last : null });
    }

    private static async Task<IResult> SetPin(Guid id,ChannelPin input,HttpContext ctx,NpgsqlDataSource db)
    {
        var a=await Sql.Authenticate(ctx,db);
        if(input.ExpectedRevision<0 || input.Seq<=0) throw new ApiError(400,"INVALID_CHANNEL_PIN");
        await using var c=await db.OpenConnectionAsync();
        await using var tx=await c.BeginTransactionAsync();
        await LockAccount(c,a);
        if(!(await Access(c,id,a,true)).Owner) throw new ApiError(403,"CHANNEL_OWNER_REQUIRED");
        if(input.Seq is long seq)
        {
            await using var target=Sql.Cmd(c,"SELECT 1 FROM public_channel_posts WHERE channel_id=$1 AND seq=$2 AND body IS NOT NULL",id,seq);
            if(await target.ExecuteScalarAsync() is null) throw new ApiError(404,"CHANNEL_POST_NOT_FOUND");
        }
        long revision;
        long? current;
        await using(var get=Sql.Cmd(c,"SELECT pin_revision,pinned_seq FROM channel_catalog WHERE id=$1",id))
        await using(var r=await get.ExecuteReaderAsync())
        {
            await r.ReadAsync();
            revision=r.GetInt64(0);
            current=r.IsDBNull(1)?null:r.GetInt64(1);
        }
        if(input.ExpectedRevision!=revision && !(current==input.Seq && input.ExpectedRevision==revision-1))
            throw new ApiError(409,"CHANNEL_PIN_CHANGED");
        if(current!=input.Seq)
        {
            await using var update=Sql.Cmd(c,"UPDATE channel_catalog SET pinned_seq=$2::bigint,pin_revision=pin_revision+1 WHERE id=$1",id,(object?)input.Seq??DBNull.Value);
            await update.ExecuteNonQueryAsync();
        }
        await tx.CommitAsync();
        return Results.NoContent();
    }

    private static async Task<IResult> Feed(Guid id,long? before,HttpContext ctx,NpgsqlDataSource db)
    {
        var a=await Sql.Authenticate(ctx,db);
        if(before<=0)throw new ApiError(400,"INVALID_CHANNEL_CURSOR");
        await using var c=await db.OpenConnectionAsync(ctx.RequestAborted);
        await using var tx=await c.BeginTransactionAsync(ctx.RequestAborted);
        await Sql.LockTrustedDeliverySession(c, a, ctx.RequestAborted);
        var access=await Access(c,id,a);
        if(!access.Owner && !access.Subscribed) throw new ApiError(403,"CHANNEL_SUBSCRIPTION_REQUIRED");
        long pinRevision;
        object? pinned=null;
        await using(var pin=Sql.Cmd(c,"""
            SELECT c.pin_revision,p.seq,p.body FROM channel_catalog c
            LEFT JOIN public_channel_posts p ON p.channel_id=c.id AND p.seq=c.pinned_seq AND p.body IS NOT NULL
            WHERE c.id=$1
            """,id))
        await using(var pr=await pin.ExecuteReaderAsync(ctx.RequestAborted))
        {
            await pr.ReadAsync(ctx.RequestAborted);
            pinRevision=pr.GetInt64(0);
            if(!pr.IsDBNull(1)) pinned=new {seq=pr.GetInt64(1),body=pr.GetString(2)};
        }
        await using var cmd=Sql.Cmd(c,$$"""
            WITH page AS MATERIALIZED (
                SELECT seq,body,published_at,revision,edited_at FROM public_channel_posts
                WHERE channel_id=$2 AND body IS NOT NULL AND seq<$3 ORDER BY seq DESC LIMIT 9
            )
            SELECT p.*, reactions.* FROM page p
            CROSS JOIN LATERAL (
                SELECT {{ReactionProjection}} FROM public_channel_reactions r WHERE r.post_seq=p.seq
            ) reactions ORDER BY p.seq DESC
            """,a.UserId,id,before??long.MaxValue);
        await using var r=await cmd.ExecuteReaderAsync(ctx.RequestAborted);
        var items=new List<object>(); long? last=null; bool more=false;
        while(await r.ReadAsync(ctx.RequestAborted))
        {
            if(items.Count==8){more=true;break;}
            last=r.GetInt64(0);items.Add(new{seq=last,body=r.GetString(1),publishedAt=r.GetDateTime(2),revision=r.GetInt32(3),editedAt=ReadEditTime(r,4),reactions=ReadReactions(r,5)});
        }
        return Results.Ok(new{items,next=more?last:null,pinned,pinRevision});
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

    private static DateTime? ReadEditTime(NpgsqlDataReader row, int index) =>
        row.IsDBNull(index) ? null : row.GetDateTime(index);

    private sealed record ReactionCounts(long Like, long Heart, long Smile, string? Mine);

    private static ReactionCounts ReadReactions(NpgsqlDataReader row, int start) =>
        new(row.GetInt64(start), row.GetInt64(start+1), row.GetInt64(start+2),
            row.IsDBNull(start+3) ? null : row.GetString(start+3));

    private static async Task<ReactionCounts> ReadPostReactions(NpgsqlConnection c, long post, Guid account)
    {
        await using var cmd=Sql.Cmd(c,$$"""
            SELECT {{ReactionProjection}} FROM public_channel_reactions r WHERE r.post_seq=$2
            """,account,post);
        await using var row=await cmd.ExecuteReaderAsync();
        await row.ReadAsync();
        return ReadReactions(row,0);
    }

    private static async Task ClearAccountReactions(NpgsqlConnection c, Guid channel, Guid account)
    {
        await using var cmd=Sql.Cmd(c,"""
            DELETE FROM public_channel_reactions r USING public_channel_posts p
            WHERE r.post_seq=p.seq AND r.user_id=$1 AND p.channel_id=$2
            """,account,channel);
        await cmd.ExecuteNonQueryAsync();
    }

    private static Task<IResult> PutReaction(Guid id,long seq,PostReaction input,HttpContext ctx,NpgsqlDataSource db) =>
        ChangeReaction(id,seq,input.Kind,ctx,db,remove:false);

    private static Task<IResult> DeleteReaction(Guid id,long seq,HttpContext ctx,NpgsqlDataSource db) =>
        ChangeReaction(id,seq,null,ctx,db,remove:true);

    private static async Task<IResult> ChangeReaction(Guid id,long seq,string? kind,HttpContext ctx,NpgsqlDataSource db,bool remove)
    {
        var actor=await Sql.Authenticate(ctx,db);
        if(!remove && kind is not ("like" or "heart" or "smile"))
            throw new ApiError(400,"INVALID_CHANNEL_REACTION");
        await using var c=await db.OpenConnectionAsync(ctx.RequestAborted);
        await using var tx=await c.BeginTransactionAsync(ctx.RequestAborted);
        await LockAccount(c,actor);
        var access=await Access(c,id,actor);
        if(!access.Owner && !access.Subscribed) throw new ApiError(403,"CHANNEL_SUBSCRIPTION_REQUIRED");
        await using(var post=Sql.Cmd(c,"""
            SELECT 1 FROM public_channel_posts WHERE channel_id=$1 AND seq=$2 AND body IS NOT NULL FOR UPDATE
            """,id,seq))
            if(await post.ExecuteScalarAsync(ctx.RequestAborted) is null)
                throw new ApiError(404,"CHANNEL_POST_NOT_FOUND");

        var current=await ReadPostReactions(c,seq,actor.UserId);
        if(current.Mine==kind) return Results.Ok(current);

        if(remove)
        {
            await using var delete=Sql.Cmd(c,"DELETE FROM public_channel_reactions WHERE post_seq=$1 AND user_id=$2",seq,actor.UserId);
            await delete.ExecuteNonQueryAsync(ctx.RequestAborted);
        }
        else
        {
            if(current.Mine is null &&
                (current.Like+current.Heart+current.Smile>=ReactionLimit ||
                 await Count(c,"SELECT count(*) FROM public_channel_reactions WHERE user_id=$1",actor.UserId)>=ReactionLimit))
                throw new ApiError(409,"CHANNEL_REACTION_QUOTA");
            await Charge(c,actor.UserId,"reaction",240);
            await using var update=Sql.Cmd(c,"""
                INSERT INTO public_channel_reactions(post_seq,user_id,kind) VALUES($1,$2,$3)
                ON CONFLICT(post_seq,user_id) DO UPDATE SET kind=excluded.kind
                """,seq,actor.UserId,kind!);
            await update.ExecuteNonQueryAsync(ctx.RequestAborted);
        }

        var result=await ReadPostReactions(c,seq,actor.UserId);
        await tx.CommitAsync(ctx.RequestAborted);
        return Results.Ok(result);
    }

    private static async Task<IResult> RemovePost(Guid id,long seq,HttpContext ctx,NpgsqlDataSource db)
    {
        var a=await Sql.Authenticate(ctx,db);
        await using var c=await db.OpenConnectionAsync();await using var tx=await c.BeginTransactionAsync();
        await LockAccount(c,a);
        if(!(await Access(c,id,a,true)).Owner)throw new ApiError(403,"CHANNEL_OWNER_REQUIRED");
        await using var cmd=Sql.Cmd(c,"UPDATE public_channel_posts SET body=NULL,deleted_at=now() WHERE channel_id=$1 AND seq=$2 AND body IS NOT NULL",id,seq);
        if(await cmd.ExecuteNonQueryAsync()!=0)
        {
            await using (var clear=Sql.Cmd(c,"UPDATE channel_catalog SET pinned_seq=NULL,pin_revision=pin_revision+1 WHERE id=$1 AND pinned_seq=$2",id,seq))
                await clear.ExecuteNonQueryAsync();
            await using (var comments=Sql.Cmd(c,"DELETE FROM public_channel_comments WHERE post_seq=$1",seq))
                await comments.ExecuteNonQueryAsync();
            await using var reactions=Sql.Cmd(c,"DELETE FROM public_channel_reactions WHERE post_seq=$1",seq);
            await reactions.ExecuteNonQueryAsync();
        }
        await tx.CommitAsync();return Results.NoContent();
    }
}
