# Future deployment — NOT READY

The deployment templates are under review. PRODUCTION_APPROVED=false. The project domain is nodata-messenger.online. The last DNS snapshot, HTTPS probe and registrar access status are recorded in [the product handoff](../reports/PRODUCT_HANDOFF_RU.md). Current API intentionally refuses Production startup; do not remove that guard before security/acceptance blockers are resolved.

Before deployment: complete required M0–M7 functionality/gates; remediate advisories; obtain independent crypto/mobile/infra review; choose host/jurisdiction, domain/TLS, SMTP/abuse contact, push/store credentials, object/backup provider, admin MFA/bootstrap, retention/legal policy and operational ownership. No external credentials are required for local development.

Pin reviewed runtime/API image digests; apply compatible migrations, run staging smoke and DB+object recovery, prepare rollback. No production capacity was measured. compose.staging.yaml requires injected reviewed image/config and still hits the production guard. reverse-proxy.conf.template is for later TLS review. Local recovery exercises cover profile privacy, restricted channel data, MLS messages and database-backed encrypted attachments. The public ingress still requires access to the host, a zone export, a trusted certificate and a tested rollback. [Backup and recovery coverage](backups/README.md)

### DNS rollout for registration mail

The proposed sending domain is `auth.nodata-messenger.online`. The observed apex already receives mail through the hosting provider and publishes its SPF policy. Keep those records when enabling SecureMesh mail. The recorded public answers cover selected names. Obtain the full provider zone export and identify the exact owner names of the changes before applying them. [Public DNS snapshot](../reports/evidence/public-dns-20261128.json)

1. In Resend Domains, add the sending subdomain and choose its sending region. Copy the exact DKIM record and return-path records shown for that domain. Record each owner name, RR type, MX priority if present, target and TTL in the private change log. [Resend domain configuration](https://resend.com/docs/dashboard/domains/introduction)
2. At the authoritative DNS provider, add the generated records under their specified names. Check how the zone editor appends the root suffix. Coordinate any pre-existing SPF or MX record at the same owner before changing it. Check the effective DMARC policy for the sending subdomain including inheritance from the apex, and validate alignment with the chosen From address using the received test message.
3. Verify the records against both authoritative servers and a recursive resolver, then wait for the domain to show verified in Resend. Open its Configuration tab and check that open and click tracking are disabled. [Tracking settings](https://resend.com/docs/dashboard/domains/tracking)
4. Create a Sending access key restricted to the verified subdomain and place it in the protected server secret file. Record the key name and rotation date separately from its value. [Resend key permissions](https://resend.com/docs/dashboard/api-keys/introduction)
5. Run registration and recovery for an authorized test mailbox. Verify actual arrival, SPF/DKIM/DMARC results in the received headers, acceptance of each code once, fresh login after recovery, and rejection of the old session. Keep timestamps and outcomes in the test report. Exclude email bodies, authorization codes and message headers containing personal data.
6. For rollback, stop the email worker's external sending, revoke the dedicated key and restore only the changed RRsets from the provider export. Recheck the apex MX, SPF and delivery of existing mail.

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

## Private blob upload limit

The nginx template allows 4,194,320 bytes for `PUT /v1/conversations/{group}/blobs/{id}` with lowercase canonical UUIDs. This fits native 4 MiB attachments and PWA photos with their 16-byte AES-GCM tag. Every other request, including `/parts` and other methods on the blob URL, keeps the 128 KiB cap. The API still enforces trusted membership, ciphertext length and quotas.

The API virtual host writes HTTP status and elapsed time to stdout. Its normal access log omits the remote address, request line, query string, headers and account or conversation identifiers. Its error threshold is critical because routine nginx errors can include the original request line. Restrict access and retention for runtime and platform logs. Review upstream load balancers, the default virtual host, application logging and crash diagnostics separately before staging.

Substitute only the three deployment placeholders to retain the nginx variables:

```sh
envsubst '$SECUREMESH_DOMAIN $SECUREMESH_TLS_CERT_PATH $SECUREMESH_TLS_KEY_PATH' \
  < deploy/reverse-proxy.conf.template
```

The local integration test renders this template with a loopback listener, a private TLS certificate and an isolated API/PostgreSQL fixture. It uses local PostgreSQL and Mailpit, the Debug API, the native crypto CLI, generated wire bindings, OpenSSL and a locally cached `nginx:1.27-alpine` image. Override `SECUREMESH_TEST_NGINX_IMAGE` to test a different cached image.

```sh
.local/venv/bin/python tests/integration/nginx_private_blobs.py
```

The test checks native and PWA-sized PUT/GET round trips, rejection one byte above the cap, standard and part request limits, rejection of URL aliases at the elevated size, browser preflight and WSS HELLO/PING.
