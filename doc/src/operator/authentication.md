# Authentication

kipuka supports multiple authentication methods to accommodate different enrollment scenarios and enterprise environments. This chapter covers the three primary authentication mechanisms available for EST endpoints.

## Authentication Methods

### mTLS (Mutual TLS) Authentication

Mutual TLS is the primary authentication method for EST as defined in RFC 7030. The client presents a certificate during the TLS handshake, which the server validates against a configured trust store.

#### Configuration

mTLS is configured in the `[tls.client_auth]` section:

```toml
[tls]
# ... other TLS settings ...

[tls.client_auth]
# Path to CA bundle containing trusted client certificate issuers
trust_anchors = "/etc/kipuka/client-ca-bundle.pem"

# Client certificate verification mode
mode = "required"  # required | optional | none
```

**Mode Options:**

- **`required`**: All EST endpoints require a valid client certificate. The TLS handshake fails if no certificate is presented or if the certificate is not signed by a trusted CA.
- **`optional`**: Client certificate is verified if presented, but clients without certificates can still connect. This mode allows fallback to OTP or GSSAPI for initial enrollment.
- **`required_for_reenroll`**: Enrollment optionally requires a client certificate, but reenrollment is only possible using an existing client certificate.
- **`none`**: No client certificate verification. Not recommended for production environments.

**Trust Anchors:**

The `trust_anchors` file should contain one or more PEM-encoded CA certificates. These CAs define which client certificates are accepted for authentication.

```bash
# Example: concatenate multiple CA certificates
cat corporate-ca.pem partner-ca.pem > /etc/kipuka/client-ca-bundle.pem
```

#### Re-enrollment Workflow

For re-enrollment (`/simplereenroll`), the client typically uses its previously-issued certificate as the client certificate:

1. Client initiates TLS connection with its current certificate
2. Server validates certificate against trust anchors
3. Client submits CSR for new certificate
4. Server issues new certificate

#### Example: Initial Enrollment with mTLS

For clients that already have a certificate (e.g., issued by a different CA or manually installed):

```bash
curl --cert client.crt --key client.key \
     --cacert est-server-ca.pem \
     -H "Content-Type: application/pkcs10" \
     --data-binary @request.csr \
     https://est.example.com:8443/.well-known/est/simpleenroll
```

#### Example: Re-enrollment

```bash
# Use the previously-issued certificate for authentication
curl --cert current.crt --key current.key \
     --cacert est-server-ca.pem \
     -H "Content-Type: application/pkcs10" \
     --data-binary @renewal.csr \
     https://est.example.com:8443/.well-known/est/simplereenroll
```

### OTP (One-Time Password) Authentication

OTP authentication is designed for initial enrollment scenarios where the client does not yet have a certificate. The administrator generates a token via the Admin API, delivers it to the client through a secure out-of-band channel, and the client uses it for authentication.

#### Configuration

```toml
[otp]
# Enable OTP authentication
enabled = true

# Hash algorithm for token storage
# Options: argon2id (recommended), bcrypt, sha256-hmac
hash_algorithm = "argon2id"

# Minimum token length (NIAP PP requires >= 16)
token_length = 20

# Single-use or multi-use tokens
max_uses = 1

# Rate limiting configuration
max_failures = 5
failure_window = 300  # 5 minutes
lockout_duration = 900  # 15 minutes
```

**Hash Algorithms:**

- **`argon2id`** (recommended): NIAP-compliant, memory-hard algorithm resistant to GPU attacks
- **`bcrypt`**: Industry-standard password hashing
- **`sha256-hmac`**: Fast but less secure; use only for low-security environments

All implementations use timing-safe comparison to prevent timing attacks.

**Rate Limiting:**

- `max_failures`: Maximum authentication failures before lockout
- `failure_window`: Time window (seconds) for counting failures
- `lockout_duration`: How long (seconds) the client is locked out after exceeding max_failures

#### OTP Workflow

1. **Token Generation**: Administrator calls the Admin API to generate an OTP token
2. **Out-of-Band Delivery**: Token is securely delivered to the client (email, SMS, secure portal, etc.)
3. **Client Authentication**: Client uses the token in HTTP Basic authentication
4. **Certificate Issuance**: Server validates token and issues certificate
5. **Future Renewals**: Client uses mTLS with the issued certificate

#### Generating OTP Tokens

Tokens are generated via the Admin API:

```bash
# Generate a single-use OTP token for a client
curl -X POST https://est.example.com:8443/admin/otp \
     -H "Authorization: Bearer <admin-token>" \
     -H "Content-Type: application/json" \
     -d '{
       "client_id": "workstation-42",
       "max_uses": 1,
       "expires_at": "2026-06-30T23:59:59Z"
     }'
```

Response:

```json
{
  "token": "xK9mP2vL8qR5wN3jT7fY",
  "client_id": "workstation-42",
  "created_at": "2026-06-24T10:15:00Z",
  "expires_at": "2026-06-30T23:59:59Z",
  "max_uses": 1
}
```

#### Using OTP for Enrollment

The client sends the OTP token as the password in HTTP Basic authentication. The username is ignored but should be provided for RFC compliance:

```bash
# Enroll using OTP authentication
curl -u ":xK9mP2vL8qR5wN3jT7fY" \
     --cacert est-server-ca.pem \
     -H "Content-Type: application/pkcs10" \
     --data-binary @request.csr \
     https://est.example.com:8443/.well-known/est/simpleenroll
```

After successful enrollment, the client stores the issued certificate and uses mTLS for all future operations, including re-enrollment.

#### NIAP PP Compliance

For NIAP Protection Profile compliance:

- Set `token_length >= 16`
- Use `hash_algorithm = "argon2id"`
- Configure appropriate rate limiting
- Enable audit logging for OTP generation and usage

### GSSAPI/Kerberos Authentication

GSSAPI authentication provides enterprise Single Sign-On (SSO) integration using Kerberos tickets. This is particularly useful in Active Directory and FreeIPA environments.

#### Configuration

```toml
[gssapi]
# Enable GSSAPI/Kerberos authentication
enabled = true

# Path to server's keytab file
keytab = "/etc/kipuka/kipuka.keytab"

# Service principal name
# Format: HTTP/hostname@REALM
service_principal = "HTTP/est.example.com@EXAMPLE.COM"

# Principal to certificate subject mapping
# Maps Kerberos principal to X.509 subject DN
[gssapi.principal_mapping]
"user@EXAMPLE.COM" = "CN=User,OU=People,DC=example,DC=com"
"admin@EXAMPLE.COM" = "CN=Admin,OU=Admins,DC=example,DC=com"

# Default mapping template (optional)
# {principal} is replaced with the authenticated Kerberos principal
default_template = "CN={principal},OU=Users,DC=example,DC=com"
```

#### Server Setup

The EST server must have a keytab containing credentials for the HTTP service principal:

```bash
# On Active Directory or FreeIPA KDC, create the service principal
# and export the keytab

# FreeIPA example:
ipa service-add HTTP/est.example.com
ipa-getkeytab -s ipaserver.example.com \
              -p HTTP/est.example.com \
              -k /etc/kipuka/kipuka.keytab

# Set appropriate permissions
chown kipuka:kipuka /etc/kipuka/kipuka.keytab
chmod 600 /etc/kipuka/kipuka.keytab
```

#### Client Authentication

Clients use SPNEGO (RFC 4559) to send Kerberos tickets via the `Negotiate` HTTP authentication scheme:

```bash
# Obtain Kerberos ticket
kinit user@EXAMPLE.COM

# Enroll using GSSAPI authentication
curl --negotiate -u : \
     --cacert est-server-ca.pem \
     -H "Content-Type: application/pkcs10" \
     --data-binary @request.csr \
     https://est.example.com:8443/.well-known/est/simpleenroll
```

The server:

1. Receives the `Negotiate` header with Kerberos ticket
2. Validates the ticket against the KDC
3. Extracts the authenticated principal name
4. Maps the principal to a certificate subject DN using the configured mapping rules
5. Issues a certificate with the mapped subject

#### Authentication Modes

kipuka supports two GSSAPI authentication modes controlled by the `require_crypto_verification` setting:

**Cryptographic Verification (default, recommended)**

When `require_crypto_verification = true` (the default), kipuka uses `libgssapi` to perform full cryptographic verification of Kerberos tickets. This requires:

- A valid keytab file or gssproxy configuration
- The `gssapi` compile-time feature flag enabled
- Network connectivity to the KDC for ticket validation

```toml
[gssapi]
enabled = true
keytab = "/etc/kipuka/kipuka.keytab"
service_principal = "HTTP/est.example.com@EXAMPLE.COM"
require_crypto_verification = true
```

**Structural Parsing Mode (development only)**

When `require_crypto_verification = false`, kipuka performs structural parsing of the SPNEGO token without cryptographic verification. The service name (sname) is extracted from the cleartext portion of the ticket, but:

- No cryptographic verification is performed
- The client identity **cannot** be authenticated
- This mode is **not suitable for production**

This mode is intended only for development, logging, or environments where TLS client certificates provide the primary authentication and GSSAPI is used only for identity hint extraction.

```toml
[gssapi]
enabled = true
require_crypto_verification = false  # WARNING: development only
```

> **Security Warning:** Never set `require_crypto_verification = false` in production. Without cryptographic verification, any client can forge a SPNEGO token with an arbitrary principal name.

#### Credential Management

kipuka supports two mutually exclusive credential management strategies:

**Keytab file** (traditional):

```toml
[gssapi]
keytab = "/etc/kipuka/kipuka.keytab"
```

**gssproxy** (recommended for containerized deployments):

```toml
[gssapi]
gssproxy = true  # Uses gssproxy socket instead of keytab
```

gssproxy separates credential management from the application, allowing kipuka to run without direct access to the keytab file. This is particularly useful in container environments where mounting keytab files is operationally complex.

#### Principal Mapping

The `principal_mapping` table defines explicit mappings from Kerberos principals to certificate subject DNs. If no explicit mapping exists, the `default_template` is used (if configured).

Example: Principal `alice@EXAMPLE.COM` with default template `"CN={principal},OU=Users,DC=example,DC=com"` results in subject `CN=alice@EXAMPLE.COM,OU=Users,DC=example,DC=com`.

## Authentication per Endpoint

Different EST endpoints have different authentication requirements:

| Endpoint | Authentication | Notes |
|----------|---------------|-------|
| `/cacerts` | None | Public endpoint; returns CA certificate chain |
| `/csrattrs` | None | Public endpoint; returns CSR attributes |
| `/simpleenroll` | mTLS OR OTP OR GSSAPI | Initial enrollment; at least one method must succeed |
| `/simplereenroll` | mTLS required | Re-enrollment requires an existing valid certificate |
| `/serverkeygen` | mTLS OR OTP OR GSSAPI | Server-side key generation; same as simpleenroll |
| `/fullcmc` | mTLS required | Full CMC protocol requires client certificate |
| `/admin/*` | Admin auth | Separate authentication via `[admin]` section |

### Admin Endpoint Authentication

Admin endpoints (OTP generation, certificate revocation, etc.) use separate authentication configured in the `[admin]` section:

```toml
[admin]
# mTLS for admin endpoints
[admin.tls]
trust_anchors = "/etc/kipuka/admin-ca-bundle.pem"
mode = "required"

# Bearer token authentication (alternative or in addition to mTLS)
[admin.bearer_token]
enabled = true
tokens = [
    { token_hash = "sha256:...", description = "CI/CD automation" },
    { token_hash = "sha256:...", description = "Admin portal" }
]
```

Admin authentication is independent of EST endpoint authentication. You can require mTLS for admin operations even if EST endpoints accept OTP or GSSAPI.

## Authentication Precedence

When multiple authentication methods are enabled, kipuka evaluates them in the following order:

1. **mTLS**: If a client certificate is presented (and `mode != "none"`), it is validated first
2. **GSSAPI**: If no valid client certificate and `Negotiate` header is present, GSSAPI is attempted
3. **OTP**: If no valid client certificate and `Authorization: Basic` header is present, OTP is checked

A request succeeds if any enabled method authenticates successfully. For endpoints requiring mTLS (e.g., `/simplereenroll`), only mTLS is evaluated.

## Security Best Practices

- **Production environments**: Use `mode = "required"` for mTLS and disable OTP after initial enrollment
- **Initial enrollment**: Use `mode = "optional"` with OTP enabled, then migrate to `mode = "required"` after all devices are enrolled
- **Token delivery**: Never send OTP tokens over the same channel as enrollment (e.g., do not email a token to an address that auto-forwards to the EST client)
- **Token entropy**: Use `token_length >= 20` for high-security environments
- **Keytab protection**: Store GSSAPI keytabs with restrictive permissions (600) and limit access to the kipuka service account
- **Audit logging**: Enable audit logs for all authentication events to detect suspicious activity

## Troubleshooting

### mTLS Issues

**Error: "client certificate required"**

- Verify `mode` is set to `optional` or `none` if client does not have a certificate
- Check that the client is sending a certificate (`--cert` and `--key` in curl)

**Error: "certificate signed by unknown authority"**

- Ensure the client certificate is signed by a CA in `trust_anchors`
- Verify the CA bundle is readable and contains valid PEM data

### OTP Issues

**Error: "invalid OTP token"**

- Check token expiration (`expires_at`)
- Verify token has not exceeded `max_uses`
- Ensure token is sent as password in Basic auth (username can be empty or any value)

**Error: "too many failures, locked out"**

- Wait for `lockout_duration` to expire
- Review rate limiting configuration (`max_failures`, `failure_window`)

### GSSAPI Issues

**Error: "GSSAPI authentication failed"**

- Verify client has a valid Kerberos ticket (`klist`)
- Check server's keytab is readable and contains the correct principal
- Ensure clocks are synchronized between client, server, and KDC (Kerberos requires time sync within 5 minutes)

**Error: "principal not mapped"**

- Add an explicit mapping in `[gssapi.principal_mapping]` or configure `default_template`
- Check that the authenticated principal name matches the expected format
