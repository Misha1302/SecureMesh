using Microsoft.EntityFrameworkCore;
using Npgsql;
using SecureMesh;
using System.Threading.RateLimiting;
using Microsoft.AspNetCore.DataProtection;

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
var stateDirectory=builder.Configuration["StateDirectory"] ?? Path.Combine(Directory.GetCurrentDirectory(),".local");
builder.Services.AddDataProtection().PersistKeysToFileSystem(new DirectoryInfo(Path.Combine(stateDirectory,"cursor-keys")));
builder.Services.AddSingleton(new VerificationEmail(builder.Configuration));
builder.Services.AddSingleton<Delivery>();
builder.Services.AddSingleton<PublicKeyPackageValidator>();
builder.Services.AddRateLimiter(o =>
{
    o.RejectionStatusCode=429;
    o.GlobalLimiter=PartitionedRateLimiter.Create<HttpContext,string>(ctx=>RateLimitPartition.GetTokenBucketLimiter(
        ctx.Connection.RemoteIpAddress?.ToString() ?? "unknown",_=>new TokenBucketRateLimiterOptions {TokenLimit=120,TokensPerPeriod=60,ReplenishmentPeriod=TimeSpan.FromSeconds(10),QueueLimit=0,AutoReplenishment=true}));
});
var app = builder.Build();
using (var scope = app.Services.CreateScope())
    await scope.ServiceProvider.GetRequiredService<MeshDb>().Database.MigrateAsync();
app.Use(async(ctx,next)=>
{
    ctx.Response.Headers["X-Content-Type-Options"]="nosniff";
    ctx.Response.Headers["Cache-Control"]="no-store";
    try {await next(ctx);}
    catch(ApiError e) {ctx.Response.StatusCode=e.Status; await ctx.Response.WriteAsJsonAsync(new {code=e.Code});}
    catch(Exception e) when(e is FormatException or ArgumentException or BadHttpRequestException)
    {ctx.Response.StatusCode=400; await ctx.Response.WriteAsJsonAsync(new {code="INVALID_REQUEST"});}
    catch(NpgsqlException)
    {ctx.Response.StatusCode=503; await ctx.Response.WriteAsJsonAsync(new {code="STORAGE_UNAVAILABLE"});}
});
app.UseRateLimiter();
app.MapIdentity();
app.MapAccountRemoval();
app.MapProfilePhotos();
app.MapPublicChannels();
app.MapPrivateBlobs();
app.MapDeviceTrust();
app.MapMlsDirectory();
Delivery.MapDelivery(app);
app.MapStream();
app.MapGet("/health/live", () => Results.Ok(new { status = "live", productionApproved = false }));
app.MapGet("/health/ready", async (NpgsqlDataSource db) =>
{
    try { await using var cmd = db.CreateCommand("SELECT 1"); await cmd.ExecuteScalarAsync(); return Results.Ok(new { status = "ready" }); }
    catch (NpgsqlException) { return Results.StatusCode(503); }
});
app.Run();
