using System.Text.RegularExpressions;
using Npgsql;

namespace SecureMesh;

internal static class ContactBlocks
{
    internal static void MapContactBlocks(this WebApplication app)
    {
        var routes = app.MapGroup("/v1/contact-blocks");
        routes.MapGet("", async (HttpContext ctx, NpgsqlDataSource db) =>
        {
            var actor = await Sql.Authenticate(ctx, db);
            await using var c = await db.OpenConnectionAsync(ctx.RequestAborted);
            await using var tx = await c.BeginTransactionAsync(ctx.RequestAborted);
            await Sql.LockTrustedDeliverySession(c, actor, ctx.RequestAborted);
            await using var command = Sql.Cmd(c, """
                SELECT u.username FROM contact_blocks b JOIN users u ON u.id=b.blocked_id
                WHERE b.owner_id=$1 ORDER BY u.username
                """, actor.UserId);
            var items = new List<string>();
            await using (var rows = await command.ExecuteReaderAsync(ctx.RequestAborted))
            {
                while (await rows.ReadAsync(ctx.RequestAborted)) items.Add(rows.GetString(0));
            }
            await tx.CommitAsync(ctx.RequestAborted);
            return Results.Ok(new { items });
        });
        routes.MapPut("/{username}", (string username, HttpContext ctx, NpgsqlDataSource db) =>
            SetAsync(username, ctx, db, block: true));
        var unblock = routes.MapDelete("/{username}", (string username, HttpContext ctx, NpgsqlDataSource db) =>
            SetAsync(username, ctx, db, block: false));
        if (app.Configuration["BrowserClientOrigin"] is not null) unblock.RequireCors("BrowserContactUnblock");
    }

    private static async Task<IResult> SetAsync(string username, HttpContext ctx, NpgsqlDataSource db, bool block)
    {
        var actor = await Sql.Authenticate(ctx, db);
        if (!Regex.IsMatch(username, "^[a-z0-9_]{3,32}$"))
            throw new ApiError(400, "INVALID_CONTACT_USERNAME");

        var ct = ctx.RequestAborted;
        await using var c = await db.OpenConnectionAsync(ct);
        await using var tx = await c.BeginTransactionAsync(ct);
        await using var lookup = Sql.Cmd(c, "SELECT id FROM users WHERE username=$1 AND verified", username);
        if (await lookup.ExecuteScalarAsync(ct) is not Guid target)
        {
            if (!block) return Results.NoContent();
            throw new ApiError(404, "USER_NOT_FOUND");
        }
        if (target == actor.UserId) throw new ApiError(400, "SELF_BLOCK_NOT_SUPPORTED");

        // Use the same sorted account locks as invitation creation.
        await using var pairLock = Sql.Cmd(c, "SELECT id FROM users WHERE id=ANY($1) ORDER BY id FOR UPDATE",
            new[] { actor.UserId, target });
        await pairLock.ExecuteNonQueryAsync(ct);
        await Sql.LockTrustedDeliverySession(c, actor, ct);
        if (block)
        {
            await using var insert = Sql.Cmd(c, """
                INSERT INTO contact_blocks(owner_id,blocked_id)
                SELECT $1,$2 WHERE (SELECT count(*) FROM contact_blocks WHERE owner_id=$1) < 500
                ON CONFLICT DO NOTHING
                """, actor.UserId, target);
            if (await insert.ExecuteNonQueryAsync(ct) == 0)
            {
                await using var current = Sql.Cmd(c,
                    "SELECT 1 FROM contact_blocks WHERE owner_id=$1 AND blocked_id=$2", actor.UserId, target);
                if (await current.ExecuteScalarAsync(ct) is null)
                    throw new ApiError(429, "CONTACT_BLOCK_LIMIT");
            }

            // Keep IDs for retry deduplication. Accepted invitations and conversations stay usable.
            await using var expire = Sql.Cmd(c, """
                UPDATE chat_requests q SET expires_at=LEAST(q.expires_at,statement_timestamp())
                FROM devices sender WHERE q.sender_device=sender.id AND sender.user_id=$2
                  AND q.recipient_user=$1 AND q.recipient_device IS NULL AND q.expires_at>statement_timestamp()
                """, actor.UserId, target);
            await expire.ExecuteNonQueryAsync(ct);
        }
        else
        {
            await using var remove = Sql.Cmd(c, "DELETE FROM contact_blocks WHERE owner_id=$1 AND blocked_id=$2",
                actor.UserId, target);
            await remove.ExecuteNonQueryAsync(ct);
        }

        await tx.CommitAsync(ct);
        return Results.NoContent();
    }
}
