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

    public async Task EnqueueAsync(NpgsqlConnection connection, Guid user, string recipient,
        CancellationToken cancellationToken)
    {
        var token = Sql.Token();
        var hash = Sql.Hash(token);
        // The address has passed MailAddress validation and cannot contain a newline.
        var payload = protector.Protect(recipient + "\n" + token);
        await using var command = Sql.Cmd(connection, """
            WITH created AS (
                INSERT INTO email_tokens VALUES($1,$2,now()+interval '30 minutes')
                RETURNING hash,expires_at
            )
            INSERT INTO verification_email_queue(token_hash,payload,expires_at)
            SELECT hash,$3,expires_at FROM created
            """, hash, user, payload);
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
        // Reserve one provider attempt in the same statement as the queue lease.
        // The reservation covers failures and process loss so retries also count against the cap.
        await using var claim = db.CreateCommand("""
            WITH candidate AS (
                SELECT token_hash FROM verification_email_queue
                WHERE next_attempt_at <= now() AND expires_at > now() AND attempts < $1
                ORDER BY next_attempt_at LIMIT 1 FOR UPDATE SKIP LOCKED
            ), reservation AS (
                INSERT INTO verification_email_budget AS budget (singleton,hour_started_at,attempts)
                SELECT true,date_trunc('hour',now(),'UTC'),1 FROM candidate
                ON CONFLICT (singleton) DO UPDATE
                SET hour_started_at=excluded.hour_started_at,
                    attempts=CASE WHEN budget.hour_started_at=excluded.hour_started_at
                        THEN budget.attempts+1 ELSE 1 END
                WHERE budget.hour_started_at < excluded.hour_started_at
                    OR (budget.hour_started_at=excluded.hour_started_at AND budget.attempts < $2)
                RETURNING singleton
            )
            UPDATE verification_email_queue q
            SET attempts=q.attempts+1, next_attempt_at=now()+interval '30 seconds'
            FROM candidate CROSS JOIN reservation WHERE q.token_hash=candidate.token_hash
            RETURNING q.token_hash,q.payload,q.attempts
            """);
        claim.Parameters.AddWithValue(MaxAttempts);
        claim.Parameters.AddWithValue(sender.MaxAttemptsPerUtcHour);
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
