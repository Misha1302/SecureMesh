using System.Globalization;
using System.Text;
using System.Text.Json.Serialization;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;
using Npgsql;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611270015_ProfileText")]
public sealed class ProfileTextMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        ALTER TABLE users
            ADD COLUMN bio text CHECK (char_length(bio) BETWEEN 1 AND 280),
            ADD COLUMN profile_status text CHECK (char_length(profile_status) BETWEEN 1 AND 80),
            ADD COLUMN profile_text_revision bigint NOT NULL DEFAULT 0 CHECK (profile_text_revision >= 0);
        """);

    protected override void Down(MigrationBuilder migrationBuilder) =>
        throw new NotSupportedException("Older clients can retain this additive schema.");
}

[DbContext(typeof(MeshDb))]
[Migration("202611280111_ProfileTextVisibility")]
public sealed class ProfileTextVisibilityMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) =>
        migrationBuilder.Sql("ALTER TABLE users ADD COLUMN profile_text_visible boolean NOT NULL DEFAULT true");

    protected override void Down(MigrationBuilder migrationBuilder) =>
        throw new NotSupportedException("Removing visibility would expose hidden profile text.");
}

public sealed record ProfileTextUpdate(
    [property: JsonRequired] string? Bio,
    [property: JsonRequired] string? Status,
    [property: JsonRequired] long Revision, bool? VisibleToPeers = null);

public static class ProfileText
{
    private static string Normalize(string? input, int limit, bool multiline)
    {
        if (input is null) return "";
        if (input.Length > 4096) throw new ApiError(400, "INVALID_PROFILE_TEXT");
        var value = input.Replace("\r\n", "\n").Normalize(NormalizationForm.FormC);
        foreach (var rune in value.EnumerateRunes())
        {
            var category = Rune.GetUnicodeCategory(rune);
            if (multiline && rune.Value == '\n') continue;
            if (category is UnicodeCategory.Control or UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator ||
                (category == UnicodeCategory.Format && rune.Value is not (0x200C or 0x200D)))
                throw new ApiError(400, "INVALID_PROFILE_TEXT");
        }
        value = value.Trim();
        if (value.EnumerateRunes().Count() > limit ||
            (value.Length > 0 && value.EnumerateRunes().All(rune => Rune.GetUnicodeCategory(rune) is
                UnicodeCategory.Format or UnicodeCategory.NonSpacingMark or UnicodeCategory.EnclosingMark or UnicodeCategory.SpaceSeparator or UnicodeCategory.Control)))
            throw new ApiError(400, "INVALID_PROFILE_TEXT");
        return value;
    }

    public static void MapProfileText(this WebApplication app)
    {
        app.MapGet("/v1/users/me/profile-text", async (HttpContext ctx, NpgsqlDataSource db) =>
        {
            var actor = await Sql.Authenticate(ctx, db);
            await using var c = await db.OpenConnectionAsync(ctx.RequestAborted);
            await using var tx = await c.BeginTransactionAsync(ctx.RequestAborted);
            await Sql.LockTrustedProfileOwner(c, actor, ctx.RequestAborted);
            await using var cmd = Sql.Cmd(c, "SELECT bio, profile_status, profile_text_revision, profile_text_visible FROM users WHERE id=$1", actor.UserId);
            IResult result;
            await using (var row = await cmd.ExecuteReaderAsync(ctx.RequestAborted))
            {
                if (!await row.ReadAsync(ctx.RequestAborted)) throw new ApiError(401, "AUTH_REQUIRED");
                result = Results.Ok(new {
                    bio = row.IsDBNull(0) ? null : row.GetString(0),
                    status = row.IsDBNull(1) ? null : row.GetString(1),
                    revision = row.GetInt64(2), visibleToPeers = row.GetBoolean(3)
                });
            }
            await tx.CommitAsync(ctx.RequestAborted);
            return result;
        });

        static async Task<IResult> Save(ProfileTextUpdate input, HttpContext ctx, NpgsqlDataSource db)
        {
            var actor = await Sql.Authenticate(ctx, db);
            if (input.Revision < 0) throw new ApiError(400, "INVALID_PROFILE_REVISION");
            var bio = Normalize(input.Bio, 280, true);
            var status = Normalize(input.Status, 80, false);
            await using var c = await db.OpenConnectionAsync(ctx.RequestAborted);
            await using var tx = await c.BeginTransactionAsync(ctx.RequestAborted);
            await Sql.LockTrustedProfileOwner(c, actor, ctx.RequestAborted);
            // Same-data retries are safe even if the original acknowledgement was lost.
            await using var cmd = Sql.Cmd(c, """
                WITH desired AS (
                    SELECT NULLIF($2,'') AS bio, NULLIF($3,'') AS status,
                           CASE WHEN $5 THEN $6 ELSE profile_text_visible END AS visible
                    FROM users WHERE id=$1
                )
                UPDATE users u SET bio=d.bio, profile_status=d.status, profile_text_visible=d.visible,
                    profile_text_revision=u.profile_text_revision + CASE
                      WHEN (u.bio,u.profile_status,u.profile_text_visible) IS DISTINCT FROM (d.bio,d.status,d.visible) THEN 1 ELSE 0 END
                FROM desired d WHERE u.id=$1 AND (u.profile_text_revision=$4 OR
                    (u.bio,u.profile_status,u.profile_text_visible) IS NOT DISTINCT FROM (d.bio,d.status,d.visible))
                RETURNING u.profile_text_revision,u.profile_text_visible
                """, actor.UserId, bio, status, input.Revision, input.VisibleToPeers.HasValue, input.VisibleToPeers.GetValueOrDefault());
            long revision;
            bool visible;
            await using (var row = await cmd.ExecuteReaderAsync(ctx.RequestAborted))
            {
                if (!await row.ReadAsync(ctx.RequestAborted)) throw new ApiError(409, "PROFILE_CHANGED");
                revision = row.GetInt64(0);
                visible = row.GetBoolean(1);
            }
            await tx.CommitAsync(ctx.RequestAborted);
            return Results.Ok(new { bio = bio.Length == 0 ? null : bio, status = status.Length == 0 ? null : status, revision, visibleToPeers = visible });
        }

        app.MapPut("/v1/users/me/profile-text", Save);
        app.MapPut("/v1/users/me/profile-text/with-visibility", Save);

        app.MapGet("/v1/conversations/{id:guid}/profile-text/{peer:guid}", async (Guid id, Guid peer, HttpContext ctx, NpgsqlDataSource db) =>
        {
            var actor = await Sql.Authenticate(ctx, db);
            await using var c = await db.OpenConnectionAsync(ctx.RequestAborted);
            await using var tx = await c.BeginTransactionAsync(ctx.RequestAborted);
            await Sql.LockTrustedProfileOwner(c, actor, ctx.RequestAborted);
            // Scope disclosure to an established one-to-one conversation and its
            // specific peer device. A username, account id or outstanding invite is insufficient.
            await using var cmd = Sql.Cmd(c, """
                SELECT CASE WHEN visibility.allowed THEN u.bio END,
                       CASE WHEN visibility.allowed THEN u.profile_status END
                FROM conversation_devices own
                JOIN members m ON m.conversation_id=own.conversation_id AND m.device_id=$3
                JOIN devices d ON d.id=m.device_id AND d.trusted AND NOT d.revoked
                JOIN users u ON u.id=d.user_id AND u.id<>$4
                JOIN conversation_bootstraps b ON b.conversation_id=own.conversation_id AND b.received
                CROSS JOIN LATERAL (
                    SELECT u.profile_text_visible AND NOT EXISTS (
                      SELECT 1 FROM contact_blocks WHERE (owner_id,blocked_id) IN ((u.id,$4),($4,u.id))
                    ) AS allowed
                ) visibility
                WHERE own.device_id=$1 AND own.conversation_id=$2
                  AND (SELECT count(*) FROM members WHERE conversation_id=$2)=2
                """, actor.DeviceId, id, peer, actor.UserId);
            IResult result;
            await using (var row = await cmd.ExecuteReaderAsync(ctx.RequestAborted))
            {
                if (!await row.ReadAsync(ctx.RequestAborted)) throw new ApiError(404, "PROFILE_NOT_FOUND");
                result = Results.Ok(new { bio = row.IsDBNull(0) ? null : row.GetString(0), status = row.IsDBNull(1) ? null : row.GetString(1) });
            }
            await tx.CommitAsync(ctx.RequestAborted);
            return result;
        });
    }
}
