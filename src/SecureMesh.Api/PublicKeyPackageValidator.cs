using System.Diagnostics;
using System.Text.Json;

namespace SecureMesh;

/// OpenMLS validates public MLS objects for the authentication service. No client store or private keys.
public sealed class PublicKeyPackageValidator(IConfiguration configuration)
{
    private readonly SemaphoreSlim slots = new(2);
    public async Task<byte[]> Validate(byte[] payload, Guid identity, byte[] key, CancellationToken ct)
    {
        if (payload.Length is <1 or >16384) throw new ApiError(400,"INVALID_KEYPACKAGE");
        if (!await slots.WaitAsync(0,ct)) throw new ApiError(429,"KEYPACKAGE_VALIDATOR_BUSY");
        try
        {
            var executable = configuration["KeyPackageValidator"] ?? Path.GetFullPath("src/crypto_core/target/debug/securemesh-crypto");
            using var process = new Process { StartInfo = new ProcessStartInfo(executable) {
                UseShellExecute=false, RedirectStandardInput=true, RedirectStandardOutput=true, RedirectStandardError=true,
                ArgumentList = { "--validate-keypackage" }
            }};
            if (!File.Exists(executable)) throw new ApiError(503,"KEYPACKAGE_VALIDATOR_UNAVAILABLE");
            process.StartInfo.Environment.Clear();
            process.Start();
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(5));
            try
            {
                var output = process.StandardOutput.ReadToEndAsync(timeout.Token);
                var errors = process.StandardError.ReadToEndAsync(timeout.Token);
                await process.StandardInput.WriteAsync(JsonSerializer.Serialize(new {keypackage=Convert.ToBase64String(payload),identity=identity.ToString("D"),public_key=Convert.ToBase64String(key)}).AsMemory(),timeout.Token);
                process.StandardInput.Close();
                await process.WaitForExitAsync(timeout.Token);
                var raw = await output;
                await errors; // Never log input, raw stdout or native diagnostics.
                if (process.ExitCode!=0 || raw.Length>1024) throw new ApiError(400,"INVALID_KEYPACKAGE");
                using var result=JsonDocument.Parse(raw);
                var reference=Convert.FromBase64String(result.RootElement.GetProperty("reference").GetString()!);
                if(reference.Length!=32) throw new ApiError(503,"KEYPACKAGE_VALIDATOR_FAILED");
                return reference;
            }
            catch(OperationCanceledException) { throw new ApiError(503,"KEYPACKAGE_VALIDATOR_TIMEOUT"); }
            finally { if(!process.HasExited) {process.Kill(entireProcessTree:true);await process.WaitForExitAsync(CancellationToken.None);} }
        }
        finally {slots.Release();}
    }
}
