using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;
using SecureMesh;

// Owned fixture utility, intentionally restricted to the previous schema.
var connection = Environment.GetEnvironmentVariable("SECUREMESH_TEST_DATABASE")
    ?? throw new InvalidOperationException("Owned database connection required");
using var db = new MeshDb(new DbContextOptionsBuilder<MeshDb>().UseNpgsql(connection).Options);
const string previous = "202611190006_EnrollmentIssuanceQuota";
// Historical project IDs use a shorter timestamp than EF's ID recognizer;
// resolve their name through EF rather than inventing/down-migrating a schema.
var name = db.GetService<IMigrationsIdGenerator>().GetName(previous);
await db.GetService<IMigrator>().MigrateAsync(name);
Console.WriteLine("Previous six-migration schema created by real EF migrator.");
