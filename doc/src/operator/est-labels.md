# EST Labels

EST labels provide a powerful mechanism for operating multiple certificate profiles from a single EST server instance. This chapter covers label configuration, policy enforcement, and practical deployment patterns.

## What Are EST Labels

RFC 7030 Section 3.2.2 defines EST path segments that enable certificate profile selection. The URL pattern for enrollment operations follows this structure:

```
/.well-known/est/<label>/simpleenroll
/.well-known/est/<label>/simplereenroll
```

When a client makes a request without a label (e.g., `/.well-known/est/simpleenroll`), the EST server applies its default certificate profile. Labels allow a single EST server to issue different types of certificates with different policies, CA issuers, and validation rules.

Common use cases include:

- **Certificate purpose separation**: Different labels for TLS server certificates, client authentication certificates, and code signing certificates
- **Policy enforcement**: Distinct labels enforcing different validity periods, key requirements, or subject naming constraints
- **Multi-tenant operation**: Separate labels for different organizational units or trust boundaries
- **CA hierarchy management**: Different labels issuing from different intermediate CAs within the same PKI

## Label Configuration

Each `[[est.label]]` section in `kipuka.toml` defines a named profile. Labels are bound to specific CAs and enforce policy constraints on certificate issuance.

### Full Label Syntax

```toml
[[est.label]]
# Unique label name used in EST URLs
name = "server-tls"

# CA ID reference (must match a [[ca]] entry)
ca_id = "intermediate-tls"

# Allowed CSR key types (optional)
# If omitted, all key types are accepted
allowed_key_types = ["ecdsaP256", "ecdsaP384", "rsa2048", "rsa3072"]

# Required Extended Key Usage OIDs (optional)
# Forces these EKUs into all issued certificates
required_ext_key_usage = ["serverAuth"]

# Maximum certificate validity in days (optional)
# Overrides CA default if set
max_validity_days = 398

# Require Subject Alternative Names (default: true)
require_san = true

# Subject DN validation regex (optional)
# CSRs must match this pattern to be accepted
subject_pattern = "^CN=[a-z0-9-]+\\.example\\.com(,.*)?$"
```

All fields except `name` and `ca_id` are optional. Without constraints, the label inherits behavior from the referenced CA.

## CA Binding

Every label must reference a CA through `ca_id`. This CA identifier must match the `id` field of a `[[ca]]` entry defined elsewhere in `kipuka.toml`.

### Multiple Labels, Same CA

Different labels can reference the same CA to provide different policy enforcement while using the same issuer:

```toml
[[ca]]
id = "corp-intermediate"
cert_path = "/etc/kipuka/pki/intermediate.crt"
key_path = "/etc/kipuka/pki/intermediate.key"
default_validity_days = 365

[[est.label]]
name = "server"
ca_id = "corp-intermediate"
required_ext_key_usage = ["serverAuth"]
max_validity_days = 398

[[est.label]]
name = "client"
ca_id = "corp-intermediate"
required_ext_key_usage = ["clientAuth"]
max_validity_days = 90
require_san = false
```

Both labels issue certificates from the same intermediate CA but enforce different EKUs, validity periods, and SAN requirements.

### Multiple Labels, Different CAs

Labels can reference different CAs to support complex PKI hierarchies:

```toml
[[ca]]
id = "public-tls-ca"
cert_path = "/etc/kipuka/pki/public-tls-intermediate.crt"
key_path = "/etc/kipuka/pki/public-tls-intermediate.key"

[[ca]]
id = "internal-device-ca"
cert_path = "/etc/kipuka/pki/internal-device-intermediate.crt"
key_path = "/etc/kipuka/pki/internal-device-intermediate.key"

[[est.label]]
name = "public-server"
ca_id = "public-tls-ca"
required_ext_key_usage = ["serverAuth"]

[[est.label]]
name = "iot-device"
ca_id = "internal-device-ca"
required_ext_key_usage = ["clientAuth"]
max_validity_days = 30
```

This configuration issues public TLS certificates from one CA and private IoT device certificates from another.

## Key Type Restrictions

The `allowed_key_types` field restricts which cryptographic key algorithms are accepted in certificate signing requests. This prevents weak key types or enforces organizational cryptographic policies.

### Supported Key Type Values

```toml
allowed_key_types = [
    "rsa2048",    # RSA with 2048-bit modulus
    "rsa3072",    # RSA with 3072-bit modulus
    "rsa4096",    # RSA with 4096-bit modulus
    "ecdsaP256",  # ECDSA with NIST P-256 curve
    "ecdsaP384",  # ECDSA with NIST P-384 curve
    "ecdsaP521",  # ECDSA with NIST P-521 curve
]
```

If `allowed_key_types` is omitted, the label accepts any supported key type. An empty array `[]` rejects all requests.

### Example: ECDSA-Only Label

```toml
[[est.label]]
name = "modern-tls"
ca_id = "tls-ca"
allowed_key_types = ["ecdsaP256", "ecdsaP384"]
```

This configuration rejects all RSA CSRs and only accepts P-256 or P-384 ECDSA keys.

## EKU Constraints

The `required_ext_key_usage` field forces specific Extended Key Usage OIDs into all certificates issued under this label. This ensures certificates are only used for their intended purpose.

### Common EKU Values

```toml
required_ext_key_usage = [
    "serverAuth",        # TLS server authentication (1.3.6.1.5.5.7.3.1)
    "clientAuth",        # TLS client authentication (1.3.6.1.5.5.7.3.2)
    "emailProtection",   # S/MIME email (1.3.6.1.5.5.7.3.4)
    "codeSigning",       # Code signing (1.3.6.1.5.5.7.3.3)
]
```

You can specify multiple EKUs for dual-purpose certificates. If the field is omitted, the label does not enforce EKU requirements (though the CA may still add EKUs based on its own policy).

### Example: Mutual TLS Label

```toml
[[est.label]]
name = "mtls"
ca_id = "corp-ca"
required_ext_key_usage = ["serverAuth", "clientAuth"]
```

Certificates issued under this label can be used for both server and client authentication.

## SAN Requirements

The `require_san` field enforces the presence of Subject Alternative Names in certificate signing requests. This follows CA/Browser Forum Baseline Requirements, which mandate SAN extensions for publicly trusted TLS certificates.

```toml
require_san = true   # Default: reject CSRs without SAN
require_san = false  # Accept CSRs without SAN
```

When `require_san = true`, the EST server rejects any CSR that does not contain at least one SAN entry (DNS name, IP address, email, or URI).

### When to Disable SAN Requirements

Set `require_san = false` for:

- **Client authentication certificates**: User certificates often have meaningful Subject DNs but no SAN
- **Legacy device certificates**: Older systems may not support SAN extension generation
- **Internal PKI**: Private infrastructures may rely solely on Subject DN for identification

```toml
[[est.label]]
name = "user-cert"
ca_id = "user-ca"
required_ext_key_usage = ["clientAuth", "emailProtection"]
require_san = false  # Allow subject-only certificates
```

## Subject DN Patterns

The `subject_pattern` field validates the Subject Distinguished Name of incoming CSRs using regular expressions. This prevents clients from requesting certificates with arbitrary subject fields.

### Pattern Syntax

```toml
# Exact CN match
subject_pattern = "^CN=server\\.example\\.com$"

# Domain restriction with variable hostname
subject_pattern = "^CN=[a-z0-9-]+\\.example\\.com$"

# Multiple RDN components
subject_pattern = "^CN=[^,]+,O=Example Corp,C=US$"

# Flexible ordering (less restrictive)
subject_pattern = "CN=[a-z0-9-]+\\.example\\.com"
```

The regex engine is Rust's `regex` crate, which supports standard PCRE-like syntax. Patterns are case-sensitive by default.

### Example: Locked-Down Production Label

```toml
[[est.label]]
name = "prod-server"
ca_id = "prod-ca"
subject_pattern = "^CN=(www|api|mail)\\.example\\.com(,O=Example Corp)?(,C=US)?$"
required_ext_key_usage = ["serverAuth"]
allowed_key_types = ["ecdsaP256", "ecdsaP384"]
```

This pattern only allows CSRs with CN values of `www.example.com`, `api.example.com`, or `mail.example.com`, with optional Organization and Country fields.

## Practical Examples

### Server TLS Label

Configuration for public-facing TLS server certificates following CA/B Forum requirements:

```toml
[[ca]]
id = "public-tls-ca"
cert_path = "/etc/kipuka/pki/tls-intermediate.crt"
key_path = "/etc/kipuka/pki/tls-intermediate.key"
default_validity_days = 365

[[est.label]]
name = "server-tls"
ca_id = "public-tls-ca"
allowed_key_types = ["ecdsaP256", "ecdsaP384", "rsa2048", "rsa3072"]
required_ext_key_usage = ["serverAuth"]
max_validity_days = 398  # CA/B Forum 398-day limit
require_san = true
subject_pattern = "^CN=[a-z0-9-]+\\.example\\.com$"
```

Client enrollment:

```bash
# Generate CSR with SAN
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -nodes -keyout server-key.pem -out server-csr.pem \
  -subj "/CN=web.example.com" \
  -addext "subjectAltName=DNS:web.example.com,DNS:www.example.com"

# Enroll via EST
curl --cacert ca.pem --cert client.pem --key client-key.pem \
  --data-binary @server-csr.pem \
  -H "Content-Type: application/pkcs10" \
  -o server-cert.p7 \
  https://est.example.com/.well-known/est/server-tls/simpleenroll

# Extract certificate from PKCS#7
openssl pkcs7 -in server-cert.p7 -inform DER -print_certs -out server.pem
```

### Client Authentication Label

Configuration for mutual TLS client certificates with shorter validity and relaxed SAN requirements:

```toml
[[ca]]
id = "client-ca"
cert_path = "/etc/kipuka/pki/client-intermediate.crt"
key_path = "/etc/kipuka/pki/client-intermediate.key"

[[est.label]]
name = "client-auth"
ca_id = "client-ca"
allowed_key_types = ["ecdsaP256", "rsa2048"]
required_ext_key_usage = ["clientAuth"]
max_validity_days = 90
require_san = false
subject_pattern = "^CN=[a-z]+\\.[a-z]+@example\\.com$"
```

Client enrollment:

```bash
# Generate CSR (no SAN required)
openssl req -new -newkey rsa:2048 -nodes \
  -keyout client-key.pem -out client-csr.pem \
  -subj "/CN=john.doe@example.com"

# Enroll via EST
curl --cacert ca.pem --cert bootstrap.pem --key bootstrap-key.pem \
  --data-binary @client-csr.pem \
  -H "Content-Type: application/pkcs10" \
  -o client-cert.p7 \
  https://est.example.com/.well-known/est/client-auth/simpleenroll

# Extract certificate
openssl pkcs7 -in client-cert.p7 -inform DER -print_certs -out client.pem
```

### Device Identity Label

Configuration for IoT device certificates with strict key type enforcement and short validity:

```toml
[[ca]]
id = "device-ca"
cert_path = "/etc/kipuka/pki/device-intermediate.crt"
key_path = "/etc/kipuka/pki/device-intermediate.key"

[[est.label]]
name = "device"
ca_id = "device-ca"
allowed_key_types = ["ecdsaP256"]  # P-256 only for embedded devices
required_ext_key_usage = ["clientAuth"]
max_validity_days = 30
require_san = true
subject_pattern = "^CN=device-[0-9a-f]{8}$"
```

Device enrollment:

```bash
# Generate CSR with device-specific CN and SAN
DEVICE_ID="device-a1b2c3d4"
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -nodes -keyout device-key.pem -out device-csr.pem \
  -subj "/CN=${DEVICE_ID}" \
  -addext "subjectAltName=URI:urn:uuid:a1b2c3d4-e5f6-7890-abcd-ef1234567890"

# Enroll via EST
curl --cacert ca.pem --cert device-bootstrap.pem --key device-bootstrap-key.pem \
  --data-binary @device-csr.pem \
  -H "Content-Type: application/pkcs10" \
  -o device-cert.p7 \
  https://est.example.com/.well-known/est/device/simpleenroll

# Extract certificate
openssl pkcs7 -in device-cert.p7 -inform DER -print_certs -out device.pem
```

## Label Selection Strategy

When designing your EST label architecture, consider:

1. **Certificate Purpose Separation**: Create distinct labels for server authentication, client authentication, email protection, and code signing. Never mix purposes in a single label.

2. **Security Posture**: Use restrictive labels for production workloads (`subject_pattern`, strict `allowed_key_types`) and permissive labels for development environments.

3. **Validity Period**: Match `max_validity_days` to certificate rotation cadence. Short-lived certificates (30-90 days) for automated systems, longer validity for manually managed certificates.

4. **CA Hierarchy Mapping**: Map labels to CAs based on trust requirements. Public-facing services may require certificates from a different CA than internal infrastructure.

5. **Client Capabilities**: Consider what key types and extensions your clients can generate. Legacy systems may require `require_san = false` and broader `allowed_key_types`.

## Label Discovery

Clients can discover available labels through the EST `/csrattrs` endpoint:

```bash
curl --cacert ca.pem --cert client.pem --key client-key.pem \
  https://est.example.com/.well-known/est/server-tls/csrattrs
```

However, RFC 7030 does not define a standard mechanism for enumerating all labels. Operators should document available labels and their intended purposes in client onboarding documentation.

## Validation Behavior

When a client submits a CSR to a labeled endpoint, kipuka performs validation in this order:

1. **Key type validation**: If `allowed_key_types` is set, reject CSRs with non-matching key algorithms
2. **SAN validation**: If `require_san = true`, reject CSRs without SAN extension
3. **Subject DN validation**: If `subject_pattern` is set, reject CSRs with non-matching Subject DN
4. **EKU injection**: Add `required_ext_key_usage` OIDs to the issued certificate (does not validate CSR EKUs)
5. **Validity enforcement**: Apply `max_validity_days` limit, overriding CA default if stricter

If any validation step fails, the EST server returns HTTP 400 Bad Request with an error message indicating which constraint was violated.

## Performance Considerations

Label lookups occur on every EST request. For deployments with hundreds of labels, ensure `kipuka.toml` is stored on fast local storage. Label matching is O(n) in the number of configured labels.

If you anticipate very large numbers of labels (>100), consider deploying multiple kipuka instances, each serving a subset of labels, behind a reverse proxy that routes based on URL path.
