using Microsoft.EntityFrameworkCore;
using Npgsql;
using SecureMesh;

var builder = WebApplication.CreateBuilder(args);
// Transport is loopback-only in development. Public TLS belongs to a future deployment.
if (!builder.Environment.IsDevelopment())
    throw new InvalidOperationException("LOCAL_ALPHA_ONLY: production startup disabled until release gates pass.");
builder.WebHost.ConfigureKestrel(o => o.Limits.MaxRequestBodySize = 131072);
builder.Logging.ClearProviders();
builder.Logging.AddJsonConsole();
builder.Logging.AddFilter("Microsoft.AspNetCore", LogLevel.Warning);
builder.Logging.AddFilter("Microsoft.EntityFrameworkCore", LogLevel.Warning);
var connection = builder.Configuration.GetConnectionString("Database")
    ?? throw new InvalidOperationException("ConnectionStrings__Database required");
builder.Services.AddDbContext<MeshDb>(o => o.UseNpgsql(connection));
builder.Services.AddSingleton(NpgsqlDataSource.Create(connection));
var app = builder.Build();
using (var scope = app.Services.CreateScope())
    await scope.ServiceProvider.GetRequiredService<MeshDb>().Database.MigrateAsync();
app.MapGet("/health/live", () => Results.Ok(new { status = "live", productionApproved = false }));
app.MapGet("/health/ready", async (NpgsqlDataSource db) =>
{
    try { await using var cmd = db.CreateCommand("SELECT 1"); await cmd.ExecuteScalarAsync(); return Results.Ok(new { status = "ready" }); }
    catch (NpgsqlException) { return Results.StatusCode(503); }
});
app.Run();
