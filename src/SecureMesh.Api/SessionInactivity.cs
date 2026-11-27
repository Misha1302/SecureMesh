using System.Globalization;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;
using Npgsql;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611270018_SessionInactivity")]
public sealed class SessionInactivityMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        ALTER TABLE sessions
          ADD COLUMN last_interactive_at timestamptz NOT NULL DEFAULT now(),
          ADD COLUMN idle_timeout_days smallint DEFAULT 7 CHECK (idle_timeout_days IN (1,3,7,14,30,90));
        CREATE FUNCTION session_idle_deadline(last_activity timestamptz, idle_days smallint)
            RETURNS timestamptz LANGUAGE SQL STABLE STRICT
            RETURN last_activity + idle_days * interval '24 hours';
        CREATE FUNCTION session_idle_active(last_activity timestamptz, idle_days smallint)
            RETURNS boolean LANGUAGE SQL STABLE
            RETURN idle_days IS NULL OR session_idle_deadline(last_activity, idle_days) > statement_timestamp();
        """);

    protected override void Down(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        DROP FUNCTION session_idle_active(timestamptz, smallint);
        DROP FUNCTION session_idle_deadline(timestamptz, smallint);
        ALTER TABLE sessions DROP COLUMN last_interactive_at, DROP COLUMN idle_timeout_days;
        """);
}

public sealed record SessionInactivityUpdate(string? IdleTimeout);

public static class SessionInactivity
{
    public static void MapSessionInactivity(this WebApplication app)
    {
        app.MapGet("/v1/auth/session/inactivity", async (HttpContext ctx, NpgsqlDataSource db) =>
        {
            var actor = await Sql.Authenticate(ctx, db);
            await using var c = await db.OpenConnectionAsync(ctx.RequestAborted);
            await using var cmd = Sql.Cmd(c, """
                SELECT idle_timeout_days, session_idle_deadline(last_interactive_at,idle_timeout_days)
                FROM sessions WHERE id=$1
                """, actor.SessionId);
            return await ReadPolicy(cmd, ctx.RequestAborted);
        });
        app.MapPut("/v1/auth/session/inactivity", async (SessionInactivityUpdate input, HttpContext ctx, NpgsqlDataSource db) =>
        {
            var actor = await Sql.Authenticate(ctx, db);
            short? days = input.IdleTimeout switch
            {
                "1" => 1, "3" => 3, "7" => 7, "14" => 14, "30" => 30, "90" => 90, "never" => null,
                _ => throw new ApiError(400, "INVALID_IDLE_TIMEOUT"),
            };
            return await RecordActivity(ctx, db, actor, updatePolicy: true, days: days);
        });
        app.MapPost("/v1/auth/session/activity", async (HttpContext ctx, NpgsqlDataSource db) =>
        {
            var actor = await Sql.Authenticate(ctx, db);
            return await RecordActivity(ctx, db, actor, updatePolicy: false, days: null);
        });
    }

    private static async Task<IResult> RecordActivity(HttpContext ctx, NpgsqlDataSource db, Actor actor, bool updatePolicy, short? days)
    {
        await using var c = await db.OpenConnectionAsync(ctx.RequestAborted);
        await using var cmd = Sql.Cmd(c, """
            UPDATE sessions s SET last_interactive_at=greatest(s.last_interactive_at,statement_timestamp()),
                idle_timeout_days=CASE WHEN $2 THEN $3::smallint ELSE s.idle_timeout_days END
            FROM devices d
            WHERE s.id=$1 AND d.id=s.device_id AND d.trusted AND NOT d.revoked
                AND NOT s.revoked AND NOT s.used AND s.expires_at>statement_timestamp()
                AND session_idle_active(s.last_interactive_at,s.idle_timeout_days)
            RETURNING s.idle_timeout_days, session_idle_deadline(s.last_interactive_at,s.idle_timeout_days)
            """, actor.SessionId, updatePolicy, (object?)days ?? DBNull.Value);
        return await ReadPolicy(cmd, ctx.RequestAborted);
    }

    private static async Task<IResult> ReadPolicy(NpgsqlCommand cmd, CancellationToken cancellationToken)
    {
        await using var r = await cmd.ExecuteReaderAsync(cancellationToken);
        if (!await r.ReadAsync(cancellationToken)) throw new ApiError(401, "AUTH_REQUIRED");
        var idleTimeout = r.IsDBNull(0) ? "never" : r.GetInt16(0).ToString(CultureInfo.InvariantCulture);
        var idleExpiresAt = r.IsDBNull(1) ? (DateTime?)null : r.GetDateTime(1);
        return Results.Ok(new { idleTimeout, idleExpiresAt });
    }
}
