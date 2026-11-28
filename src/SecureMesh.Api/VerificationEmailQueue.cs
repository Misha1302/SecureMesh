using System.Security.Cryptography;
using Microsoft.AspNetCore.DataProtection;
using Npgsql;

namespace SecureMesh;

internal sealed class VerificationEmailQueue(
    NpgsqlDataSource db,
    IDataProtectionProvider protection,
    VerificationEmail sender,
    ILogger<VerificationEmailQueue> logger) : BackgroundService
{
    private const int MaxAttempts = 5;
    private readonly IDataProtector protector = protection.CreateProtector("SecureMesh.VerificationEmail.v1");

    public async Task EnqueueAsync(NpgsqlConnection connection, byte[] hash, string recipient,
        string token, CancellationToken cancellationToken)
    {
        // The address has passed MailAddress validation and cannot contain a newline.
        var payload = protector.Protect(recipient + "\n" + token);
        await using var command = Sql.Cmd(connection, """
            INSERT INTO verification_email_queue(token_hash,payload,expires_at)
            SELECT hash,$2,expires_at FROM email_tokens WHERE hash=$1
            """, hash, payload);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                if (await DeliverNextAsync(stoppingToken)) continue;
            }
            catch (NpgsqlException) when (!stoppingToken.IsCancellationRequested)
            {
                logger.LogWarning("Verification email queue storage unavailable.");
            }

            await Task.Delay(TimeSpan.FromMilliseconds(500), stoppingToken);
        }
    }

    private async Task<bool> DeliverNextAsync(CancellationToken cancellationToken)
    {
        // Commit the lease before SMTP. An interrupted attempt can be retried after the lease expires.
        await using var claim = db.CreateCommand("""
            WITH candidate AS (
                SELECT token_hash FROM verification_email_queue
                WHERE next_attempt_at <= now() AND expires_at > now() AND attempts < $1
                ORDER BY next_attempt_at LIMIT 1 FOR UPDATE SKIP LOCKED
            )
            UPDATE verification_email_queue q
            SET attempts=q.attempts+1, next_attempt_at=now()+interval '30 seconds'
            FROM candidate WHERE q.token_hash=candidate.token_hash
            RETURNING q.token_hash,q.payload,q.attempts
            """);
        claim.Parameters.AddWithValue(MaxAttempts);
        byte[] hash;
        string payload;
        int attempt;
        await using (var result = await claim.ExecuteReaderAsync(cancellationToken))
        {
            if (!await result.ReadAsync(cancellationToken))
            {
                await result.DisposeAsync();
                await using var cleanup = db.CreateCommand("""
                    DELETE FROM verification_email_queue
                    WHERE expires_at <= now() OR (attempts >= $1 AND next_attempt_at <= now())
                    """);
                cleanup.Parameters.AddWithValue(MaxAttempts);
                await cleanup.ExecuteNonQueryAsync(cancellationToken);
                return false;
            }

            hash = result.GetFieldValue<byte[]>(0);
            payload = result.GetString(1);
            attempt = result.GetInt32(2);
        }

        try
        {
            var parts = protector.Unprotect(payload).Split('\n', 2);
            await sender.SendAsync(parts[0], parts[1], cancellationToken);
        }
        catch (ApiError)
        {
            logger.LogWarning("Verification email delivery attempt failed.");
            return true;
        }
        catch (CryptographicException)
        {
            logger.LogWarning("Verification email payload could not be decrypted.");
        }

        await using var complete = db.CreateCommand("""
            DELETE FROM verification_email_queue WHERE token_hash=$1 AND attempts=$2
            """);
        complete.Parameters.AddWithValue(hash);
        complete.Parameters.AddWithValue(attempt);
        await complete.ExecuteNonQueryAsync(cancellationToken);
        return true;
    }
}
