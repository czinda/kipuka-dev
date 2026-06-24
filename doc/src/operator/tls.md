# TLS Configuration

This guide covers TLS configuration for the kipuka EST server, including certificate requirements, protocol versions, cipher suites, client authentication modes, and production deployment scenarios.

## Server Certificate Requirements

RFC 7030 Section 3.3.2 mandates that EST server certificates include the **id-kp-cmcRA** Extended Key Usage (EKU) with OID `1.3.6.1.5.5.7.3.28`. This EKU identifies the server as an authorized Registration Authority (RA) for certificate enrollment operations.

Without this EKU, compliant EST clients may reject the server certificate, even if it is otherwise valid. In production deployments, include both:

- **id-kp-cmcRA** (`1.3.6.1.5.5.7.3.28`) - Required for EST protocol compliance
- **id-kp-serverAuth** (`1.3.6.1.5.5.7.3.1`) - Standard server authentication for web browser compatibility

### Generating a Server Certificate with cmcRA EKU

Create an OpenSSL configuration file (`est-server.cnf`) with the required extensions:

```ini
[ req ]
default_bits       = 2048
distinguished_name = req_distinguished_name
req_extensions     = v3_req
prompt             = no

[ req_distinguished_name ]
CN = est.example.com
O  = Example Organization
C  = US

[ v3_req ]
keyUsage           = critical, digitalSignature, keyEncipherment
extendedKeyUsage   = serverAuth, 1.3.6.1.5.5.7.3.28
subjectAltName     = @alt_names

[ alt_names ]
DNS.1 = est.example.com
DNS.2 = kipuka.example.com

[ v3_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:true
keyUsage               = critical, keyCertSign, cRLSign
```

Generate the server private key and CSR:

```bash
# Generate private key
openssl genrsa -out est-server-key.pem 2048

# Generate certificate signing request
openssl req -new -key est-server-key.pem \
    -out est-server.csr \
    -config est-server.cnf

# Sign with your CA (replace ca-cert.pem and ca-key.pem)
openssl x509 -req -in est-server.csr \
    -CA ca-cert.pem -CAkey ca-key.pem \
    -CAcreateserial -out est-server-cert.pem \
    -days 365 -sha256 \
    -extensions v3_req -extfile est-server.cnf

# Verify the cmcRA EKU is present
openssl x509 -in est-server-cert.pem -text -noout | grep -A1 "Extended Key Usage"
```

Expected output should include:

```
X509v3 Extended Key Usage:
    TLS Web Server Authentication, 1.3.6.1.5.5.7.3.28
```

### Self-Signed Certificate for Development

For development and testing only:

```bash
# Generate self-signed certificate with cmcRA EKU
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout est-server-key.pem \
    -out est-server-cert.pem \
    -days 365 -sha256 \
    -config est-server.cnf \
    -extensions v3_req
```

**Warning:** Self-signed certificates should never be used in production. Always obtain certificates from a trusted CA.

## TLS Version Configuration

The `min_version` parameter in the `[tls]` section controls the minimum TLS protocol version accepted by the server.

```toml
[tls]
min_version = "1.2"  # or "1.3"
```

### Supported Values

- **`"1.2"`** (default): Accept TLS 1.2 and TLS 1.3 connections. This is the minimum version required for RFC 7030 compliance and maintains compatibility with older EST clients.
- **`"1.3"`**: Accept only TLS 1.3 connections. Recommended for new deployments where all clients support TLS 1.3, as it provides improved security and performance.

TLS 1.0 and TLS 1.1 are **not supported**, as they have been deprecated by RFC 8996 and are considered insecure.

### Recommendation

For production environments deployed after 2024, set `min_version = "1.3"` unless you have specific legacy client requirements. TLS 1.3 removes obsolete cryptographic algorithms, reduces handshake latency, and encrypts more of the handshake metadata.

## Cipher Suite Configuration

The `cipher_suites` array in the `[tls]` section specifies the allowed cipher suites. If omitted, kipuka uses a secure default set that excludes weak ciphers.

```toml
[tls]
cipher_suites = [
    "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
    "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
    "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
    "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
]
```

### TLS 1.2 Cipher Suites

The default cipher suite list for TLS 1.2 connections includes:

```toml
cipher_suites = [
    "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
    "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
    "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
    "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
    "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256",
    "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256",
]
```

All suites provide:
- **Forward Secrecy** via ECDHE key exchange
- **AEAD encryption** (GCM or ChaCha20-Poly1305)
- **Strong hash functions** (SHA-256 or SHA-384)

### TLS 1.3 Cipher Suites

TLS 1.3 defines only three mandatory cipher suites, which are always enabled when `min_version = "1.3"`:

- `TLS_AES_256_GCM_SHA384`
- `TLS_AES_128_GCM_SHA256`
- `TLS_CHACHA20_POLY1305_SHA256`

The `cipher_suites` configuration parameter does not affect TLS 1.3, as the protocol specification mandates these suites.

### NIAP and FIPS Compliance

For systems requiring **NIAP Common Criteria** or **FIPS 140-2/3** compliance, disable ChaCha20-Poly1305 cipher suites, as they are not FIPS-approved algorithms:

```toml
[tls]
cipher_suites = [
    "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
    "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
    "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
    "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
]
```

Consult your organization's security policy for approved cipher suites.

## Client Authentication Modes

The `mode` parameter in the `[tls.client_auth]` section controls whether and how client certificates are verified.

```toml
[tls.client_auth]
mode = "optional"
trust_anchors = "/etc/kipuka/client-ca.pem"
```

### Available Modes

#### `mode = "required"`

All TLS connections **must** present a valid client certificate. The certificate must:
- Chain to a CA in the `trust_anchors` file
- Not be expired or revoked
- Have valid signatures

Use this mode when:
- All clients have existing certificates (e.g., re-enrollment only)
- Initial enrollment is performed via a separate out-of-band mechanism
- Maximum security is required

**Note:** With `mode = "required"`, clients cannot perform initial enrollment unless they already possess a certificate. You must provision initial certificates through another channel (e.g., manual issuance, SCEP, or ACME).

#### `mode = "optional"`

Client certificates are verified if presented, but connections are allowed without a certificate. This mode supports:
- **mTLS re-enrollment**: Clients with existing certificates use them for authentication
- **OTP-based enrollment**: Clients without certificates authenticate with a one-time password (OTP) during initial enrollment

This is the recommended mode for production EST deployments, as it supports the full enrollment lifecycle.

```toml
[tls.client_auth]
mode = "optional"
trust_anchors = "/etc/kipuka/client-ca.pem"

[enrollment]
require_proof_of_possession = true  # Enforce PoP for OTP enrollments
```

#### `mode = "none"`

No client certificate verification is performed. Connections are accepted without client authentication.

**This mode is for development and testing only.** Do not use in production, as it disables a critical security layer.

### Trust Anchors

The `trust_anchors` parameter specifies a PEM file containing the CA certificates trusted for client authentication. This file may contain multiple concatenated certificates.

```bash
# Example trust_anchors file with two CAs
cat ca1-cert.pem ca2-cert.pem > /etc/kipuka/client-ca.pem
```

kipuka validates client certificates against this trust anchor bundle. Ensure the file is readable by the kipuka process user.

## Separate Admin API TLS Configuration

The administrative API runs on a separate TCP port (default `9443`) and can use independent TLS settings. This allows you to:

- Bind the admin API to a management network interface
- Use separate client authentication for administrative operations
- Restrict admin access to authorized systems only

### Basic Admin API Configuration

```toml
[server]
listen = "0.0.0.0:8443"        # EST API (client-facing)
admin_listen = "127.0.0.1:9443" # Admin API (localhost only)

[tls]
cert = "/etc/kipuka/est-server-cert.pem"
key = "/etc/kipuka/est-server-key.pem"

[tls.client_auth]
mode = "optional"
trust_anchors = "/etc/kipuka/client-ca.pem"

[admin.client_auth]
mode = "required"
trust_anchors = "/etc/kipuka/admin-ca.pem"  # Separate CA for admin certs
```

In this example:
- EST API on port 8443 accepts optional client certificates from end-user devices
- Admin API on localhost port 9443 requires client certificates from administrator systems
- Admin certificates are issued by a separate CA (`admin-ca.pem`)

### Binding to Management Networks

For multi-homed systems, bind the admin API to a dedicated management network interface:

```toml
[server]
listen = "0.0.0.0:8443"           # EST API on all interfaces
admin_listen = "10.0.1.100:9443"  # Admin API on management VLAN
```

Configure firewall rules to restrict access to the management network. For example, using `iptables`:

```bash
# Allow admin API only from management subnet
iptables -A INPUT -p tcp --dport 9443 -s 10.0.1.0/24 -j ACCEPT
iptables -A INPUT -p tcp --dport 9443 -j DROP
```

### Localhost-Only Admin Access

For single-host deployments or when using a reverse proxy, bind the admin API to localhost:

```toml
[server]
admin_listen = "127.0.0.1:9443"
```

Administrators can access the API via SSH port forwarding:

```bash
ssh -L 9443:localhost:9443 user@est-server.example.com
curl --cert admin-cert.pem --key admin-key.pem \
     https://localhost:9443/admin/health
```

## Practical Configuration Examples

### Development Setup with Self-Signed Certificate

For local testing and development:

```toml
[server]
listen = "127.0.0.1:8443"
admin_listen = "127.0.0.1:9443"

[tls]
cert = "/home/dev/kipuka/dev-cert.pem"
key = "/home/dev/kipuka/dev-key.pem"
min_version = "1.2"

[tls.client_auth]
mode = "none"  # Accept all connections for testing

[enrollment]
require_proof_of_possession = false  # Simplified for dev
```

Generate the development certificate:

```bash
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout dev-key.pem -out dev-cert.pem \
    -days 365 -sha256 \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
    -addext "extendedKeyUsage=serverAuth,1.3.6.1.5.5.7.3.28"
```

### Production Setup with Internal CA

For enterprise deployments with an internal PKI:

```toml
[server]
listen = "0.0.0.0:8443"
admin_listen = "10.0.1.100:9443"

[tls]
cert = "/etc/kipuka/certs/est-server-cert.pem"
key = "/etc/kipuka/private/est-server-key.pem"
min_version = "1.2"
cipher_suites = [
    "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
    "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
    "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
    "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
]

[tls.client_auth]
mode = "optional"
trust_anchors = "/etc/kipuka/ca/device-ca-bundle.pem"

[admin.client_auth]
mode = "required"
trust_anchors = "/etc/kipuka/ca/admin-ca.pem"

[enrollment]
require_proof_of_possession = true
allowed_key_types = ["rsa2048", "rsa4096", "ecdsa256", "ecdsa384"]
```

Certificate generation workflow:

```bash
# 1. Generate server private key
openssl genrsa -out est-server-key.pem 2048
chmod 600 est-server-key.pem

# 2. Create CSR with cmcRA EKU
openssl req -new -key est-server-key.pem \
    -out est-server.csr \
    -config est-server.cnf

# 3. Submit CSR to internal CA for signing
# (Process varies by CA implementation)

# 4. Install signed certificate
install -m 644 est-server-cert.pem /etc/kipuka/certs/
install -m 600 est-server-key.pem /etc/kipuka/private/
chown kipuka:kipuka /etc/kipuka/certs/est-server-cert.pem
chown kipuka:kipuka /etc/kipuka/private/est-server-key.pem

# 5. Verify cmcRA EKU
openssl x509 -in /etc/kipuka/certs/est-server-cert.pem -text -noout \
    | grep -A1 "Extended Key Usage"
```

### High-Security Setup with TLS 1.3 Only

For environments requiring maximum security (e.g., classified networks, financial services):

```toml
[server]
listen = "10.0.1.50:8443"
admin_listen = "127.0.0.1:9443"

[tls]
cert = "/etc/kipuka/certs/est-server-cert.pem"
key = "/etc/kipuka/private/est-server-key.pem"
min_version = "1.3"  # TLS 1.3 only

# Note: cipher_suites parameter has no effect in TLS 1.3
# The following suites are always enabled:
# - TLS_AES_256_GCM_SHA384
# - TLS_AES_128_GCM_SHA256
# - TLS_CHACHA20_POLY1305_SHA256

[tls.client_auth]
mode = "required"  # All connections must present client cert
trust_anchors = "/etc/kipuka/ca/device-ca-bundle.pem"

[admin.client_auth]
mode = "required"
trust_anchors = "/etc/kipuka/ca/admin-ca.pem"

[enrollment]
require_proof_of_possession = true
allowed_key_types = ["ecdsa384"]  # P-384 only
max_validity_days = 365
require_san = true
```

Additional hardening:

```bash
# Restrict file permissions
chmod 700 /etc/kipuka/private
chmod 600 /etc/kipuka/private/*.pem
chmod 644 /etc/kipuka/certs/*.pem

# Run as unprivileged user
useradd -r -s /bin/false -d /var/lib/kipuka kipuka
chown -R kipuka:kipuka /etc/kipuka

# Enable mandatory access control (SELinux/AppArmor)
# Example SELinux policy (adjust for your distribution)
semanage fcontext -a -t cert_t "/etc/kipuka/certs(/.*)?"
semanage fcontext -a -t cert_t "/etc/kipuka/ca(/.*)?"
semanage fcontext -a -t cert_t "/etc/kipuka/private(/.*)?"
restorecon -R /etc/kipuka
```

### FIPS-Compliant Configuration

For systems requiring FIPS 140-2/3 compliance:

```toml
[server]
listen = "0.0.0.0:8443"
admin_listen = "10.0.1.100:9443"

[tls]
cert = "/etc/kipuka/certs/est-server-cert.pem"
key = "/etc/kipuka/private/est-server-key.pem"
min_version = "1.2"

# Disable ChaCha20 (not FIPS-approved)
cipher_suites = [
    "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
    "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
    "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
    "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
]

[tls.client_auth]
mode = "required"
trust_anchors = "/etc/kipuka/ca/device-ca-bundle.pem"

[enrollment]
allowed_key_types = ["rsa2048", "rsa4096", "ecdsa256", "ecdsa384"]
allowed_signature_algorithms = ["sha256", "sha384", "sha512"]
```

Ensure the underlying operating system is running in FIPS mode:

```bash
# RHEL/CentOS
fips-mode-setup --enable
reboot

# Verify FIPS mode
cat /proc/sys/crypto/fips_enabled  # Should output: 1
```

## Troubleshooting

### Client Rejects Server Certificate

**Symptom:** EST client fails with "server certificate verification failed" or similar.

**Cause:** Server certificate missing the `id-kp-cmcRA` EKU.

**Solution:** Verify the EKU is present:

```bash
openssl x509 -in est-server-cert.pem -text -noout | grep -A1 "Extended Key Usage"
```

Expected output:

```
X509v3 Extended Key Usage:
    TLS Web Server Authentication, 1.3.6.1.5.5.7.3.28
```

If `1.3.6.1.5.5.7.3.28` is missing, regenerate the certificate using the instructions in "Server Certificate Requirements."

### TLS Handshake Failure

**Symptom:** Connection fails during TLS handshake with "no shared cipher" or "protocol version mismatch."

**Cause:** Client and server have no common cipher suites or TLS versions.

**Solution:** Enable TLS 1.2 support if clients do not support TLS 1.3:

```toml
[tls]
min_version = "1.2"
```

Check client cipher suite support and add compatible suites to `cipher_suites`.

### Admin API Unreachable

**Symptom:** Cannot connect to admin API on port 9443.

**Cause:** Admin API bound to wrong interface or blocked by firewall.

**Solution:** Verify `admin_listen` binding:

```toml
[server]
admin_listen = "0.0.0.0:9443"  # Listen on all interfaces
```

Check firewall rules:

```bash
# List firewall rules
iptables -L -n -v | grep 9443

# Allow admin API port
iptables -A INPUT -p tcp --dport 9443 -j ACCEPT
```

For localhost-only access, use SSH port forwarding:

```bash
ssh -L 9443:localhost:9443 user@est-server.example.com
```

## Security Best Practices

1. **Use TLS 1.3 for new deployments:** Set `min_version = "1.3"` to eliminate legacy protocol weaknesses.
2. **Restrict cipher suites:** Use the default list or a more restrictive set. Avoid CBC-mode ciphers and weak hashes.
3. **Require client authentication for re-enrollment:** Set `mode = "required"` if all clients have certificates.
4. **Separate admin and client CAs:** Use distinct trust anchors for administrative and end-user certificates.
5. **Bind admin API to management networks:** Limit exposure of administrative endpoints.
6. **Rotate certificates before expiration:** Monitor certificate expiry and renew at least 30 days in advance.
7. **Protect private keys:** Store keys on encrypted filesystems or HSMs. Use `chmod 600` and restrict access to the kipuka process user.
8. **Enable OCSP or CRL checking:** Configure revocation checking for client certificates (see enrollment configuration documentation).
9. **Audit TLS configuration regularly:** Use tools like `testssl.sh` or `sslyze` to verify cipher suite and protocol configuration.
10. **Follow your organization's security policy:** Consult internal PKI and cryptography standards before deployment.

## References

- **RFC 7030:** Enrollment over Secure Transport (EST)
- **RFC 8996:** Deprecating TLS 1.0 and TLS 1.1
- **RFC 8446:** The Transport Layer Security (TLS) Protocol Version 1.3
- **NIST SP 800-52 Rev. 2:** Guidelines for the Selection, Configuration, and Use of TLS
- **NIAP Protection Profile for Network Devices:** Common Criteria requirements for TLS configuration
