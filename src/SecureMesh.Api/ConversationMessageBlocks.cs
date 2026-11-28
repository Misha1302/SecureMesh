using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;
using Npgsql;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611280114_ConversationMessageBlocks")]
public sealed class ConversationMessageBlocksMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        CREATE TABLE conversation_message_blocks (
            conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            owner_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            PRIMARY KEY (conversation_id,owner_id)
        );
        CREATE INDEX conversation_message_blocks_owner ON conversation_message_blocks(owner_id);
        """);

    protected override void Down(MigrationBuilder migrationBuilder) =>
        throw new NotSupportedException("Preserve established conversation blocking preferences.");
}

public static class ConversationMessageBlocks
{
    public static void MapConversationMessageBlocks(this WebApplication app)
    {
        const string route = "/v1/conversations/{group:guid}/message-block";
        app.MapGet(route, (Guid group, HttpContext ctx, NpgsqlDataSource db) => Control(group, null, ctx, db));
        app.MapPut(route, (Guid group, HttpContext ctx, NpgsqlDataSource db) => Control(group, true, ctx, db));
        var unblock = app.MapDelete(route, (Guid group, HttpContext ctx, NpgsqlDataSource db) => Control(group, false, ctx, db));
        if (app.Configuration["BrowserClientOrigin"] is not null) unblock.RequireCors("BrowserContactUnblock");
    }

    // Caller already holds the conversation gate. Never consume a sequence or
    // advance the MLS epoch for an envelope rejected by this delivery barrier.
    internal static async Task RequireOpen(NpgsqlConnection c, Guid group, CancellationToken ct)
    {
        await using var cmd = Sql.Cmd(c,
            "SELECT EXISTS(SELECT 1 FROM conversation_message_blocks WHERE conversation_id=$1)", group);
        if (await cmd.ExecuteScalarAsync(ct) is true)
            throw new ApiError(409, "CONVERSATION_MESSAGES_BLOCKED");
    }

    private static async Task<IResult> Control(Guid group, bool? block, HttpContext ctx, NpgsqlDataSource db)
    {
        var actor = await Sql.Authenticate(ctx, db);
        var ct = ctx.RequestAborted;
        await using var c = await db.OpenConnectionAsync(ct);
        await using var tx = await c.BeginTransactionAsync(ct);
        await Sql.LockTrustedDeliverySession(c, actor, ct);
        await using (var gate = Sql.Cmd(c, "SELECT account_removed FROM conversations WHERE id=$1 FOR UPDATE", group))
            if (await gate.ExecuteScalarAsync(ct) is not false)
                throw new ApiError(404, "MESSAGE_BLOCK_UNAVAILABLE");
        await using (var eligible = Sql.Cmd(c, """
            SELECT 1 FROM conversation_bootstraps b
            JOIN conversation_devices m ON m.conversation_id=b.conversation_id AND m.device_id=$2
            WHERE b.conversation_id=$1 AND b.received
            AND (SELECT count(DISTINCT d.user_id) FROM conversation_devices all_devices
                 JOIN devices d ON d.id=all_devices.device_id WHERE all_devices.conversation_id=$1)=2
            """, group, actor.DeviceId))
            if (await eligible.ExecuteScalarAsync(ct) is null)
                throw new ApiError(404, "MESSAGE_BLOCK_UNAVAILABLE");

        if (block.HasValue)
        {
            var mutation = block.Value
                ? "INSERT INTO conversation_message_blocks VALUES($1,$2) ON CONFLICT DO NOTHING"
                : "DELETE FROM conversation_message_blocks WHERE conversation_id=$1 AND owner_id=$2";
            await using var cmd = Sql.Cmd(c, mutation, group, actor.UserId);
            await cmd.ExecuteNonQueryAsync(ct);
        }

        bool blockedByYou, paused;
        await using (var status = Sql.Cmd(c, """
            SELECT coalesce(bool_or(owner_id=$2),false), count(*)>0
            FROM conversation_message_blocks WHERE conversation_id=$1
            """, group, actor.UserId))
        await using (var row = await status.ExecuteReaderAsync(ct))
        {
            await row.ReadAsync(ct);
            blockedByYou = row.GetBoolean(0);
            paused = row.GetBoolean(1);
        }
        await tx.CommitAsync(ct);
        return Results.Ok(new { blockedByYou, paused });
    }
}
