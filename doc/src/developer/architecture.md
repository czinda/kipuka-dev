# Architecture

kipuka is structured as a Cargo workspace with six crates, each owning a
distinct responsibility.  This separation enforces module boundaries at the
compilation level and allows operators to build only the features they need.

## Workspace layout

```
                      Clients
                        |
                   TLS + mTLS/OTP
                        |
                +-------+-------+
                |   kipuka-est  |     axum routes, EST protocol
                +---+---+---+---+
                    |   |   |
          +---------+   |   +---------+
          |             |             |
     kipuka-otp    kipuka-hsm    kipuka-util
     OTP lifecycle  PKCS#11      shared types
                    HSM ops         & config
          |             |
          |        kipuka-dogtag
          |         Dogtag PKI
          |         REST client
          |
     +----+----+       kipuka-coap
     |   sqlx  |       CoAP transport
     | sqlite  |       (RFC 7252)
     | postgres|
     | mariadb |
     +---------+
```

### Crate responsibilities

| Crate | Role |
| ----- | ---- |
| **kipuka-est** | Core server binary.  Owns the axum HTTP router, TLS termination (rustls), EST protocol handlers (`/cacerts`, `/simpleenroll`, `/simplereenroll`, `/serverkeygen`, `/fullcmc`, `/csrattrs`), request authentication, CSR validation, certificate construction (via synta), the admin API, database access (sqlx), and the HA state machine. |
| **kipuka-hsm** | PKCS #11 integration via the `cryptoki` crate.  Provides a `Signer` trait implementation that delegates cryptographic operations to an HSM.  Handles slot enumeration, session management, key lookup, and sign operations.  Isolates all unsafe FFI behind a safe Rust API. |
| **kipuka-otp** | One-time password lifecycle: generation (CSPRNG), hashing (argon2id / bcrypt), storage, validation, rate limiting, and expiration.  Exposes an internal API consumed by kipuka-est for enrollment authentication and by the admin API for token provisioning. |
| **kipuka-util** | Shared types and configuration parsing.  Owns `kipuka.toml` deserialization (via serde + toml), X.509 helper functions, ASN.1 OID constants, error types, and the `zeroize`-aware wrappers for sensitive data. |
| **kipuka-dogtag** | REST client for Red Hat Certificate System / Dogtag PKI.  Translates EST enrollment requests into Dogtag profile-based certificate issuance calls, delegating signing to a full CA back-end instead of local key material. |
| **kipuka-coap** | CoAP (RFC 7252) transport layer for constrained-device enrollment.  Maps CoAP request/response semantics onto the same EST handlers used by the HTTPS path, enabling bandwidth-constrained IoT devices to enroll without HTTP overhead. |

Dependencies flow strictly downward: `kipuka-est` depends on all other crates;
leaf crates (`kipuka-util`, `kipuka-coap`) depend on nothing project-internal
except `kipuka-util`.

## EST operation data flow

A certificate enrollment request traverses the following path from TLS
handshake to certificate issuance.

```
1. Client opens TLS connection to kipuka-est (rustls).
2. rustls performs TLS 1.2/1.3 handshake.
   - If mTLS: client certificate is validated against configured trust anchors.
   - If OTP:  TLS completes without client cert; HTTP Basic auth carries the token.
3. axum routes the request based on URL path:
   /.well-known/est/{label?}/simpleenroll  -> enroll handler
   /.well-known/est/{label?}/simplereenroll -> reenroll handler
   /.well-known/est/{label?}/cacerts       -> cacerts handler
   /.well-known/est/{label?}/serverkeygen  -> serverkeygen handler
   ...
4. Label resolution: if a label segment is present, kipuka looks up the
   [[est.label]] entry and resolves the bound [[ca]] configuration.
   If absent, the default CA is used.
5. Authentication:
   a. mTLS: extract client certificate from TLS session, verify chain.
   b. OTP:  extract Basic auth credentials, validate against kipuka-otp
            (argon2 hash comparison, rate limiting, expiration check).
   c. GSSAPI: validate Negotiate header against KDC, map principal.
6. CSR parsing: the request body (application/pkcs10) is parsed by synta.
   Key type, subject DN, SANs, and extensions are extracted and validated
   against the label's policy (allowed_key_types, subject_pattern,
   require_san, required_ext_key_usage).
7. Certificate construction: synta builds the X.509 TBS (to-be-signed)
   certificate from the validated CSR fields, CA configuration, and
   label policy.  Serial number is generated from OsRng (CSPRNG).
8. Signing:
   - File-based CA key: synta signs the TBS certificate directly.
   - HSM-backed CA key: kipuka-hsm opens a PKCS#11 session and delegates
     the sign operation to the hardware token.
   - Dogtag back-end: kipuka-dogtag sends the CSR to the Dogtag REST API
     and retrieves the signed certificate.
9. Response: the signed certificate is wrapped in a PKCS#7 / CMS
   ContentInfo envelope (DER-encoded) and returned with Content-Type
   application/pkcs7-mime.
10. Audit: an audit event is written to the configured destinations
    (file, syslog, database) with request metadata, outcome, and
    certificate fingerprint.
```

## Multi-CA HA failover state machine

When `[ha]` is enabled, each CA in an `[[ha.group]]` transitions through four
states.  The HA controller runs periodic health checks and manages transitions
automatically.

```
                   check passes
          +---------------------------+
          |                           |
          v                           |
    +-----------+    check fails    +-----------+
    |  Healthy  | ----------------> |  Degraded |
    +-----------+                   +-----------+
          ^                           |
          |                           | failure_threshold
          |                           | consecutive failures
          |                           v
    +-----------+    check passes   +-----------+
    |  Recovery | <---------------- | Failed    |
    +-----------+   after           +-----------+
          |         recovery_timeout
          | sustained success
          | (failure_threshold checks pass)
          v
    +-----------+
    |  Healthy  |
    +-----------+
```

**State definitions:**

- **Healthy** -- CA is operational.  Health checks pass.  Enrollment requests
  are routed to this CA normally.
- **Degraded** -- One or more health checks have failed but the threshold has
  not been reached.  The CA continues to receive traffic.  An alert is raised.
- **Failed** -- Consecutive failures have reached `failure_threshold`.  The CA
  is removed from the routing pool.  If the CA was the active node in an
  `active-passive` group, the next CA in `ca_ids` order is promoted.
- **Recovery** -- After `recovery_timeout` elapses, the HA controller begins
  probing the failed CA.  It must pass `failure_threshold` consecutive checks
  before returning to Healthy.  During recovery the CA does not receive
  enrollment traffic.

**Failover strategies** (set per `[[ha.group]]` or globally in `[ha]`):

| Strategy | Behavior |
| -------- | -------- |
| `active-passive` | First healthy CA in `ca_ids` order handles all requests.  Failover promotes the next CA in order. |
| `round-robin` | Requests are distributed across all healthy CAs in rotation. |
| `weighted` | CAs are weighted by a configurable priority; higher-priority CAs receive more traffic. |
| `latency-based` | Health check latency is tracked; requests are routed to the CA with the lowest observed latency. |

The health check itself performs a lightweight signing operation (or, for
Dogtag-backed CAs, a REST API ping) to verify that the CA can actually issue
certificates.  Network reachability alone is insufficient -- a reachable HSM
that has entered an error state must still be detected as unhealthy.

## Authentication flow

### OTP validation path

```
Client ---[HTTP Basic: entity_id:otp_value]---> kipuka-est
  |
  +-> kipuka-otp: look up entity_id in database
      |
      +-> Check expiration (expires_at > now)
      +-> Check use count (uses < max_uses)
      +-> Check lockout (failed_attempts < max_failures within failure_window)
      +-> Hash provided OTP with argon2id
      +-> Timing-safe comparison (subtle::ConstantTimeEq) against stored hash
      |
      +-> On success: increment use count, clear failure counter, return Ok
      +-> On failure: increment failed_attempts, check lockout threshold
```

OTP values are never stored in plaintext.  The `argon2id` hash is computed at
token generation time and only the hash is persisted.  The raw token is
returned to the administrator exactly once in the generation response.

### mTLS certificate chain validation

```
Client ---[TLS ClientHello + Certificate]---> rustls
  |
  +-> rustls verifies:
      1. Certificate signature is valid
      2. Certificate is not expired
      3. Issuer chain terminates at a configured trust anchor
      4. Key usage includes digitalSignature
      5. Extended key usage includes clientAuth (if enforced)
  |
  +-> kipuka-est extracts:
      - Subject DN (for audit and authorization)
      - Serial number (for certificate identity tracking)
      - SAN entries (for device identification)
```

### GSSAPI / Kerberos

```
Client ---[Negotiate: base64(SPNEGO token)]---> kipuka-est
  |
  +-> Accept security context using server keytab
  +-> Extract authenticated principal (e.g., user@REALM)
  +-> Map principal to certificate subject via [gssapi.principal_mapping]
      or default_template
  +-> Return mapped subject for certificate construction
```

## Database schema overview

kipuka uses sqlx with compile-time checked queries.  The schema is managed
through sequential migrations in `migrations/{sqlite,postgres,mariadb}/`.

### Core tables

**`otps`** -- One-time password state.

| Column | Type | Description |
| ------ | ---- | ----------- |
| `id` | INTEGER / SERIAL | Primary key |
| `entity_id` | TEXT | Client identifier (e.g., device hostname) |
| `otp_hash` | TEXT | Argon2id hash of the OTP value |
| `created_at` | TIMESTAMP | Token generation time |
| `expires_at` | TIMESTAMP | Token expiration time |
| `max_uses` | INTEGER | Maximum allowed uses |
| `use_count` | INTEGER | Current use count |
| `failed_attempts` | INTEGER | Consecutive failed validation attempts |
| `last_failure_at` | TIMESTAMP | Time of most recent failed attempt |
| `locked_until` | TIMESTAMP | Lockout expiration (NULL if not locked) |

**`audit_log`** -- Tamper-evident audit trail.

| Column | Type | Description |
| ------ | ---- | ----------- |
| `id` | INTEGER / SERIAL | Primary key |
| `timestamp` | TIMESTAMP | Event time (UTC) |
| `event_type` | TEXT | Event category (`enroll`, `renew`, `reject`, `otp_create`, etc.) |
| `entity_id` | TEXT | Client or device identifier |
| `ca_id` | TEXT | CA that processed the request |
| `label` | TEXT | EST label (NULL for unlabeled requests) |
| `auth_method` | TEXT | Authentication method (`mtls`, `otp`, `gssapi`) |
| `outcome` | TEXT | `success` or `failure` |
| `detail` | TEXT | Human-readable detail or error message |
| `cert_fingerprint` | TEXT | SHA-256 fingerprint of issued certificate (NULL on failure) |
| `client_ip` | TEXT | Source IP address |

**`certs`** -- Certificate inventory.

| Column | Type | Description |
| ------ | ---- | ----------- |
| `id` | INTEGER / SERIAL | Primary key |
| `serial_number` | TEXT | Certificate serial (hex-encoded) |
| `subject_dn` | TEXT | Subject distinguished name |
| `issuer_dn` | TEXT | Issuer distinguished name |
| `not_before` | TIMESTAMP | Validity start |
| `not_after` | TIMESTAMP | Validity end |
| `fingerprint` | TEXT | SHA-256 fingerprint |
| `ca_id` | TEXT | Issuing CA identifier |
| `label` | TEXT | EST label used for issuance |
| `entity_id` | TEXT | Associated entity (from OTP or mTLS subject) |
| `pem` | TEXT | Full PEM-encoded certificate (optional, controlled by config) |

## EST label routing

EST labels are the primary mechanism for multi-profile and multi-CA operation.
When a request arrives at `/.well-known/est/{label}/simpleenroll`, kipuka
resolves the label to a `[[est.label]]` configuration entry:

```
Request URL: /.well-known/est/iot-devices/simpleenroll
                                   |
                                   v
            +--------------------------------------+
            | Label lookup: name == "iot-devices"  |
            +--------------------------------------+
                                   |
                     ca_id = "iot-ca"
                                   |
                                   v
            +--------------------------------------+
            | CA lookup: id == "iot-ca"            |
            | cert, key, chain, validity_days,     |
            | hsm_slot, max_validity_days          |
            +--------------------------------------+
                                   |
                                   v
            +--------------------------------------+
            | Policy enforcement:                  |
            | - allowed_key_types                  |
            | - required_ext_key_usage             |
            | - require_san                        |
            | - subject_pattern                    |
            | - max_validity_days                  |
            +--------------------------------------+
                                   |
                                   v
            +--------------------------------------+
            | Certificate issuance using resolved  |
            | CA key material and label policy     |
            +--------------------------------------+
```

Requests without a label segment (e.g., `/.well-known/est/simpleenroll`) use
the first `[[ca]]` entry as the default CA with no additional label-level
policy enforcement.

When HA is enabled, label routing is extended: the label's `ca_id` is checked
against `[[ha.group]]` memberships.  If the CA belongs to an HA group and is in
a `Failed` state, the request is transparently routed to the next healthy CA in
the group's `ca_ids` list.  The label's policy constraints (key types, subject
pattern, etc.) are still enforced regardless of which CA in the group handles
the request.
