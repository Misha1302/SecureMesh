using System.Net;
using System.Net.Mail;

namespace SecureMesh;

internal sealed class VerificationEmail
{
    private readonly string sender = "no-reply@securemesh.test";
    private readonly NetworkCredential? credentials;
    private readonly int mailpitPort;
    public int MaxAttemptsPerUtcHour { get; }

    public VerificationEmail(IConfiguration configuration)
    {
        MaxAttemptsPerUtcHour = configuration.GetValue("VerificationEmail:MaxAttemptsPerUtcHour", 60);
        if (MaxAttemptsPerUtcHour < 1)
            throw new InvalidOperationException("VerificationEmail:MaxAttemptsPerUtcHour must be positive.");

        var provider = configuration["VerificationEmail:Provider"];
        if (provider is null or "Mailpit")
        {
            mailpitPort = configuration.GetValue("VerificationEmail:MailpitPort", 51028);
            if (mailpitPort is < 1 or > 65535)
                throw new InvalidOperationException("VerificationEmail:MailpitPort must be a valid port.");
            return;
        }
        if (provider != "Resend")
            throw new InvalidOperationException("Unknown verification email provider.");

        var from = configuration["VerificationEmail:From"];
        if (!MailAddress.TryCreate(from, out var address) || address.Address != from)
            throw new InvalidOperationException("VerificationEmail:From requires a sender address on a verified Resend domain.");
        var path = configuration["VerificationEmail:ApiKeyFile"];
        if (string.IsNullOrWhiteSpace(path))
            throw new InvalidOperationException("VerificationEmail:ApiKeyFile is required for Resend.");
        var key = File.ReadAllText(path).Trim();
        if (string.IsNullOrWhiteSpace(key))
            throw new InvalidOperationException("The Resend API key file is empty.");
        sender = address.Address;
        credentials = new NetworkCredential("resend", key);
    }

    public async Task SendAsync(string recipient, string token, CancellationToken cancellationToken)
    {
        using var smtp = credentials is null
            ? new SmtpClient("127.0.0.1", mailpitPort)
            : new SmtpClient("smtp.resend.com", 587) { EnableSsl = true, Credentials = credentials };
        using var message = new MailMessage(sender, recipient, "SecureMesh verification", token);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        try
        {
            await smtp.SendMailAsync(message, timeout.Token);
        }
        catch (SmtpException)
        {
            throw new ApiError(503, "EMAIL_DELIVERY_UNAVAILABLE");
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new ApiError(503, "EMAIL_DELIVERY_UNAVAILABLE");
        }
    }
}
