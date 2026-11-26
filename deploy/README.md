# Future deployment — NOT READY

No remote server, DNS, real email/push account, public repository or production service was changed. PRODUCTION_APPROVED=false. These are review templates, not an approved staging release. Current API intentionally refuses Production startup; do not remove that guard before security/acceptance blockers are resolved.

Before deployment: complete required M0–M7 functionality/gates; remediate advisories; obtain independent crypto/mobile/infra review; choose host/jurisdiction, domain/TLS, SMTP/abuse contact, push/store credentials, object/backup provider, admin MFA/bootstrap, retention/legal policy and operational ownership. No external credentials are required for local development.

Pin reviewed runtime/API image digests; apply compatible migrations, run staging smoke and DB+object recovery, prepare rollback. No production capacity was measured. compose.staging.yaml requires injected reviewed image/config and still hits the production guard. reverse-proxy.conf.template is for later TLS review. Actual DB-only recovery is tests/integration/recovery.py; media/object recovery is absent. Future deployment requires a separate owner instruction.

### Registration email via Resend SMTP in the local alpha

Mailpit on loopback is the default. To opt in to external verification email, verify the sending domain in Resend and create a sending-only key restricted to that domain. Store the key in a secret file outside the checkout, readable only by the API runtime. Export these settings in the process that starts the API, replacing the example address and path:

```sh
export VerificationEmail__Provider=Resend
export VerificationEmail__From=verification@example.org
export VerificationEmail__ApiKeyFile=/run/secrets/securemesh-resend
make demo
```

The API connects to smtp.resend.com on port 587 using mandatory STARTTLS and the SMTP username resend. Resend receives the recipient address and verification code. Restart the API after key rotation. To verify delivery, register a fresh test account with a mailbox you control and submit the code received there. Check delivery status in the Resend Emails dashboard. Production startup remains gated.
