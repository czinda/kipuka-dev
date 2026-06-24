# NIAP CA Protection Profile

This page maps kipuka capabilities to the Security Functional Requirements
(SFRs) defined in the NIAP Certificate Authority Protection Profile v2.0.
The mapping is intended for evaluation teams preparing a Common Criteria
assessment and for operators who need to verify that their deployment
satisfies the Protection Profile.

> **Note:** A Common Criteria evaluation requires an accredited evaluation
> facility.  This document describes how kipuka addresses each SFR at the
> implementation level; it does not constitute a certified Security Target.

## Audit (FAU)

### FAU_GEN.1 -- Audit Data Generation

**Requirement:** The TOE shall generate an audit record for each auditable
event, including the date/time, event type, subject identity, and outcome.

**How kipuka satisfies it:**

The `kipuka::audit` module records structured audit events through the
`AuditEvent` struct.  Every event includes:

- Timestamp (UTC, microsecond precision)
- Event type (`AuditEventType` enum)
- Subject identity (client certificate DN, OTP identifier, or GSSAPI
  principal)
- Outcome (success or failure with reason)
- Source IP address and EST label

The following event types are audited:

| Event Type | Trigger |
|------------|---------|
| `EnrollRequest` | Client submits a CSR to `/simpleenroll`, `/simplereenroll`, or `/fullcmc` |
| `CertIssue` | Certificate successfully signed and returned to client |
| `CertReenroll` | Certificate re-enrollment completed |
| `CertRevoke` | Certificate revocation processed |
| `EnrollReject` | CSR rejected (policy violation, invalid key, unauthorized) |
| `AuthSuccess` | Client authentication succeeded (any method) |
| `AuthFailure` | Client authentication failed (bad OTP, invalid cert, GSSAPI error) |
| `KeyGenerate` | CA key pair generated (HSM or software) |
| `KeyLoad` | CA key loaded from HSM slot or file |
| `KeyDestroy` | CA key destroyed (HSM `C_DestroyObject` or file wipe) |
| `OtpCreate` | OTP token created via admin API |
| `OtpUse` | OTP token consumed during enrollment |
| `OtpRevoke` | OTP token revoked via admin API |
| `OtpExpire` | OTP token expired (TTL exceeded) |
| `AdminLogin` | Operator authenticated to admin API |
| `AdminLogout` | Operator session ended |
| `AdminAction` | Operator performed an administrative operation |
| `CaStart` | CA instance started and ready for signing |
| `CaStop` | CA instance shut down |
| `CaHealthChange` | CA health status changed (HA failover event) |
| `CrlGenerate` | CRL generated (when using Dogtag back-end) |
| `SecurityViolation` | Policy violation detected (tampered request, replay, etc.) |

**Implementation location:** `kipuka::audit::record()` is called from every
EST handler and authentication layer.

**Evaluation notes:** The event set covers all "minimum audit events" listed
in Table 5 of the Protection Profile.  Additional events (OTP lifecycle, HA
health changes) exceed the minimum.

### FAU_GEN.2 -- User Identity Association

**Requirement:** The TOE shall associate each auditable event with the
identity of the user that caused the event.

**How kipuka satisfies it:**

The `AuditEvent` struct contains a `subject` field populated from the
authenticated identity:

- **mTLS**: Subject DN and serial number of the client certificate.
- **OTP**: The OTP identifier (opaque token ID, not the secret).
- **GSSAPI**: The Kerberos principal name.
- **CMS**: The signer DN from the CMS `SignerInfo`.
- **Unauthenticated** (`/cacerts`): Recorded as `"anonymous"` with the
  source IP.

### FAU_STG.1 -- Protected Audit Trail Storage

**Requirement:** The TOE shall protect the stored audit records from
unauthorized deletion.

**How kipuka satisfies it:**

Audit records are written through two channels, both designed for
append-only semantics:

1. **Database** -- Audit records are `INSERT`-only.  The database schema
   does not expose `UPDATE` or `DELETE` operations on the audit table.
   When using PostgreSQL, row-level security policies can further restrict
   modification.

2. **File** -- When `audit.file` is configured, events are appended to a
   JSON Lines file.  kipuka opens the file in append-only mode
   (`O_APPEND`).  File-system permissions should restrict the audit file to
   the kipuka service account.

3. **Syslog** -- When `audit.syslog` is configured, events are forwarded to
   a remote syslog server over TLS, placing the audit trail outside the
   TOE boundary.

**Evaluation notes:** The Protection Profile requires that "the TSF shall
be able to prevent unauthorized deletion of the stored audit records."
Operators must ensure that file-system permissions and database RBAC are
configured to prevent the kipuka process from deleting its own audit
records.  Shipping audit events to a remote syslog server (channel 3)
provides the strongest protection.

## Cryptographic Support (FCS)

### FCS_CKM.1 -- Cryptographic Key Generation

**Requirement:** The TOE shall generate asymmetric cryptographic keys in
accordance with a specified key generation algorithm and key sizes.

**How kipuka satisfies it:**

| Key Type | Generation Method | Module |
|----------|-------------------|--------|
| RSA 2048, 3072, 4096 | PKCS#11 `C_GenerateKeyPair` (HSM) or Synta software | `kipuka_hsm::key` |
| ECDSA P-256, P-384, P-521 | PKCS#11 `C_GenerateKeyPair` (HSM) or Synta software | `kipuka_hsm::key` |
| ML-DSA-44, ML-DSA-65, ML-DSA-87 | Synta software or vendor PKCS#11 | `kipuka_hsm::key` |
| Certificate serial numbers | OS CSPRNG (`getrandom`) or PKCS#11 `C_GenerateRandom` | `kipuka::ca::issue` |

Serial numbers are 160 bits (20 bytes) from a CSPRNG, exceeding the CA/B
Forum minimum of 64 bits and the NIAP requirement for unpredictable serial
numbers.

**Implementation location:** `kipuka_hsm::key::HsmKeyPair` for CA keys;
`kipuka_est::serverkeygen` for end-entity keys generated via
`/serverkeygen`.

### FCS_CKM.2 -- Cryptographic Key Distribution

**Requirement:** The TOE shall distribute cryptographic keys in accordance
with a specified key distribution method.

**How kipuka satisfies it:**

- **CA certificate distribution** -- The `/cacerts` endpoint returns the CA
  certificate chain as a PKCS#7 `certs-only` message.  Distribution is
  over TLS (FCS_TLSS_EXT.1).

- **Server-generated key distribution** -- When `/serverkeygen` is enabled,
  the generated private key is encrypted to the client using PKCS#7
  `EnvelopedData`:
  - **AES-256 key wrapping** with the content-encryption key wrapped to
    the client's public key via RSA-OAEP or ECDH-ES.
  - The wrapped key and signed certificate are returned as a single
    multipart MIME response.

**Implementation location:** `kipuka_est::serverkeygen` for key wrapping;
`kipuka_est::cacerts` for CA chain distribution.

### FCS_COP.1 -- Cryptographic Operation

**Requirement:** The TOE shall perform cryptographic operations in
accordance with specified algorithms and key sizes.

**How kipuka satisfies it:**

| Operation | Algorithm(s) | Key Size | Module |
|-----------|-------------|----------|--------|
| Certificate signing | RSA PKCS#1 v1.5, RSA-PSS, ECDSA | >= 2048 (RSA), P-256/P-384/P-521 (EC) | `kipuka_hsm::sign` |
| Certificate signing (PQC) | ML-DSA | L2/L3/L5 | `kipuka_hsm::sign::sign_ml_dsa` |
| Hashing | SHA-256, SHA-384, SHA-512 | -- | Synta / HSM |
| TLS | TLS 1.2 / TLS 1.3 | Per cipher suite | `rustls` |
| OTP hashing | Argon2id, bcrypt, SHA-256-HMAC | -- | `kipuka_otp` |
| Key wrapping (`/serverkeygen`) | AES-256-WRAP, RSA-OAEP | 256 (AES), >= 2048 (RSA) | `kipuka_est::serverkeygen` |

**Implementation location:** `kipuka_hsm::sign` dispatches to
`sign_rsa_pkcs1`, `sign_rsa_pss`, `sign_ecdsa`, or `sign_ml_dsa` depending
on the CA key type.

### FCS_RBG_EXT.1 -- Random Bit Generation

**Requirement:** The TOE shall use a DRBG that is seeded by an entropy
source.

**How kipuka satisfies it:**

- **With HSM**: Random bytes are obtained via PKCS#11 `C_GenerateRandom`,
  which invokes the HSM's FIPS-validated DRBG.
- **Without HSM**: Random bytes are obtained from the operating system's
  CSPRNG via `getrandom(2)` on Linux or the equivalent on other platforms.

Serial number generation always uses whichever RBG is active.

### FCS_TLSS_EXT.1 -- TLS Server

**Requirement:** The TOE shall implement TLS 1.2 and/or TLS 1.3 as a
server.

**How kipuka satisfies it:**

kipuka uses `rustls` for TLS termination.

| Parameter | Configuration | Notes |
|-----------|--------------|-------|
| Minimum version | `tls.min_version` (default `"1.2"`) | Set to `"1.3"` to disable TLS 1.2 entirely. |
| Cipher suites | `tls.cipher_suites` | Defaults to `rustls` safe defaults (TLS_AES_256_GCM_SHA384, TLS_AES_128_GCM_SHA256, TLS_CHACHA20_POLY1305_SHA256 for TLS 1.3; ECDHE suites for TLS 1.2). |
| Client auth | `tls.client_auth` | Supports `required`, `optional`, and `none` modes. |
| Server certificate EKU | id-kp-cmcRA | The server certificate should include the CMC Registration Authority extended key usage OID (1.3.6.1.5.5.7.3.28) for NIAP compliance. |

**Implementation location:** `kipuka::tls` module configures
`rustls::ServerConfig`.

## Identification and Authentication (FIA)

### FIA_AFL.1 -- Authentication Failure Handling

**Requirement:** The TOE shall detect when a configurable number of
unsuccessful authentication attempts occur and take action.

**How kipuka satisfies it:**

The OTP authentication subsystem implements rate limiting and lockout:

| Parameter | Config Key | Default |
|-----------|-----------|---------|
| Max consecutive failures | `otp.max_failures` | 5 |
| Failure counting window | `otp.failure_window` | 15 minutes |
| Lockout duration | `otp.lockout_duration` | 30 minutes |

When the threshold is reached:

1. An `AuthFailure` audit event is recorded with reason `"lockout"`.
2. Subsequent authentication attempts for that OTP identifier return HTTP
   403 until the lockout expires.
3. If the lockout is triggered by mTLS (invalid client cert), the TLS
   handshake fails before the HTTP layer is reached; the audit event
   records the client IP and certificate serial number.

**Implementation location:** `kipuka::auth::otp` for OTP lockout;
`kipuka::auth::mtls` for mTLS failure logging.

### FIA_UAU.1 -- Timing of Authentication

**Requirement:** The TOE shall allow only the retrieval of CA certificates
before the user is authenticated.

**How kipuka satisfies it:**

- `/cacerts` -- Unauthenticated.  No client credential is required.
- All other endpoints (`/simpleenroll`, `/simplereenroll`, `/fullcmc`,
  `/serverkeygen`, `/csrattrs`) -- Require authentication via at least one
  configured method (mTLS, OTP, GSSAPI, or CMS signature).

The `EstAuth` extractor in `kipuka::auth` enforces this policy.  The
`OptionalAuth` extractor is used only for `/cacerts` and returns
`AuthMethod::None` when no credential is presented.

**Implementation location:** `kipuka::auth::EstAuth` and
`kipuka::auth::OptionalAuth`.

### FIA_UAU.5 -- Multiple Authentication Mechanisms

**Requirement:** The TOE shall provide multiple authentication mechanisms.

**How kipuka satisfies it:**

kipuka supports five authentication methods, selectable per EST label:

| Method | `AuthMethod` Variant | Use Case |
|--------|---------------------|----------|
| Mutual TLS | `Mtls` | Primary method for re-enrollment and machine identity |
| One-Time Password | `Otp` | Initial device bootstrapping |
| GSSAPI / Kerberos | `Gssapi` | Enterprise domain-joined devices |
| CMS signature | `Cms` | Full CMC requests signed by an RA |
| None (unauthenticated) | `None` | `/cacerts` only |

## Security Management (FMT)

### FMT_SMR.1 -- Security Roles

**Requirement:** The TOE shall maintain the roles of operator and user.

**How kipuka satisfies it:**

kipuka defines two distinct roles:

| Role | Access | Authentication |
|------|--------|---------------|
| **Operator** | Admin API (OTP management, CA health, HA control, audit retrieval) | Admin-specific mTLS certificate or bearer token, on a separate listener (`admin_listen`) |
| **User** | EST endpoints (enrollment, renewal, CA certificate retrieval) | EST client credentials (mTLS, OTP, GSSAPI) |

The admin API listens on a separate address and port
(`server.admin_listen`, default `127.0.0.1:9443`) with independent TLS
configuration.  No EST client credential grants access to the admin API,
and no admin credential grants access to EST endpoints on behalf of a
client.

**Implementation location:** `kipuka::routes::admin` for operator
endpoints; `kipuka::routes::est` for user endpoints.

### FMT_SMF.1 -- Management Functions

**Requirement:** The TOE shall provide management functions for authorized
operators.

**How kipuka satisfies it:**

The admin API provides:

| Function | Endpoint | Description |
|----------|----------|-------------|
| OTP management | `POST /admin/otp`, `DELETE /admin/otp/{id}` | Create and revoke OTP tokens |
| CA health | `GET /admin/ca/health` | View CA status, signing latency, HSM connectivity |
| HA control | `POST /admin/ha/failover` | Force failover to a backup CA |
| Audit retrieval | `GET /admin/audit` | Query audit records with time range and event type filters |
| Configuration reload | `POST /admin/reload` | Hot-reload certificate and label configuration without restart |

## Trusted Path (FTP)

### FTP_TRP.1 -- Trusted Path

**Requirement:** The TOE shall provide a communication path between itself
and remote users that is logically distinct from other paths and provides
assured identification of its endpoints.

**How kipuka satisfies it:**

- **EST over TLS** -- All enrollment communication uses TLS with server
  certificate authentication and (for authenticated endpoints) mutual TLS.
  The server certificate identifies the kipuka instance; the client
  certificate identifies the enrolling device.

- **Admin on separate TLS** -- The admin API uses an independent TLS
  listener with its own certificate and trust anchors.  This provides
  logical separation between the user-facing EST path and the
  operator-facing management path.

- **DTLS for CoAP** -- CoAP enrollment uses DTLS 1.2 for the trusted path,
  providing the same endpoint authentication guarantees over UDP.

**Implementation location:** `kipuka::tls` for EST and admin TLS;
`kipuka_coap::dtls` for DTLS.

## SFR Coverage Summary

| SFR | Requirement | kipuka Module | Status |
|-----|-------------|---------------|--------|
| FAU_GEN.1 | Audit data generation | `kipuka::audit` | Satisfied |
| FAU_GEN.2 | User identity association | `kipuka::audit` | Satisfied |
| FAU_STG.1 | Protected audit trail | `kipuka::audit`, DB, syslog | Satisfied |
| FCS_CKM.1 | Key generation | `kipuka_hsm::key` | Satisfied |
| FCS_CKM.2 | Key distribution | `kipuka_est::serverkeygen`, `kipuka_est::cacerts` | Satisfied |
| FCS_COP.1 | Crypto operations | `kipuka_hsm::sign`, `rustls` | Satisfied |
| FCS_RBG_EXT.1 | Random bit generation | OS CSPRNG, PKCS#11 | Satisfied |
| FCS_TLSS_EXT.1 | TLS server | `kipuka::tls` (`rustls`) | Satisfied |
| FIA_AFL.1 | Auth failure handling | `kipuka::auth::otp` | Satisfied |
| FIA_UAU.1 | Timing of authentication | `kipuka::auth` | Satisfied |
| FIA_UAU.5 | Multiple auth mechanisms | `kipuka::auth` | Satisfied |
| FMT_SMR.1 | Security roles | `kipuka::routes::admin`, `kipuka::routes::est` | Satisfied |
| FMT_SMF.1 | Management functions | `kipuka::routes::admin` | Satisfied |
| FTP_TRP.1 | Trusted path | `kipuka::tls`, `kipuka_coap::dtls` | Satisfied |
