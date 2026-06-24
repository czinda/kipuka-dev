# CA/B Forum Baseline Requirements

This page documents how kipuka enforces the CA/Browser Forum Baseline
Requirements (BR) for the issuance and management of publicly-trusted TLS
server certificates.  Operators issuing certificates under a
publicly-trusted root must configure kipuka to comply with these
requirements; operators running private PKI may relax some constraints
through configuration.

## Certificate Profile Enforcement

kipuka validates every CSR against the BR certificate profile before
signing.  A CSR that violates any of the following rules is rejected with an
`EnrollReject` audit event and an HTTP 400 response describing the
violation.

### Subject Fields

| Field | BR Requirement | kipuka Enforcement |
|-------|---------------|-------------------|
| `commonName` | Must match a SAN value if present | Validated at CSR parsing; rejected if CN is present but does not appear in the SAN extension |
| `organizationName` | Must be verified if included | kipuka does not verify organizational identity (this is a CA responsibility); operators can restrict allowed subjects via `est.label.subject_pattern` |
| `serialNumber` | Must be unique within the CA | Not included by default; kipuka does not inject Subject serial numbers |
| `countryName` | Two-letter ISO 3166 code if present | Format-validated at CSR parsing |

### Key Type Requirements

| Key Type | Minimum Size | kipuka Config |
|----------|-------------|--------------|
| RSA | 2048 bits | Enforced unconditionally; CSRs with RSA keys < 2048 are rejected |
| RSA | 3072 bits (recommended) | Configurable via `est.label.allowed_key_types` |
| ECDSA P-256 | 256 bits | Accepted |
| ECDSA P-384 | 384 bits | Accepted |
| ECDSA P-521 | 521 bits | Accepted but not recommended by BR |

To restrict a label to specific key types:

```toml
[[est.label]]
name = "web-servers"
ca_id = "issuing-ca-1"
allowed_key_types = ["rsa-3072", "rsa-4096", "ecdsa-p256", "ecdsa-p384"]
```

## Serial Number Generation

The BR requires that certificate serial numbers contain at least 64 bits of
output from a CSPRNG.

kipuka generates **160-bit** (20-byte) serial numbers, significantly
exceeding the minimum.  The generation path depends on configuration:

| Configuration | Source | Entropy |
|--------------|--------|---------|
| HSM configured | PKCS#11 `C_GenerateRandom` | 160 bits from HSM's FIPS-validated DRBG |
| Software-only | `getrandom(2)` | 160 bits from OS CSPRNG |

Serial numbers are encoded as unsigned integers in the `serialNumber` field
of the `TBSCertificate`, with the high bit set to zero to ensure a positive
ASN.1 INTEGER encoding (per RFC 5280 section 4.1.2.2).

## Extension Enforcement

kipuka enforces the following extensions on every issued certificate.
Extensions not listed here may be added via CSR attributes or label
configuration but are not required by the BR.

### Mandatory Extensions

| Extension | OID | BR Requirement | kipuka Behavior |
|-----------|-----|---------------|----------------|
| Authority Key Identifier (AKI) | 2.5.29.35 | Must be present (non-critical) | Always injected using the SHA-1 hash of the CA's public key |
| Subject Key Identifier (SKI) | 2.5.29.14 | Must be present (non-critical) | Always injected using the SHA-1 hash of the end-entity public key |
| Basic Constraints | 2.5.29.19 | `CA:FALSE` for end-entity (critical) | Always set to `CA:FALSE` with `pathLenConstraint` absent |
| Key Usage | 2.5.29.15 | Must be present (critical) | Set from `ca.default_key_usage`; defaults to `digitalSignature, keyEncipherment` for RSA, `digitalSignature` for ECDSA |
| Extended Key Usage | 2.5.29.37 | Must include `id-kp-serverAuth` for TLS certificates | Set from `ca.default_ext_key_usage`; default includes `serverAuth` |
| Subject Alternative Name (SAN) | 2.5.29.17 | Must be present; CN deprecated as identity source | kipuka requires SAN by default (`est.label.require_san = true`).  SAN values from the CSR are passed through to the certificate. |
| Certificate Policies | 2.5.29.32 | Must reference applicable CP/CPS | Operators configure this via label-level certificate profile settings |

### Extension Validation Rules

- If the CSR contains a `basicConstraints` extension with `CA:TRUE`,
  kipuka rejects the request.  CA certificates are issued through the
  admin API, not through EST enrollment.

- If the CSR's Key Usage includes `keyCertSign` or `cRLSign`, the request
  is rejected.

- SAN entries are validated for syntactic correctness: DNS names must be
  valid hostnames (no wildcards unless explicitly enabled), IP addresses
  must parse as IPv4 or IPv6, and email addresses must contain exactly one
  `@`.

## Validity Period Enforcement

The CA/B Forum is reducing maximum certificate validity on a declining
timeline.  kipuka tracks this timeline through the `max_validity_days`
configuration parameter.

### BR Validity Timeline

| Effective Date | Maximum Validity | Maximum `notBefore` to `notAfter` | Recommended `max_validity_days` |
|---------------|-----------------|----------------------------------|-------------------------------|
| Current | 398 days | 398 days | `398` |
| 15 March 2026 | 200 days | 200 days | `200` |
| 15 March 2027 | 100 days | 100 days | `100` |
| 15 March 2029 | 47 days | 47 days | `47` |

### Configuration

Each CA and each EST label can specify a maximum validity:

```toml
[[ca]]
id = "public-ca"
name = "Public TLS CA"
cert = "/etc/kipuka/ca/public-ca.pem"
key = "/etc/kipuka/ca/public-ca.key"
validity_days = 90
max_validity_days = 200
```

```toml
[[est.label]]
name = "short-lived"
ca_id = "public-ca"
max_validity_days = 47
```

The effective maximum validity for a certificate is the **minimum** of:

1. The CA's `max_validity_days`
2. The label's `max_validity_days` (if set)
3. The client's requested validity (if the CSR includes a
   `ValidityPeriod` attribute)

If the client's requested validity exceeds the effective maximum, kipuka
clamps the `notAfter` date to the allowed maximum rather than rejecting the
request.  This behavior is logged as an audit event with the original and
clamped values.

### STAR Integration

For STAR (RFC 8739) auto-renewal certificates, the validity period is
typically much shorter than the BR maximum -- often hours or days.  STAR
renewal orders track their own validity interval independently of the
label's `max_validity_days`.

## Server-Side Key Generation Compliance

The `/serverkeygen` endpoint generates a key pair on the server and returns
the private key to the client.  The BR imposes requirements on how this
private key is protected in transit.

### Key Generation

- Key pairs are generated using the same CSPRNG path as serial numbers
  (PKCS#11 `C_GenerateKeyPair` when an HSM is configured, Synta software
  otherwise).
- The generated key type and size must satisfy the same minimums as
  client-generated keys (RSA >= 2048, ECDSA P-256 or P-384).
- The private key exists in kipuka's memory only for the duration of the
  request.  It is not written to disk or database.

### Key Transport

The private key is returned to the client in a PKCS#7 `EnvelopedData`
structure:

| Component | Algorithm | Notes |
|-----------|-----------|-------|
| Content encryption | AES-256-CBC or AES-256-GCM | Symmetric encryption of the private key |
| Key wrapping (RSA) | RSA-OAEP (SHA-256) | Wraps the CEK to the client's public key from the CSR |
| Key wrapping (ECDH) | ECDH-ES + AES-256-WRAP | Key agreement with the client's EC public key |

The response is a multipart MIME message containing:

1. The signed certificate (`application/pkcs7-mime; smime-type=certs-only`)
2. The encrypted private key (`application/pkcs8`)

### Implementation Location

`kipuka_est::serverkeygen` handles key generation, wrapping, and response
construction.

## Name Constraints and Encoding

### Distinguished Name Encoding

All Distinguished Name components are encoded as `UTF8String` per RFC 5280
section 4.1.2.4 and BR section 7.1.4.  kipuka does not use `PrintableString`
or `TeletexString` encoding for any DN attribute.

### Name Constraints

kipuka supports Name Constraints through CA configuration.  When a CA
certificate contains a Name Constraints extension, kipuka enforces those
constraints at CSR validation time:

- **Permitted subtrees** -- SAN DNS names must fall within the permitted
  DNS name subtrees.  IP addresses must fall within permitted IP ranges.
- **Excluded subtrees** -- SAN entries matching excluded subtrees cause
  CSR rejection.

This enforcement happens before signing, so a constraint violation results
in an `EnrollReject` audit event rather than an improperly-issued
certificate.

### Internationalized Domain Names

kipuka accepts internationalized domain names (IDN) in SAN `dNSName`
entries only in their A-label (Punycode) form, per BR section 7.1.4.2.
U-label (Unicode) forms are rejected at CSR validation.

## Compliance Checklist

The following checklist summarizes BR compliance status for operators
running kipuka under a publicly-trusted root.

| Requirement | BR Section | Status | Configuration |
|-------------|-----------|--------|---------------|
| RSA >= 2048 bits | 6.1.5 | Enforced | Unconditional |
| ECDSA P-256 or P-384 | 6.1.5 | Enforced | Unconditional |
| Serial >= 64 bits CSPRNG | 7.1 | Exceeded (160 bits) | Unconditional |
| AKI present | 7.1.2.7 | Enforced | Unconditional |
| SKI present | 7.1.2.8 | Enforced | Unconditional |
| `CA:FALSE` for EE certs | 7.1.2.3 | Enforced | Unconditional |
| Key Usage critical | 7.1.2.1 | Enforced | Unconditional |
| SAN required | 7.1.4.2 | Default `true` | `est.label.require_san` |
| Max validity period | 6.3.2 | Enforced | `ca.max_validity_days`, `est.label.max_validity_days` |
| `/serverkeygen` key protection | 6.1.2 | Enforced | PKCS#7 EnvelopedData transport |
| Certificate Policies extension | 7.1.2.2 | Operator-configured | Label certificate profile |
| DN encoding (UTF8String) | 7.1.4 | Enforced | Unconditional |
