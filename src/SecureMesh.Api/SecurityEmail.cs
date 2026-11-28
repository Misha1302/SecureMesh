using Npgsql;

namespace SecureMesh;

internal sealed record SecurityEmailPreference(bool? Enabled);

internal static class SecurityEmail
{
    internal const string NewDevice = "trusted_device_connected";
    internal const string RefreshReuse = "rotated_refresh_reused";

    internal static void MapSecurityEmail(this WebApplication app)
    {
        const string path = "/v1/users/me/security-email";
        app.MapGet(path, async (HttpContext ctx, NpgsqlDataSource db) =>
        {
            var actor = await Sql.Authenticate(ctx, db);
            await using var c = await db.OpenConnectionAsync(ctx.RequestAborted);
            await using var tx = await c.BeginTransactionAsync(ctx.RequestAborted);
            await Sql.LockTrustedDeliverySession(c, actor, ctx.RequestAborted);
            await using var query = Sql.Cmd(c, "SELECT security_email_enabled FROM users WHERE id=$1", actor.UserId);
            var enabled = (bool)(await query.ExecuteScalarAsync(ctx.RequestAborted))!;
            await tx.CommitAsync(ctx.RequestAborted);
            return Results.Ok(new { enabled });
        });
        app.MapPut(path, async (SecurityEmailPreference input, HttpContext ctx, NpgsqlDataSource db) =>
        {
            var actor = await Sql.Authenticate(ctx, db);
            if (input.Enabled is not bool enabled) throw new ApiError(400, "INVALID_PREFERENCE");
            await using var c = await db.OpenConnectionAsync(ctx.RequestAborted);
            await using var tx = await c.BeginTransactionAsync(ctx.RequestAborted);
            await Sql.LockTrustedProfileOwner(c, actor, ctx.RequestAborted);
            await using var query = Sql.Cmd(c, "UPDATE users SET security_email_enabled=$2 WHERE id=$1", actor.UserId, enabled);
            await query.ExecuteNonQueryAsync(ctx.RequestAborted);
            if (!enabled)
            {
                await using var cancel = Sql.Cmd(c, "DELETE FROM verification_email_queue WHERE security_owner=$1", actor.UserId);
                await cancel.ExecuteNonQueryAsync(ctx.RequestAborted);
            }
            await tx.CommitAsync(ctx.RequestAborted);
            return Results.Ok(new { enabled });
        });
    }
}
