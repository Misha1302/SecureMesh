# Account credentials v2

New native registrations collect a unique @username, a display name, an email address and a single password. The client requires 16–256 grapheme clusters, up to 4096 UTF-8 bytes. It preserves password whitespace and Unicode encoding exactly. Save a fresh random password in a trusted password manager. The email code verifies the mailbox. Restoring a mailbox or authenticating to the server cannot restore the private keys or chat history of a lost device.

## Credential derivation

The client encodes the password as UTF-8 and derives 32 bytes with Argon2id v1.3, 65536 KiB, three iterations and four lanes. Its 32-byte salt is SHA-256 of the following concatenated bytes.

```text
UTF8("SecureMesh/server-credential/v2") || 0x00 ||
UTF8(canonical HTTPS origin) || 0x00 || ASCII(lowercase username)
```

The Dart URI origin removes the root slash and default HTTPS port, lowercases the host and retains a nondefault port. The username uses the existing lowercase ASCII grammar. Changing the origin or username therefore requires a separately authenticated re-enrollment strategy. Base64 with standard padding encodes the result as the JSON field `credential`. HTTPS redirects are disabled. Both `POST /v2/auth/register` and `POST /v2/auth/login` reject a `password` field containing a value. Registration writes the normalized display name in the same transaction as the account and email token. The unchanged challenge still requires a device signature, while devices added after the first require approval.

SQLCipher derives its database key separately from the original password with its per-database random salt. The client writes the selected version to its encrypted onboarding journal and final profile. Neither the input password nor its network credential is journaled. The server applies its existing randomly salted Argon2 password hash to the network credential and prefixes the stored hash with `sm2$`. This extra component causes older verifiers to reject it. Updated clients and servers never automatically fall back from a v2 attempt to the legacy plaintext-over-TLS protocol.

## Compatibility and threat model

An existing two-password account uses the explicit legacy sign-in option. Preserve its existing local passphrase to unlock an existing database. For a new local profile of a legacy account use a separate local passphrase. Its old login password has historically been available to its server during authentication. There is no automatic conversion, rekeying, or change to historical SQLCipher parameters. Encrypted legacy journals and profiles without a credential-version field retain version 1. Unknown versions stop the operation.

The derived credential is a reusable authentication secret visible to the server. It does not unlock a copied SQLCipher database, and account login alone does not provide existing device keys. A server with this credential can test guesses for the original password offline using the public derivation inputs. A stolen encrypted database also permits offline guesses. The cost depends on the KDF and the entropy of the password. Neither password-length validation nor domain separation guarantees protection for reused or predictable passwords. A compromised client, OS or malicious update can capture the original input. This protocol is not a PAKE. An independent cryptographic and implementation review remains necessary before a production security claim.

The KDF parameters follow the 64 MiB profile in [RFC 9106 section 4](https://www.rfc-editor.org/rfc/rfc9106.html#section-4). The local storage design follows [SQLCipher's documented key derivation and file salt](https://www.zetetic.net/sqlcipher/design/).
