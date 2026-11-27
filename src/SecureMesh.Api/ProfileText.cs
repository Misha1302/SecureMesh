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

public sealed record ProfileTextUpdate(
    [property: JsonRequired] string? Bio,
    [property: JsonRequired] string? Status,
    [property: JsonRequired] long Revision);

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
            await using var cmd = Sql.Cmd(c, "SELECT bio, profile_status, profile_text_revision FROM users WHERE id=$1", actor.UserId);
            await using var row = await cmd.ExecuteReaderAsync(ctx.RequestAborted);
            if (!await row.ReadAsync(ctx.RequestAborted)) throw new ApiError(401, "AUTH_REQUIRED");
            return Results.Ok(new {
                bio = row.IsDBNull(0) ? null : row.GetString(0),
                status = row.IsDBNull(1) ? null : row.GetString(1), revision = row.GetInt64(2)
            });
        });

        app.MapPut("/v1/users/me/profile-text", async (ProfileTextUpdate input, HttpContext ctx, NpgsqlDataSource db) =>
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
                UPDATE users SET bio=NULLIF($2,''),profile_status=NULLIF($3,''),
                    profile_text_revision=profile_text_revision + CASE
                      WHEN (bio,profile_status) IS DISTINCT FROM (NULLIF($2,''),NULLIF($3,'')) THEN 1 ELSE 0 END
                WHERE id=$1 AND (profile_text_revision=$4 OR
                    (bio,profile_status) IS NOT DISTINCT FROM (NULLIF($2,''),NULLIF($3,'')))
                RETURNING profile_text_revision
                """, actor.UserId, bio, status, input.Revision);
            var revision = await cmd.ExecuteScalarAsync(ctx.RequestAborted);
            if (revision is null) throw new ApiError(409, "PROFILE_CHANGED");
            await tx.CommitAsync(ctx.RequestAborted);
            return Results.Ok(new { bio = bio.Length == 0 ? null : bio, status = status.Length == 0 ? null : status, revision = (long)revision });
        });

        app.MapGet("/v1/conversations/{id:guid}/profile-text/{peer:guid}", async (Guid id, Guid peer, HttpContext ctx, NpgsqlDataSource db) =>
        {
            var actor = await Sql.Authenticate(ctx, db);
            await using var c = await db.OpenConnectionAsync(ctx.RequestAborted);
            // Scope disclosure to an established one-to-one conversation and its
            // specific peer device. A username, account id or outstanding invite is insufficient.
            await using var cmd = Sql.Cmd(c, """
                SELECT u.bio,u.profile_status FROM conversation_devices own
                JOIN members m ON m.conversation_id=own.conversation_id AND m.device_id=$3
                JOIN devices d ON d.id=m.device_id AND d.trusted AND NOT d.revoked
                JOIN users u ON u.id=d.user_id AND u.id<>$4
                JOIN conversation_bootstraps b ON b.conversation_id=own.conversation_id AND b.received
                WHERE own.device_id=$1 AND own.conversation_id=$2
                  AND (SELECT count(*) FROM members WHERE conversation_id=$2)=2
                """, actor.DeviceId, id, peer, actor.UserId);
            await using var row = await cmd.ExecuteReaderAsync(ctx.RequestAborted);
            if (!await row.ReadAsync(ctx.RequestAborted)) throw new ApiError(404, "PROFILE_NOT_FOUND");
            return Results.Ok(new { bio = row.IsDBNull(0) ? null : row.GetString(0), status = row.IsDBNull(1) ? null : row.GetString(1) });
        });
    }
}
