# Future deployment — NOT READY

The deployment templates are under review. PRODUCTION_APPROVED=false. The project domain is nodata-messenger.online. The last DNS snapshot, HTTPS probe and registrar access status are recorded in [the product handoff](../reports/PRODUCT_HANDOFF_RU.md). Current API intentionally refuses Production startup; do not remove that guard before security/acceptance blockers are resolved.

Before deployment: complete required M0–M7 functionality/gates; remediate advisories; obtain independent crypto/mobile/infra review; choose host/jurisdiction, domain/TLS, SMTP/abuse contact, push/store credentials, object/backup provider, admin MFA/bootstrap, retention/legal policy and operational ownership. No external credentials are required for local development.

Pin reviewed runtime/API image digests; apply compatible migrations, run staging smoke and DB+object recovery, prepare rollback. No production capacity was measured. compose.staging.yaml requires injected reviewed image/config and still hits the production guard. reverse-proxy.conf.template is for later TLS review. Local recovery exercises cover profile privacy, restricted channel data, MLS messages and database-backed encrypted attachments. The public ingress still requires access to the host, a zone export, a trusted certificate and a tested rollback. [Backup and recovery coverage](backups/README.md)

### Registration email via Resend SMTP in the local alpha

Mailpit on loopback is the default. To opt in to external verification email, verify the sending domain in Resend and create a sending-only key restricted to that domain. Store the key in a secret file outside the checkout, readable only by the API runtime. Export these settings in the process that starts the API, replacing the example address and path:

```sh
export VerificationEmail__Provider=Resend
export VerificationEmail__From=verification@example.org
export VerificationEmail__ApiKeyFile=/run/secrets/securemesh-resend
make demo
```

The API connects to smtp.resend.com on port 587 using mandatory STARTTLS and the SMTP username resend. Resend receives the recipient address and verification code. Restart the API after key rotation. To verify delivery, register a fresh test account with a mailbox you control and submit the code received there. Check delivery status in the Resend Emails dashboard. Production startup remains gated.

Set `VerificationEmail__MaxAttemptsPerUtcHour` to the same positive value on all API workers that share a database and sender. The default is 60. Initial sends, resends and retries share this persisted cap. Each worker reserves capacity before contacting SMTP, so a timeout or interrupted attempt still counts. When capacity runs out, pending messages keep their existing queue state and retry eligibility until the next UTC hour. Verification codes retain their 30-minute expiration and expired messages are removed. Workers that share the queue need the same persistent ASP.NET Data Protection key directory.

### Public demo registration rollout

`Caddyfile.public-demo` forwards `/v2/auth/register`, `/v2/auth/resend-verification`, `/v2/auth/login`, `/v2/auth/recovery/complete`, `/v2/auth/reauthenticate` and the health endpoints to the demo API over loopback HTTPS. The API must also be built from a revision that serves the v2 routes. The historical VPS installer in commit `625548e` shipped a versioned API and OpenMLS validator bundle to the `securemesh-demo` systemd unit. It switched `/opt/securemesh-demo/releases/current` and kept persistent data under `/var/lib/securemesh-demo`. The Caddy configuration was installed separately as `/etc/caddy/Caddyfile`. The installer and SSH deployment script are absent from the current checkout.

For an owner-authorized demo rollout, confirm access to the demo host and identify the active release, state paths and mail configuration. Build and test the candidate with local PostgreSQL and Mailpit using the v2 integration flow in `tests/integration/delivery.py`. Before switching, take and verify a database backup, save the active Caddy configuration and retain the previous release. Validate the candidate Caddy configuration on the target Caddy version. Install the reviewed bundle and proxy configuration, then check readiness and the v2 validation responses both upstream and through the public ingress.

```sh
python3 deploy/check-registration-contract.py https://127.0.0.1:5088 --ca-file .local/tls.pem
python3 deploy/check-registration-contract.py https://demo.example.org
```

Use the actual ingress origin for the second command. The probe uses an invalid username and email in each request so the API rejects them before storage or SMTP. It checks that a one-character display name gets past display-name validation and that a control character is rejected with `INVALID_DISPLAY_NAME`. Successful registration, mail delivery and TLS reachability from client networks require their own checks.

If readiness or the contract fails after switching, restore the prior proxy configuration and, after checking migration and persisted credential compatibility, revert to the previous API release. Older releases cannot authenticate accounts created with v2 credentials. Preserve the database and investigate before switching back if v2 accounts may already exist. Production startup remains disabled.
