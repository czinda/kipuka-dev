# RFC Support Reference

This page documents every standards specification that kipuka implements,
which sections are covered, and any caveats relevant to conformance testing.

## Core Enrollment Standards

### RFC 7030 -- Enrollment over Secure Transport (EST)

| Section | Operation | Status | Notes |
|---------|-----------|--------|-------|
| 4.1 | `/cacerts` | Implemented | Returns the CA certificate chain as a PKCS#7 `certs-only` message.  Unauthenticated; available without client credentials. |
| 4.2 | `/simpleenroll` | Implemented | PKCS#10 CSR in, signed certificate out.  Supports OTP, mTLS, GSSAPI, and CMS-based authentication. |
| 4.2.2 | `/simplereenroll` | Implemented | Renewal with the existing client certificate presented via mTLS.  Subject and SAN matching enforced by default. |
| 4.3 | `/fullcmc` | Implemented | Full CMC (RFC 5272) request/response over the EST transport.  Disabled by default; enable with `est.fullcmc = true`. |
| 4.4 | `/serverkeygen` | Implemented | Server generates the key pair; returns a PKCS#7 `EnvelopedData` wrapping the private key and the signed certificate.  Disabled by default. |
| 4.5 | `/csrattrs` | Implemented | Returns a DER-encoded sequence of OIDs and attribute definitions the server expects in a CSR. |
| 3.2 | EST-over-TLS binding | Implemented | All endpoints served over TLS 1.2 or 1.3 via `rustls`.  The well-known URI prefix `/.well-known/est` is configurable via `est.base_path`. |
| 3.2.2 | EST labels | Implemented | Label-specific paths (`/.well-known/est/{label}/...`) route to per-CA configurations with independent certificate profiles, allowed key types, and validity limits. |
| 3.3.2 | HTTP-based client auth | Implemented | HTTP-layer authentication (OTP via `Authorization` header) supplements TLS-layer mTLS authentication. |
| 4.2.3 | `Retry-After` handling | Implemented | When a request is deferred (e.g., pending manual approval), kipuka returns HTTP 202 with a `Retry-After` header.  The interval is configurable via `est.retry_after`. |
| 3.5 | Linking identity and POP | Implemented | Proof-of-Possession via CSR self-signature is verified.  When mTLS is used, the binding between the TLS identity and the CSR subject is enforced. |

### RFC 8951 -- Clarifications for EST

RFC 8951 addresses ambiguities in RFC 7030.  kipuka incorporates all
clarifications that affect server behavior:

| Clarification | Status | Notes |
|---------------|--------|-------|
| Content-Type enforcement | Implemented | Strict `application/pkcs10` for enrollment; `application/pkcs7-mime; smime-type=certs-only` for `/cacerts` responses. |
| Base64 encoding rules | Implemented | Accepts both raw DER and Base64-encoded bodies.  Responses use Base64 with `Content-Transfer-Encoding: base64`. |
| Error response format | Implemented | HTTP 4xx/5xx responses include a `Content-Type: application/json` body with a machine-readable error code and human-readable message. |
| TLS-unique channel binding | Implemented | Channel binding values used for proof-of-possession when available (TLS 1.2 with `tls-unique`; TLS 1.3 uses `Exporter` instead). |

### RFC 5272 -- Certificate Management over CMS (Full CMC)

The `/fullcmc` endpoint accepts a Full PKI Request (a `ContentInfo`
containing a `PKIData` structure) and returns a Full PKI Response.

| Feature | Status | Notes |
|---------|--------|-------|
| PKIData parsing | Implemented | Parses `TaggedRequest` sequences containing PKCS#10 or CRMF requests. |
| PKIResponse construction | Implemented | Returns `ResponseBody` with certificates and optional control attributes. |
| Control attributes | Partial | `id-cmc-statusInfoV2`, `id-cmc-identification`, `id-cmc-transactionId`, and `id-cmc-senderNonce` / `id-cmc-recipientNonce` are supported.  RA-delegated controls are not yet implemented. |
| Nested CMS signing | Implemented | Requests may be signed by a Registration Authority; kipuka validates the RA certificate against a configured RA trust store. |

### RFC 8739 -- Short-Term, Automatically Renewed Certificates (STAR)

kipuka implements the server-side portion of STAR for short-lived certificate
management.  The `kipuka::star` module tracks renewal orders and issues
replacement certificates before expiry.

| Feature | Status | Notes |
|---------|--------|-------|
| STAR order lifecycle | Implemented | `StarOrder` tracks each auto-renewal series through `pending`, `active`, `expired`, and `cancelled` states. |
| Automatic re-issuance | Implemented | The `StarManager` monitors active orders and issues replacement certificates before the `not-after` of the current certificate.  Renewal interval is configurable per order. |
| Certificate fetch endpoint | Implemented | The `/.well-known/est/{label}/star/{order-id}` path returns the latest certificate in the renewal series. |
| Cancellation | Implemented | Operators can cancel a STAR order via the admin API.  The server stops issuing renewals and the order transitions to `cancelled`. |

## Transport

### RFC 7252 -- Constrained Application Protocol (CoAP)

The `kipuka-coap` crate implements EST-over-CoAP for resource-constrained
devices (IoT sensors, embedded controllers) that cannot maintain persistent
TCP connections.

| Feature | Status | Notes |
|---------|--------|-------|
| CoAP message parsing | Implemented | Confirmable (CON) and Non-confirmable (NON) message types.  Token matching for request/response correlation. |
| DTLS transport | Implemented | CoAP endpoints served over DTLS 1.2 with PSK or certificate-based authentication via the `kipuka_coap::dtls` module. |
| Block-wise transfer | Implemented | RFC 7959 Block1/Block2 options for transferring certificates and CSRs that exceed a single CoAP datagram.  Block size is negotiated automatically. |
| Content-Format mapping | Implemented | EST content types mapped to CoAP Content-Format option values per the EST-coaps draft. |
| `/cacerts` over CoAP | Implemented | Returns the CA certificate chain using block-wise transfer. |
| `/simpleenroll` over CoAP | Implemented | Enrollment via PKCS#10 CSR over CoAP/DTLS. |

### RFC 4210 / RFC 9810 -- Certificate Management Protocol (CMP)

The CMP endpoint at `/.well-known/cmp` provides a comprehensive certificate
lifecycle protocol with its own ASN.1 message format, independent of the
EST transport.

| Feature | Status | Notes |
|---------|--------|-------|
| Initialization Request (ir) | Implemented | New certificate enrollment via CMP. |
| Certification Request (cr) | Implemented | Certificate request from an entity with an existing certificate. |
| Key Update Request (kur) | Implemented | Certificate renewal / rekeying. |
| Revocation Request (rr) | Implemented | Certificate revocation via CMP (disabled by default). |
| MAC-based protection | Implemented | HMAC-SHA256 with shared secret for initial enrollment (RFC 4210 section 5.1.3.1). |
| Signature-based protection | Implemented | Protection using an existing certificate and private key. |
| Error handling | Implemented | PKIFailureInfo codes returned in error responses. |

### RFC 8295 -- EST with CMS-Level Security (CMS-EST)

CMS-EST wraps EST messages in CMS `SignedData` and `EnvelopedData`
structures, providing message-level security independent of the TLS transport.

| Feature | Status | Notes |
|---------|--------|-------|
| CMS SignedData requests | Implemented | All EST requests wrapped in CMS `SignedData` for authentication. |
| CMS EnvelopedData responses | Implemented | Responses encrypted to the client's certificate using CMS `EnvelopedData`. |
| Content encryption | Implemented | AES-256-GCM and AES-128-GCM supported.  Configurable via `allowed_content_encryption`. |
| Air-gapped deployment | Implemented | CMS-EST enables EST enrollment without direct TLS connectivity. |

### RFC 9483 -- EST over CoAP (EST-coaps)

Extends the RFC 7252 CoAP transport entry above with EST-specific path
mapping and content-format negotiation.

| Feature | Status | Notes |
|---------|--------|-------|
| Compressed URI paths | Implemented | `/sen`, `/sren`, `/skg`, `/att`, `/crts` mapped to EST operations per section 5.1. |
| Content-Format IDs | Implemented | CoAP content-format option values 280-287 per section 5.4. |
| DTLS 1.2 transport | Implemented | RFC 6347 with PSK and certificate-based authentication. |
| DTLS 1.3 transport | Implemented | RFC 9147 support. |
| Block-wise transfer | Implemented | RFC 7959 Block1/Block2 for PQC certificates exceeding single datagram size. |

### RFC 7959 -- Block-Wise Transfers in CoAP

| Feature | Status | Notes |
|---------|--------|-------|
| Block1 (request) | Implemented | Reassembles fragmented CSR uploads. |
| Block2 (response) | Implemented | Splits certificate responses into negotiated block sizes (16-1024 bytes). |
| Block size negotiation | Implemented | Server respects client-requested block size within configured limits. |

### Composite Post-Quantum Signatures

| Specification | Status | Notes |
|---------------|--------|-------|
| draft-ietf-lamps-pq-composite-sigs-19 | Implemented | Composite ML-DSA + classical algorithm combinations for hybrid migration. |
| CNSA Suite 2.0 | Tracked | Configuration defaults align with NSA CNSA 2.0 timeline (2025 prefer, 2030 require PQC). |

## Certificate Policy

### CA/Browser Forum Baseline Requirements

kipuka enforces the CA/B Forum Baseline Requirements for TLS server
certificates when configured to issue publicly-trusted certificates.  See
[CA/B Forum Baseline Requirements](./cab-forum.md) for the full mapping.

| Requirement | Status | Notes |
|-------------|--------|-------|
| Certificate profile | Enforced | Subject fields, key types, extensions validated against BR profiles.  Non-compliant CSRs are rejected before signing. |
| Serial number generation | Enforced | 160-bit serials from OS CSPRNG (exceeds the BR minimum of 64 bits). |
| Maximum validity period | Enforced | Configurable `max_validity_days` with declining defaults that track the BR timeline (398/200/100/47 days). |
| Key size minimums | Enforced | RSA >= 2048 bits, ECDSA P-256 or P-384.  Smaller keys are rejected at CSR validation. |

### NIAP Common Criteria -- CA Protection Profile v2.0

kipuka is designed to satisfy the Security Functional Requirements (SFRs) of
the NIAP CA Protection Profile.  See [NIAP CA Protection Profile](./niap.md)
for the full SFR-by-SFR mapping.

## Cryptographic Standards

### FIPS 140-3 -- Cryptographic Module Validation

kipuka does not itself hold a FIPS 140-3 certificate.  FIPS compliance is
achieved by delegating all cryptographic operations to a validated PKCS#11
HSM module.

| Aspect | Mechanism | Notes |
|--------|-----------|-------|
| Key generation | `C_GenerateKeyPair` | RSA and ECDSA key pairs generated inside the HSM boundary. |
| Signing | `C_Sign` | All certificate signing operations execute within the validated module. |
| Random number generation | `C_GenerateRandom` | Serial number entropy sourced from the HSM's validated DRBG when an HSM is configured; falls back to OS CSPRNG (`getrandom`) otherwise. |
| Key storage | HSM token | Private keys are CKA_SENSITIVE and CKA_EXTRACTABLE=false by default. |

When kipuka operates with a software-only key (no HSM), it uses the Synta
crate's software implementations.  These are suitable for testing and
non-FIPS environments but do not carry a FIPS validation.

### FIPS 204 -- ML-DSA (Post-Quantum Digital Signatures)

kipuka supports ML-DSA (formerly CRYSTALS-Dilithium) signing via two paths:

| Path | Mechanism | Levels |
|------|-----------|--------|
| Synta software | `kipuka_hsm::sign::sign_ml_dsa` | ML-DSA-44 (L2), ML-DSA-65 (L3), ML-DSA-87 (L5) |
| PKCS#11 HSM | `CKM_IBM_DILITHIUM` or vendor-specific | Depends on HSM firmware; see [HSM Compatibility Matrix](./hsm-compatibility.md) |

ML-DSA support is experimental.  CA certificates and end-entity certificates
can use ML-DSA key pairs, but client and browser ecosystem support is
limited as of 2026.

### FIPS 203 -- ML-KEM (Post-Quantum Key Encapsulation)

ML-KEM (formerly CRYSTALS-Kyber) is supported for key encapsulation in
hybrid key exchange scenarios.  The `kipuka_hsm::key` module defines
`MlKemLevel` variants L1, L3, and L5 corresponding to ML-KEM-512,
ML-KEM-768, and ML-KEM-1024 respectively.

| Path | Mechanism | Levels |
|------|-----------|--------|
| Synta software | Software KEM | ML-KEM-512 (L1), ML-KEM-768 (L3), ML-KEM-1024 (L5) |
| PKCS#11 HSM | Vendor-specific mechanisms | Depends on HSM firmware support |

ML-KEM is primarily relevant for `/serverkeygen` responses where the server
encrypts the generated private key for transport to the client.

## Summary Matrix

| Standard | Scope | Status |
|----------|-------|--------|
| **RFC 7030** | EST protocol | Core implementation -- all six endpoints |
| **RFC 8951** | EST clarifications | Fully implemented |
| **RFC 4210 / 9810** | CMP protocol | Initialization, certification, key update, revocation |
| **RFC 5272** | CMC (Full) | `/fullcmc` endpoint, partial control attributes |
| **RFC 8295** | CMS-EST | CMS-wrapped EST for air-gapped environments |
| **RFC 8739** | STAR auto-renewal | Short-lived certificate management |
| **RFC 7252** | CoAP transport | Constrained device enrollment over DTLS |
| **RFC 9483** | EST-coaps | EST over CoAP with compressed URI paths |
| **RFC 7959** | CoAP block transfer | Block1/Block2 for large certificate payloads |
| **RFC 6960** | OCSP | Client certificate revocation checking |
| **RFC 6347** | DTLS 1.2 | CoAP transport security |
| **RFC 9147** | DTLS 1.3 | CoAP transport security (modern) |
| **CA/B Forum BR** | Certificate profiles, validity | Enforced at CSR validation and signing |
| **NIAP CA PP v2.0** | Protection Profile | SFR mapping documented |
| **FIPS 140-3** | Cryptographic modules | Via HSM integration |
| **FIPS 204** | ML-DSA post-quantum signing | Via Synta / PKCS#11 |
| **FIPS 203** | ML-KEM post-quantum KEM | Via Synta / PKCS#11 |
| **Composite PQC** | Hybrid ML-DSA + classical | Migration path to post-quantum |
| **CNSA Suite 2.0** | NSA algorithm guidance | Timeline tracking for PQC transition |
