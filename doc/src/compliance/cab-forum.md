# CA/B Forum Baseline Requirements

This page documents compliance with the CA/Browser Forum Baseline
Requirements for the Issuance and Management of Publicly-Trusted TLS
Server Certificates, **Version 2.2.8** (16-Jun-2026).  Operators issuing
certificates under a publicly-trusted root must configure kipuka and the
issuing CA to satisfy these requirements jointly; operators running
private PKI may relax constraints through configuration.

## Responsibility Boundary

kipuka is a Registration Authority (RA) and enrollment server.  It
validates CSRs and enforces certificate profile constraints, but it does
not perform domain validation, CAA checking, or revocation services.
Those responsibilities belong to the issuing Certification Authority.

The following table maps each BR area to the specific software component
that owns it.  When deploying under a publicly-trusted root, all
affected components must be configured correctly.

| BR Area | Component | Crate / Subsystem | Status | Notes |
|---------|-----------|-------------------|--------|-------|
| CSR validation (key size, SAN, extensions) | kipuka | `kipuka-est` | Enforced | Profile enforcement at enrollment |
| RSA exponent / key quality checks | kipuka | `kipuka-est` + `synta` | Not Implemented | §6.1.6 quality checks |
| Weak key rejection (Debian/ROCA/Fermat) | kipuka | `kipuka-est` | Not Implemented | Blocklist checks needed |
| Serial number generation | kipuka | `kipuka-est` (+ `kipuka-hsm`) | Enforced | 160-bit CSPRNG |
| Certificate construction (extensions, profile) | kipuka | `synta` | Enforced | AKI, SKI, BC, KU, EKU, SAN |
| AIA / CDP injection | kipuka | `synta` | Not Implemented | Should be added to cert construction |
| Certificate Policies (Reserved OIDs) | kipuka | `synta` | Partial | Operator-configured, no OID enforcement |
| Validity period clamping | kipuka | `kipuka-est` | Enforced | Declining timeline tracked |
| `notBefore` 48-hour enforcement | kipuka | `kipuka-est` | Not Enforced | Should validate at signing time |
| SHA-1 signing rejection | kipuka | `kipuka-est` | Not Enforced | Should reject SHA-1 algorithm requests |
| `organizationalUnitName` prohibition | kipuka | `kipuka-est` | Not Implemented | Should strip/reject OU |
| Server-side key generation + transport | kipuka | `kipuka-est` + `synta` | Enforced | PKCS#7 EnvelopedData |
| OTP authentication | kipuka | `kipuka-otp` | Enforced | Enrollment authentication |
| HSM key operations | kipuka | `kipuka-hsm` | Enforced | PKCS#11 signing + serial generation |
| CoAP/DTLS transport | kipuka | `kipuka-coap` | Enforced | Shares EST enrollment logic |
| Audit logging (enrollment events) | kipuka | `kipuka-est` | Enforced | `EnrollReject`, `EnrollSuccess` |
| Certificate linting (pre-sign) | kipuka | `kipuka-est` | Not Implemented | zlint/certlint integration |
| Dogtag CA REST integration | kipuka | `kipuka-dogtag` | Enforced | Profile-based issuance delegation |
| Domain validation (DCV) | Dogtag | `base/acme` | CA Responsibility | HTTP-01 / DNS-01 |
| CAA record processing | Dogtag | `base/ca` | Not Implemented | RFC 8659 -- no code exists |
| DNSSEC validation of CAA | Dogtag | `base/ca` | Not Implemented | Must validate to IANA root |
| Multi-Perspective Issuance Corroboration | Dogtag | `base/acme` | Not Implemented | Requires MPIC infrastructure |
| Certificate Transparency (SCT) | Dogtag | `base/ca` (`CTEngine`) | Available | Precert + SCT embedding |
| Certificate linting (post-sign) | Dogtag | `base/ca` | Not Implemented | Pre-signing lint of tbsCertificate |
| OCSP responder | Dogtag | `base/ocsp` | Available | Standalone or CA-embedded |
| CRL generation and publishing | Dogtag | `base/ca` (`CRLIssuingPoint`) | Available | Auto-update configurable |
| Revocation processing | Dogtag | `base/ca` (`ServiceRevoke`) | Available | With CRLReason codes |
| Key archival / escrow | Dogtag | `base/kra` | Available | KRA subsystem |
| Signed audit logging | Dogtag | `base/server` (`SignedAuditLogger`) | Available | 56+ event types |

## Certificate Profile Enforcement

kipuka validates every CSR against the BR certificate profile before
forwarding to the CA for signing.  A CSR that violates any rule is
rejected with an `EnrollReject` audit event and an HTTP 400 response.

### Subject Fields

| Field | BR Requirement | kipuka Enforcement | Status |
|-------|---------------|-------------------|--------|
| `commonName` | Must match a SAN value if present (§7.1.4.3) | Validated at CSR parsing; rejected if CN does not appear in SAN | Enforced |
| `organizationName` | Must be verified if included (§3.2.2.2) | kipuka does not verify organizational identity; operators can restrict via `est.label.subject_pattern` | CA Responsibility |
| `organizationalUnitName` | MUST NOT be included in subscriber certs (§7.1.2.10.2) | Not enforced -- kipuka does not strip or reject OU | Not Implemented |
| `serialNumber` | Must be unique within the CA | Not included by default | N/A |
| `countryName` | Two-letter ISO 3166 code if present (§3.2.2.3) | Format-validated at CSR parsing | Enforced |

### Key Type and Size Requirements (§6.1.5)

| Key Type | Minimum Size | kipuka Enforcement | Status |
|----------|-------------|-------------------|--------|
| RSA | 2048 bits | Rejected if < 2048 | Enforced |
| RSA | 3072 bits (recommended) | Configurable via `est.label.allowed_key_types` | Configurable |
| ECDSA P-256 | 256 bits | Accepted | Enforced |
| ECDSA P-384 | 384 bits | Accepted | Enforced |
| ECDSA P-521 | 521 bits | Accepted but not recommended by BR | Enforced |

To restrict a label to specific key types:

```toml
[[est.label]]
name = "web-servers"
ca_id = "issuing-ca-1"
allowed_key_types = ["rsa-3072", "rsa-4096", "ecdsa-p256", "ecdsa-p384"]
```

### Public Key Quality Checks (§6.1.6)

| Check | BR Requirement | Status |
|-------|---------------|--------|
| RSA public exponent is odd and >= 3 | SHALL confirm (§6.1.6) | Not Implemented |
| RSA exponent in range 2^16+1 to 2^256-1 | SHOULD (§6.1.6) | Not Implemented |
| RSA modulus divisible by 8, not prime power, no factors < 752 | SHOULD (§6.1.6) | Not Implemented |
| ECDSA point validation (ECC Full or Partial) | SHOULD (§6.1.6) | Not Implemented |

### Weak Key Rejection (§6.1.1.3)

The BR requires CAs to reject keys known to be weak.  kipuka does not
currently perform weak key checks.

| Check | Source | Status |
|-------|--------|--------|
| Debian weak keys | [github.com/cabforum/Debian-weak-keys](https://github.com/cabforum/Debian-weak-keys/) | Not Implemented |
| ROCA vulnerability | [github.com/crocs-muni/roca](https://github.com/crocs-muni/roca) | Not Implemented |
| Close Primes (Fermat factorization, 100 rounds) | [fermatattack.secvuln.info](https://fermatattack.secvuln.info/) | Not Implemented |

## Serial Number Generation

The BR requires that certificate serial numbers contain at least 64 bits
of output from a CSPRNG (§7.1).

kipuka generates **160-bit** (20-byte) serial numbers, significantly
exceeding the minimum.  Serial numbers must be non-sequential, greater
than zero, and less than 2^159.

| Configuration | Source | Entropy |
|--------------|--------|---------|
| HSM configured | PKCS#11 `C_GenerateRandom` | 160 bits from HSM's FIPS-validated DRBG |
| Software-only | `getrandom(2)` | 160 bits from OS CSPRNG |

Serial numbers are encoded as unsigned integers with the high bit set to
zero to ensure a positive ASN.1 INTEGER encoding (per RFC 5280 §4.1.2.2).

## Extension Enforcement

### Mandatory Extensions (§7.1.2.7.6)

| Extension | OID | BR Presence | Critical | kipuka Behavior | Status |
|-----------|-----|------------|----------|----------------|--------|
| Authority Key Identifier | 2.5.29.35 | MUST | N | Injected using SHA-1 hash of CA public key | Enforced |
| Subject Key Identifier | 2.5.29.14 | NOT RECOMMENDED | N | Injected using SHA-1 hash of EE public key | Enforced |
| Basic Constraints | 2.5.29.19 | MAY | Y | `CA:FALSE`, `pathLenConstraint` absent | Enforced |
| Key Usage | 2.5.29.15 | SHOULD | Y | Set from `ca.default_key_usage` | Enforced |
| Extended Key Usage | 2.5.29.37 | MUST | N | `serverAuth` MUST, `clientAuth` MAY | Enforced |
| Subject Alternative Name | 2.5.29.17 | MUST | * | Required by default (`est.label.require_san = true`) | Enforced |
| Authority Information Access | 2.5.29.35.1 | MUST | N | Not injected by kipuka; CA profile responsibility | Not Implemented |
| Certificate Policies | 2.5.29.32 | MUST | N | Operator-configured via label profile | Partial |
| CRL Distribution Points | 2.5.29.31 | * | N | Not injected by kipuka; CA profile responsibility | Not Implemented |

**Notes:**

- AIA MUST contain at least one `AccessDescription`.  The
  `id-ad-caIssuers` method (SHOULD) provides a URL to the issuing CA's
  certificate.  When using Dogtag, this is set in the certificate profile.
- CRL Distribution Points presence depends on whether the certificate
  includes an AIA OCSP pointer and the certificate's validity period
  (§7.1.2.11.2).
- Certificate Policies MUST include a Reserved Certificate Policy
  Identifier matching the validation type: DV (2.23.140.1.2.1), IV
  (2.23.140.1.2.3), OV (2.23.140.1.2.2), or EV (2.23.140.1.1).  kipuka
  does not enforce the correct OID per validation type.

### Extension Validation Rules

- CSRs with `basicConstraints CA:TRUE` are rejected.
- CSRs with Key Usage `keyCertSign` or `cRLSign` are rejected.
- `pathLenConstraint` MUST NOT be present in subscriber certificates
  (§7.1.2.7.8).  kipuka does not include it, but does not actively reject
  CSRs that request it.
- SAN entries are validated: DNS names must be valid hostnames (no
  wildcards unless enabled), IP addresses must parse as IPv4/IPv6, email
  addresses must contain exactly one `@`.
- `notBefore` MUST be within 48 hours of the certificate signing
  operation (§7.1.2.7).  kipuka does not enforce this constraint.

### Subscriber Certificate Key Usage (§7.1.2.7.11)

For RSA keys, `digitalSignature` SHOULD be set.  `keyEncipherment` MAY
be set for TLS 1.2 compatibility.  `dataEncipherment` is a Pending
Prohibition.

For ECC keys, `digitalSignature` MUST be set.  `keyAgreement` is a
Pending Prohibition.

kipuka defaults: `digitalSignature, keyEncipherment` for RSA,
`digitalSignature` for ECDSA.  Configurable via `ca.default_key_usage`.

### Subscriber Certificate EKU (§7.1.2.7.10)

| Key Purpose | OID | BR Presence | kipuka Default |
|-------------|-----|------------|---------------|
| `id-kp-serverAuth` | 1.3.6.1.5.5.7.3.1 | MUST | Included |
| `id-kp-clientAuth` | 1.3.6.1.5.5.7.3.2 | MAY | Included |
| `id-kp-codeSigning` | 1.3.6.1.5.5.7.3.3 | MUST NOT | Not included |
| `id-kp-emailProtection` | 1.3.6.1.5.5.7.3.4 | MUST NOT | Not included |
| `id-kp-timeStamping` | 1.3.6.1.5.5.7.3.8 | MUST NOT | Not included |
| `id-kp-OCSPSigning` | 1.3.6.1.5.5.7.3.9 | MUST NOT | Not included |
| `anyExtendedKeyUsage` | 2.5.29.37.0 | MUST NOT | Not included |

## Validity Period Enforcement (§6.3.2)

The CA/B Forum is reducing maximum certificate validity on a declining
timeline.  kipuka tracks this through the `max_validity_days` parameter.

| Issued on or after | Issued before | SHOULD NOT exceed | MUST NOT exceed | Recommended config |
|-------------------|--------------|-------------------|-----------------|-------------------|
| -- | 2026-03-15 | 397 days | 398 days | `398` |
| 2026-03-15 | 2027-03-15 | 199 days | 200 days | `200` |
| 2027-03-15 | 2029-03-15 | 99 days | 100 days | `100` |
| 2029-03-15 | -- | 46 days | 47 days | `47` |

For the purpose of these calculations, a day is measured as 86,400
seconds.  Any amount of time greater than this, including fractional
seconds and/or leap seconds, represents an additional day.  Certificates
SHOULD NOT be issued for the maximum permissible time by default, to
account for clock drift.

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

The effective maximum is the **minimum** of the CA's `max_validity_days`,
the label's `max_validity_days`, and the client's requested validity.
If the client requests more, kipuka clamps `notAfter` to the allowed
maximum and logs the original and clamped values.

### STAR Integration

STAR (RFC 8739) auto-renewal certificates typically use much shorter
validity periods (hours or days).  STAR renewal orders track their own
interval independently of `max_validity_days`.

## Domain Validation

kipuka does **not** perform domain validation.  This is a CA
responsibility.  When using Dogtag as the issuing CA, the ACME subsystem
provides HTTP-01 and DNS-01 challenge validation.

### Validation Data Reuse (§4.2.1)

Domain and IP address validation data has maximum reuse periods that
decline over time:

| Issued on or after | Issued before | Max reuse period |
|-------------------|--------------|-----------------|
| -- | 2026-03-15 | 398 days |
| 2026-03-15 | 2027-03-15 | 200 days |
| 2027-03-15 | 2029-03-15 | 100 days |
| 2029-03-15 | -- | 10 days |

### Prohibited Names (§4.2.2)

CAs SHALL NOT issue certificates containing Internal Names or Reserved
IP Addresses.  Effective 2026-03-15, certificates SHALL NOT contain
Domain Names ending in an IP Reverse Zone Suffix.

## CAA Record Processing (§4.2.2.1)

**Status: CA Responsibility -- not implemented in Dogtag.**

The CA MUST retrieve and process CAA records in accordance with RFC 8659
for each `dNSName` in the `subjectAltName` extension before certificate
issuance.  The CA MUST process the `issue`, `issuewild`, and `iodef`
property tags.

| Requirement | BR Section | Effective | Status |
|-------------|-----------|-----------|--------|
| CAA record retrieval and processing | §4.2.2.1 | Current | Not Implemented |
| Process `accounturi` and `validationmethods` parameters | §4.2.2.1.2 | SHOULD now, MUST 2027-03-15 | Not Implemented |
| DNSSEC validation of CAA queries to IANA root trust anchor | §4.2.2.1.3 | 2026-03-15 | Not Implemented |
| DNSSEC SERVFAIL is NOT permission to issue | §4.2.2.1.3 | 2026-03-15 | Not Implemented |

**Impact:** Neither kipuka nor Dogtag currently implements CAA checking.
Any deployment under a publicly-trusted root must add CAA processing
upstream or implement it in the CA before issuance.

## Multi-Perspective Issuance Corroboration (§3.2.2.9)

**Status: CA Responsibility -- not implemented in Dogtag.**

The CA MUST corroborate domain validation and CAA checks from multiple
remote Network Perspectives before certificate issuance.

| Effective | Min Remote Perspectives | Min RIR Regions | Quorum (non-corroborations allowed) |
|-----------|------------------------|----------------|-----------------------------------|
| 2025-03-15 | 2 | -- | Per Quorum Table |
| 2026-03-15 | 3 | 2 | Per Quorum Table |
| 2026-06-15 | 4 | 2 | Per Quorum Table |
| 2026-12-15 | 5 | 2 | Per Quorum Table |

Quorum table (Table 5 of the BR):

| Remote Perspectives Used | Max Non-Corroborations |
|--------------------------|----------------------|
| 2--5 | 1 |
| 6+ | 2 |

**Impact:** This requirement is already in effect.  Deployments under
publicly-trusted roots cannot issue certificates without MPIC
infrastructure.

## Certificate Transparency (§4.3.1.2, §7.1.2.9)

**Status: CA Responsibility -- available in Dogtag.**

| Requirement | BR Section | Status |
|-------------|-----------|--------|
| Lint to-be-signed certificate content before signing | §4.3.1.2 | Not Implemented |
| Submit Precertificate to CT logs | §7.1.2.9 | Available in Dogtag (`CTEngine.java`) |
| Embed SCT list in final certificate | §7.1.2.9 | Available in Dogtag (`caServerCertWithSCT.cfg`) |
| Precertificate Signing CA profile (sunset 2026-03-15) | §7.1.2.4 | N/A (already past effective date) |

When using Dogtag with CT enabled, the CA creates a precertificate with
the poison extension (OID 1.3.6.1.4.1.11129.2.4.3), submits it to
configured CT logs, and replaces the poison with an SCT list extension
(OID 1.3.6.1.4.1.11129.2.4.2) in the final certificate.  kipuka
receives the final certificate with embedded SCTs and returns it to the
client.

## Certificate Linting (§4.3.1.2)

**Status: Not Implemented in either component.**

Effective 2025-03-15, the CA SHALL implement a Linting process to test
the technical conformity of each to-be-signed certificate artifact prior
to signing.  CAs SHOULD use widely-adopted Linting tools (see
[cabforum.org/resources/tools](https://cabforum.org/resources/tools/)).

Linting could be split across the stack: kipuka could lint the CSR and
proposed certificate content pre-submission, while the CA lints the
to-be-signed `tbsCertificate` post-assembly.  Neither integration
exists today.

## Revocation and OCSP

### Revocation Requirements (§4.9)

**Status: CA Responsibility.**

| Requirement | BR Section | Dogtag Support |
|-------------|-----------|---------------|
| Revoke within 24 hours for key compromise, mis-issuance, failed CAA | §4.9.1.1 | `ServiceRevoke` handles revocation |
| Revoke within 5 days for non-critical reasons | §4.9.1.1 | Supported |
| Investigate Certificate Problem Reports within 24 hours | §4.9.5 | Operational procedure |
| 24x7 revocation request acceptance | §4.9.3 | Dogtag web UI + REST API |
| Mass revocation plan with 9 provisions | §5.7.1.2 | Operational procedure (effective 2025-12-01) |

### CRL Requirements (§4.9.7)

| Requirement | Frequency | Dogtag Support |
|-------------|----------|---------------|
| Subscriber cert CRL (with AIA OCSP pointer) | At least every 7 days | `CRLIssuingPoint` auto-update |
| Subscriber cert CRL (without OCSP pointer) | At least every 4 days | Configurable |
| CRL after revocation | Within 24 hours | Immediate on `ServiceRevoke` |
| CA certificate CRL | At least every 12 months | Configurable |

### OCSP Requirements (§4.9.9)

| Requirement | BR Section | Status |
|-------------|-----------|--------|
| OCSP response available within 15 minutes of issuance | §4.9.9 | CA Responsibility (effective 2025-01-15) |
| OCSP GET method support | §4.9.9 | Dogtag `CAOCSPServlet` |
| OCSP validity < 16 hours: update before half validity | §4.9.9 | Configurable in Dogtag |
| OCSP validity >= 16 hours: update at least 8 hours before nextUpdate, no later than 4 days after thisUpdate | §4.9.9 | Configurable in Dogtag |
| MUST NOT respond "unknown" for issued certs (effective 2025-01-15) | §4.9.9 | Dogtag CRL-based OCSP |

## SHA-1 Sunset (§7.1.3.2)

**Status: Not Enforced.**

| Requirement | Effective | Status |
|-------------|----------|--------|
| SHA-1 MUST NOT be used in certificate signatures | Current | kipuka does not validate signing algorithm |
| SHA-1 MUST NOT be used in CRL signatures | 2026-09-15 | CA Responsibility |

kipuka should reject enrollment requests that specify SHA-1 as the
signature algorithm.  This check is not currently implemented.

## Server-Side Key Generation (§6.1.2)

The `/serverkeygen` endpoint generates a key pair and returns the
private key to the client in a PKCS#7 `EnvelopedData` structure.

| Component | Algorithm | Notes |
|-----------|-----------|-------|
| Content encryption | AES-256-CBC or AES-256-GCM | Symmetric encryption of the private key |
| Key wrapping (RSA) | RSA-OAEP (SHA-256) | Wraps the CEK to the client's public key |
| Key wrapping (ECDH) | ECDH-ES + AES-256-WRAP | Key agreement with client's EC public key |

Additional BR constraints:

- If the subscriber certificate will contain `id-kp-serverAuth`, the CA
  SHALL NOT generate a key pair on behalf of the subscriber and SHALL NOT
  accept a certificate request using a key pair previously generated by
  the CA (§6.1.1.3).  kipuka does not enforce this cross-request check.
- Parties other than the Subscriber SHALL NOT archive the Subscriber
  Private Key without authorization (§6.1.2).
- Key pairs are generated using the same CSPRNG path as serial numbers
  and exist in kipuka's memory only for the duration of the request.

## Name Constraints and Encoding

### Distinguished Name Encoding (§7.1.4)

All Distinguished Name components are encoded as `UTF8String` per
RFC 5280 §4.1.2.4 and BR §7.1.4.  kipuka does not use `PrintableString`
or `TeletexString` encoding.

### Name Constraints

kipuka enforces Name Constraints from the CA certificate at CSR
validation time:

- **Permitted subtrees** -- SAN DNS names must fall within permitted DNS
  subtrees.  IP addresses must fall within permitted IP ranges.
- **Excluded subtrees** -- SAN entries matching excluded subtrees cause
  rejection.

Enforcement before signing means a constraint violation produces an
`EnrollReject` audit event rather than a mis-issued certificate.

### Internationalized Domain Names (§7.1.4.2)

kipuka accepts IDN in SAN `dNSName` entries only in A-label (Punycode)
form.  U-label (Unicode) forms are rejected at CSR validation.

## Compliance Timeline

Operators deploying kipuka under a publicly-trusted root should track
these upcoming BR deadlines:

| Date | Section | Requirement | Affected Component |
|------|---------|------------|-------------------|
| **Already effective** | §4.2.2.1.3 | DNSSEC validation on CAA queries | Dogtag `base/ca` |
| **Already effective** | §3.2.2.9 | MPIC with 4 remote perspectives | Dogtag `base/acme` |
| **Already effective** | §4.3.1.2 | Certificate linting before signing | `kipuka-est` + Dogtag `base/ca` |
| **Already effective** | §4.9.9 | OCSP available within 15 minutes | Dogtag `base/ocsp` |
| **Already effective** | §6.3.2 | Max validity 200 days | `kipuka-est` |
| 2026-07-15 | §5.4.1 | Verification logs must include specific information | `kipuka-est` + Dogtag `base/server` |
| 2026-09-15 | §7.1.3.2.1 | SHA-1 sunset in certificates and CRLs | `kipuka-est` + `synta` + Dogtag `base/ca` |
| 2026-12-15 | §3.2.2.9 | MPIC with 5 remote perspectives, 2 RIR regions | Dogtag `base/acme` |
| 2027-03-15 | §4.2.2.1.2 | MUST process `accounturi` and `validationmethods` | Dogtag `base/ca` |
| 2027-03-15 | §3.2.2.4 | Sunset DCV methods §3.2.2.4.16+, §3.2.2.5.3 | Dogtag `base/acme` |
| 2027-03-15 | §6.3.2 | Max validity 100 days | `kipuka-est` |
| 2029-03-15 | §6.3.2 | Max validity 47 days | `kipuka-est` |
| 2029-03-15 | §4.2.1 | DCV data reuse max 10 days | Dogtag `base/acme` |

## Compliance Checklist

| Requirement | BR Section | Component | Status |
|-------------|-----------|-----------|--------|
| RSA >= 2048 bits | §6.1.5 | `kipuka-est` | Enforced |
| ECDSA P-256/P-384/P-521 | §6.1.5 | `kipuka-est` | Enforced |
| RSA exponent validation | §6.1.6 | `kipuka-est` + `synta` | Not Implemented |
| Weak key rejection (Debian/ROCA/Fermat) | §6.1.1.3 | `kipuka-est` | Not Implemented |
| Serial >= 64 bits CSPRNG | §7.1 | `kipuka-est` (+ `kipuka-hsm`) | Exceeded (160 bits) |
| AKI present | §7.1.2.11.1 | `synta` | Enforced |
| SKI present | §7.1.2.11.4 | `synta` | Enforced |
| `CA:FALSE` for EE certs | §7.1.2.7.8 | `synta` | Enforced |
| `pathLenConstraint` MUST NOT for EE | §7.1.2.7.8 | `synta` | Enforced (absent) |
| Key Usage critical | §7.1.2.7.11 | `synta` | Enforced |
| EKU with `serverAuth` | §7.1.2.7.10 | `synta` | Enforced |
| SAN required | §7.1.2.7.12 | `kipuka-est` | Enforced |
| CN matches SAN | §7.1.4.3 | `kipuka-est` | Enforced |
| AIA present (OCSP, caIssuers) | §7.1.2.7.7 | `synta` | Not Implemented |
| CRL Distribution Points | §7.1.2.11.2 | `synta` | Not Implemented |
| Certificate Policies with Reserved OID | §7.1.2.7.9 | `synta` | Partial |
| `organizationalUnitName` prohibited | §7.1.2.10.2 | `kipuka-est` | Not Implemented |
| Max validity period | §6.3.2 | `kipuka-est` | Enforced |
| `notBefore` within 48 hours | §7.1.2.7 | `kipuka-est` | Not Enforced |
| DN encoding (UTF8String) | §7.1.4 | `synta` | Enforced |
| IDN A-label only | §7.1.4.2 | `kipuka-est` | Enforced |
| Name Constraints enforcement | §7.1.5 | `kipuka-est` | Enforced |
| `/serverkeygen` key protection | §6.1.2 | `kipuka-est` + `synta` | Enforced |
| SHA-1 signing rejection | §7.1.3.2 | `kipuka-est` | Not Enforced |
| Domain validation | §3.2.2.4 | Dogtag `base/acme` | CA Responsibility |
| CAA record processing | §4.2.2.1 | Dogtag `base/ca` | Not Implemented |
| DNSSEC validation of CAA | §4.2.2.1.3 | Dogtag `base/ca` | Not Implemented |
| Multi-Perspective Issuance | §3.2.2.9 | Dogtag `base/acme` | Not Implemented |
| Certificate Transparency | §4.3.1.2 | Dogtag `base/ca` (`CTEngine`) | Available |
| Certificate linting (pre-sign) | §4.3.1.2 | `kipuka-est` | Not Implemented |
| Certificate linting (post-sign) | §4.3.1.2 | Dogtag `base/ca` | Not Implemented |
| OCSP within 15 minutes | §4.9.9 | Dogtag `base/ocsp` | Available |
| CRL issuance frequency | §4.9.7 | Dogtag `base/ca` | Available |
| Revocation processing | §4.9.1 | Dogtag `base/ca` | Available |
| Mass revocation plan | §5.7.1.2 | Operational | Procedure required |
