using Npgsql;

namespace SecureMesh;

public static partial class PublicChannels
{
    private static async Task<ChannelAccess> CommentAccess(NpgsqlConnection c, Guid id, long seq, Actor actor, bool write)
    {
        await LockAccount(c, actor);
        var access = await Access(c, id, actor);
        if (!access.Owner && !access.Subscribed) throw new ApiError(403,"CHANNEL_SUBSCRIPTION_REQUIRED");
        var lockMode = write ? "FOR UPDATE" : "FOR SHARE";
        await using var post = Sql.Cmd(c,$"SELECT seq FROM public_channel_posts WHERE channel_id=$1 AND seq=$2 AND body IS NOT NULL {lockMode}",id,seq);
        if (await post.ExecuteScalarAsync() is null) throw new ApiError(404,"CHANNEL_POST_NOT_FOUND");
        return access;
    }

    private static async Task<IResult> ListComments(Guid id,long seq,long? before,HttpContext ctx,NpgsqlDataSource db)
    {
        var actor = await Sql.Authenticate(ctx,db);
        if (before <= 0) throw new ApiError(400,"INVALID_CHANNEL_CURSOR");
        await using var c = await db.OpenConnectionAsync(ctx.RequestAborted);
        await using var tx = await c.BeginTransactionAsync(ctx.RequestAborted);
        var access = await CommentAccess(c,id,seq,actor,false);
        await using var cmd = Sql.Cmd(c,"""
            SELECT cm.id,cm.body,u.username,cm.user_id=$3 FROM public_channel_comments cm
            JOIN users u ON u.id=cm.user_id WHERE cm.post_seq=$1 AND cm.id<$2 AND cm.body IS NOT NULL
            ORDER BY cm.id DESC LIMIT 17
            """,seq,before??long.MaxValue,actor.UserId);
        var items = new List<object>();
        long? last=null, next=null;
        await using (var r = await cmd.ExecuteReaderAsync(ctx.RequestAborted))
            while (await r.ReadAsync(ctx.RequestAborted))
            {
                if (items.Count==16) { next=last; break; }
                last=r.GetInt64(0);
                items.Add(new { id=last, body=r.GetString(1), username=r.GetString(2), canDelete=access.Owner || r.GetBoolean(3) });
            }
        await tx.CommitAsync(ctx.RequestAborted);
        return Results.Ok(new { items,next });
    }

    private static async Task<IResult> AddComment(Guid id,long seq,PostInput input,HttpContext ctx,NpgsqlDataSource db)
    {
        var actor = await Sql.Authenticate(ctx,db);
        var body = Text(input.Body,512,true);
        if (input.RequestId == Guid.Empty) throw new ApiError(400,"INVALID_REQUEST_ID");
        await using var c = await db.OpenConnectionAsync(ctx.RequestAborted);
        await using var tx = await c.BeginTransactionAsync(ctx.RequestAborted);
        await CommentAccess(c,id,seq,actor,true);
        await using (var old=Sql.Cmd(c,"SELECT id,body FROM public_channel_comments WHERE user_id=$1 AND post_seq=$2 AND request_id=$3",actor.UserId,seq,input.RequestId))
        await using (var r=await old.ExecuteReaderAsync())
            if (await r.ReadAsync())
            {
                if (r.IsDBNull(1) || r.GetString(1)!=body) throw new ApiError(409,"CHANNEL_REQUEST_CONFLICT");
                return Results.Ok(new { id=r.GetInt64(0) });
            }
        // Retire tombstones only under the lock that protects their post.
        // An expired tombstone elsewhere cannot consume the author's active quota.
        await using (var purge=Sql.Cmd(c,"DELETE FROM public_channel_comments WHERE post_seq=$1 AND deleted_at < now()-interval '1 day'",seq))
            await purge.ExecuteNonQueryAsync(ctx.RequestAborted);
        await using var quota=Sql.Cmd(c,"""
            SELECT (SELECT count(*) FROM public_channel_comments WHERE post_seq=$1)>=512
                OR (SELECT count(*) FROM public_channel_comments WHERE user_id=$2
                    AND (deleted_at IS NULL OR deleted_at >= now()-interval '1 day'))>=1024
            """,seq,actor.UserId);
        if ((bool)(await quota.ExecuteScalarAsync())!) throw new ApiError(409,"CHANNEL_COMMENT_QUOTA");
        await Charge(c,actor.UserId,"comment",60);
        await using var insert=Sql.Cmd(c,"INSERT INTO public_channel_comments(post_seq,user_id,request_id,body) VALUES($1,$2,$3,$4) RETURNING id",seq,actor.UserId,input.RequestId,body);
        var comment=(long)(await insert.ExecuteScalarAsync())!;
        await tx.CommitAsync(ctx.RequestAborted);
        return Results.Json(new { id=comment }, statusCode:201);
    }

    private static async Task<IResult> DeleteComment(Guid id,long seq,long comment,HttpContext ctx,NpgsqlDataSource db)
    {
        var actor=await Sql.Authenticate(ctx,db);
        await using var c=await db.OpenConnectionAsync(ctx.RequestAborted);
        await using var tx=await c.BeginTransactionAsync(ctx.RequestAborted);
        var access=await CommentAccess(c,id,seq,actor,true);
        await using var cmd=Sql.Cmd(c,"""
            UPDATE public_channel_comments SET body=NULL,deleted_at=coalesce(deleted_at,now())
            WHERE post_seq=$1 AND id=$2 AND (user_id=$3 OR $4)
            """,seq,comment,actor.UserId,access.Owner);
        if (await cmd.ExecuteNonQueryAsync()==0) throw new ApiError(404,"CHANNEL_COMMENT_NOT_FOUND");
        await tx.CommitAsync(ctx.RequestAborted);
        return Results.NoContent();
    }
}
