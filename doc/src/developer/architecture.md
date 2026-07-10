# Architecture

kipuka is structured as a Cargo workspace with six crates, each owning a
distinct responsibility.  This separation enforces module boundaries at the
compilation level and allows operators to build only the features they need.

## Workspace layout

```mermaid
flowchart TD
    clients["Clients"]:::client

    clients -->|"TLS + mTLS / OTP"| est
    clients -->|"CoAP / DTLS<br/>(UDP)"| coap

    subgraph core [" "]
        est["<b>kipuka-est</b><br/>axum HTTP · TLS · EST protocol<br/>auth · HA · admin API"]:::server
        coap["<b>kipuka-coap</b><br/>CoAP / DTLS transport<br/>RFC 9483 · RFC 7252"]:::server
    end

    subgraph modules [" "]
        otp["<b>kipuka-otp</b><br/>OTP lifecycle<br/>argon2id · rate limiting"]:::auth
        hsm["<b>kipuka-hsm</b><br/>PKCS #11 / HSM<br/>cryptoki FFI"]:::crypto
        util["<b>kipuka-util</b><br/>shared types · config<br/>ASN.1 · zeroize"]:::server
    end

    est --> otp
    est --> hsm
    est --> util
    coap --> util

    hsm --> dogtag
    dogtag["<b>kipuka-dogtag</b><br/>Dogtag PKI<br/>REST client"]:::infra

    otp --> db
    est --> db
    db[("sqlx<br/>SQLite · PostgreSQL<br/>MariaDB")]:::store

    classDef client fill:#1a2332,stroke:#3b82f6,color:#e2e8f0
    classDef server fill:#132218,stroke:#16a34a,color:#e2e8f0
    classDef crypto fill:#2d1a0a,stroke:#f0883e,color:#e2e8f0
    classDef store  fill:#1f1a0a,stroke:#ca8a04,color:#e2e8f0
    classDef auth   fill:#1a1025,stroke:#8b5cf6,color:#e2e8f0
    classDef infra  fill:#1f0a18,stroke:#db2777,color:#e2e8f0

    style core fill:none,stroke:none
    style modules fill:none,stroke:none
```

### Crate responsibilities

| Crate | Role |
| ----- | ---- |
| **kipuka-est** | Core server binary.  Owns the axum HTTP router, TLS termination (rustls), EST protocol handlers (`/cacerts`, `/simpleenroll`, `/simplereenroll`, `/serverkeygen`, `/fullcmc`, `/csrattrs`), request authentication, CSR validation, certificate construction (via synta), the admin API, database access (sqlx), and the HA state machine. |
| **kipuka-hsm** | PKCS #11 integration via the `cryptoki` crate.  Provides a `Signer` trait implementation that delegates cryptographic operations to an HSM.  Handles slot enumeration, session management, key lookup, and sign operations.  Isolates all unsafe FFI behind a safe Rust API. |
| **kipuka-otp** | One-time password lifecycle: generation (CSPRNG), hashing (argon2id / bcrypt), storage, validation, rate limiting, and expiration.  Exposes an internal API consumed by kipuka-est for enrollment authentication and by the admin API for token provisioning. |
| **kipuka-util** | Shared types and configuration parsing.  Owns `kipuka.toml` deserialization (via serde + toml), X.509 helper functions, ASN.1 OID constants, error types, and the `zeroize`-aware wrappers for sensitive data. |
| **kipuka-dogtag** | REST client for Red Hat Certificate System / Dogtag PKI.  Translates EST enrollment requests into Dogtag profile-based certificate issuance calls, delegating signing to a full CA back-end instead of local key material. |
| **kipuka-coap** | CoAP/DTLS transport layer (RFC 7252 / RFC 9483) for constrained-device enrollment.  The `CoapDtlsServer` opens a UDP listener with DTLS 1.2/1.3 encryption (via OpenSSL), parses CoAP messages, and dispatches EST operations through the `EstHandler` trait.  Block-wise transfer (RFC 7959) splits large certificate payloads across multiple datagrams.  The main crate provides a `CoapEstHandler` that bridges CoAP requests to the shared EST enrollment logic, so both HTTPS and CoAP paths use identical CA signing, CSR validation, and audit code. |

Dependencies flow strictly downward: `kipuka-est` depends on all other crates;
leaf crates (`kipuka-util`, `kipuka-coap`) depend on nothing project-internal
except `kipuka-util`.

---

## EST operation data flow

A certificate enrollment request traverses one of two transport paths
-- HTTPS or CoAP/DTLS -- before reaching the shared EST enrollment logic.

### HTTPS transport (default)

```mermaid
flowchart TD
    C["Client"]:::client

    subgraph transport ["Transport"]
        TLS["<b>rustls</b><br/>TLS 1.2 / 1.3 handshake<br/>mTLS client cert or<br/>OTP via HTTP Basic"]:::crypto
    end

    subgraph routing ["Routing"]
        ROUTER["<b>axum router</b><br/>/.well-known/est/{label}/simpleenroll<br/>/.well-known/est/{label}/simplereenroll<br/>/.well-known/est/{label}/cacerts<br/>/.well-known/est/{label}/serverkeygen"]:::server
        LABEL["<b>Label resolution</b><br/>look up [[est.label]] entry<br/>resolve bound [[ca]] config"]:::server
    end

    subgraph authn ["Authentication"]
        direction LR
        MTLS["<b>mTLS</b><br/>verify client<br/>certificate chain"]:::auth
        OTP["<b>OTP</b><br/>argon2id hash<br/>comparison"]:::auth
        GSS["<b>GSSAPI</b><br/>SPNEGO /<br/>Kerberos"]:::auth
    end

    subgraph issue ["Issuance"]
        CSR["<b>CSR parsing</b><br/>synta · key type · SANs<br/>policy validation"]:::server
        TBS["<b>Certificate construction</b><br/>X.509 TBS · serial from<br/>OsRng (CSPRNG)"]:::server
    end

    subgraph sign ["Signing"]
        direction LR
        FILE["<b>File key</b><br/>synta direct<br/>signing"]:::crypto
        HSM["<b>HSM</b><br/>PKCS#11<br/>session"]:::crypto
        DOG["<b>Dogtag</b><br/>REST API<br/>delegation"]:::infra
    end

    RESP["<b>Response</b><br/>PKCS#7 / CMS envelope<br/>DER-encoded"]:::server
    AUDIT["<b>Audit</b><br/>file · syslog · database"]:::store

    C --> TLS
    TLS --> ROUTER
    ROUTER --> LABEL
    LABEL --> authn
    MTLS --> CSR
    OTP --> CSR
    GSS --> CSR
    CSR --> TBS
    TBS --> sign
    FILE --> RESP
    HSM --> RESP
    DOG --> RESP
    RESP --> AUDIT

    classDef client fill:#1a2332,stroke:#3b82f6,color:#e2e8f0
    classDef server fill:#132218,stroke:#16a34a,color:#e2e8f0
    classDef crypto fill:#2d1a0a,stroke:#f0883e,color:#e2e8f0
    classDef store  fill:#1f1a0a,stroke:#ca8a04,color:#e2e8f0
    classDef auth   fill:#1a1025,stroke:#8b5cf6,color:#e2e8f0
    classDef infra  fill:#1f0a18,stroke:#db2777,color:#e2e8f0

    style transport fill:none,stroke:#30363d,stroke-dasharray:5 5
    style routing fill:none,stroke:#30363d,stroke-dasharray:5 5
    style authn fill:none,stroke:#30363d,stroke-dasharray:5 5
    style issue fill:none,stroke:#30363d,stroke-dasharray:5 5
    style sign fill:none,stroke:#30363d,stroke-dasharray:5 5
```

### CoAP/DTLS transport (constrained devices)

```mermaid
flowchart TD
    D["IoT device"]:::client

    subgraph transport ["Transport"]
        DTLS["<b>OpenSSL</b><br/>DTLS 1.2 / 1.3<br/>PSK or certificate mode"]:::crypto
    end

    subgraph coap_parse ["CoAP processing"]
        COAP["<b>CoAP parser</b><br/>method · URI path · Content-Format"]:::server
        BLK["<b>Block-wise transfer</b><br/>RFC 7959 · reassemble<br/>incoming blocks"]:::server
    end

    subgraph paths ["CoAP → EST path mapping"]
        direction LR
        SEN["/sen → SimpleEnroll"]:::server
        SREN["/sren → SimpleReenroll"]:::server
        SKG["/skg → ServerKeygen"]:::server
        ATT["/att → CsrAttrs"]:::server
        CRTS["/crts → CaCerts"]:::server
    end

    EST["<b>CoapEstHandler</b><br/>shared EST logic<br/>(same as HTTPS steps 5–9)"]:::server
    RESP["<b>CoAP 2.05 Content</b><br/>raw DER · Content-Format ID"]:::server
    AUDIT["<b>Audit log</b>"]:::store

    D -->|"UDP :5684"| DTLS
    DTLS --> COAP
    COAP --> BLK
    BLK --> paths
    SEN --> EST
    SREN --> EST
    SKG --> EST
    ATT --> EST
    CRTS --> EST
    EST --> RESP
    RESP --> AUDIT

    classDef client fill:#1a2332,stroke:#3b82f6,color:#e2e8f0
    classDef server fill:#132218,stroke:#16a34a,color:#e2e8f0
    classDef crypto fill:#2d1a0a,stroke:#f0883e,color:#e2e8f0
    classDef store  fill:#1f1a0a,stroke:#ca8a04,color:#e2e8f0
    classDef auth   fill:#1a1025,stroke:#8b5cf6,color:#e2e8f0

    style transport fill:none,stroke:#30363d,stroke-dasharray:5 5
    style coap_parse fill:none,stroke:#30363d,stroke-dasharray:5 5
    style paths fill:none,stroke:#30363d,stroke-dasharray:5 5
```

Both paths converge on the same CSR validation, certificate construction, and
signing logic — the `EstHandler` trait abstracts transport details so the core
enrollment code is shared between HTTPS and CoAP.

---

## Multi-CA HA failover state machine

When `[ha]` is enabled, each CA in an `[[ha.group]]` transitions through four
states.  The HA controller runs periodic health checks and manages transitions
automatically.

```mermaid
flowchart LR
    H["<b>Healthy</b><br/>operational<br/>receiving traffic"]:::server
    D["<b>Degraded</b><br/>checks failing<br/>still serving"]:::auth
    F["<b>Failed</b><br/>removed from<br/>routing pool"]:::infra
    R["<b>Recovery</b><br/>probing<br/>no traffic yet"]:::crypto

    H -- "health check<br/>fails" --> D
    D -- "check<br/>passes" --> H
    D -- "failure_threshold<br/>consecutive<br/>failures" --> F
    F -- "recovery_timeout<br/>elapsed" --> R
    R -- "sustained success<br/>(threshold<br/>checks pass)" --> H
    R -- "check fails<br/>during<br/>recovery" --> F

    classDef client fill:#1a2332,stroke:#3b82f6,color:#e2e8f0
    classDef server fill:#132218,stroke:#16a34a,color:#e2e8f0
    classDef crypto fill:#2d1a0a,stroke:#f0883e,color:#e2e8f0
    classDef store  fill:#1f1a0a,stroke:#ca8a04,color:#e2e8f0
    classDef auth   fill:#1a1025,stroke:#8b5cf6,color:#e2e8f0
    classDef infra  fill:#1f0a18,stroke:#db2777,color:#e2e8f0
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

---

## Authentication flow

### OTP validation path

```mermaid
flowchart TD
    C["<b>Client</b><br/>HTTP Basic: entity_id : otp_value"]:::client

    LOOKUP["Look up entity_id<br/>in database"]:::store

    EXP{"Expired?<br/>expires_at > now"}:::auth
    USE{"Max uses<br/>reached?"}:::auth
    LOCK{"Locked out?<br/>failed_attempts<br/>≥ max_failures"}:::auth

    HASH["Hash provided OTP<br/>with argon2id"]:::crypto
    CMP{"Timing-safe comparison<br/>subtle::ConstantTimeEq"}:::crypto

    OK["<b>Success</b><br/>increment use count<br/>clear failure counter"]:::server
    FAIL["<b>Failure</b><br/>increment failed_attempts<br/>check lockout threshold"]:::infra

    C --> LOOKUP
    LOOKUP --> EXP
    EXP -- "not expired" --> USE
    EXP -- "expired" --> FAIL
    USE -- "within limit" --> LOCK
    USE -- "exhausted" --> FAIL
    LOCK -- "not locked" --> HASH
    LOCK -- "locked" --> FAIL
    HASH --> CMP
    CMP -- "match" --> OK
    CMP -- "mismatch" --> FAIL

    classDef client fill:#1a2332,stroke:#3b82f6,color:#e2e8f0
    classDef server fill:#132218,stroke:#16a34a,color:#e2e8f0
    classDef crypto fill:#2d1a0a,stroke:#f0883e,color:#e2e8f0
    classDef store  fill:#1f1a0a,stroke:#ca8a04,color:#e2e8f0
    classDef auth   fill:#1a1025,stroke:#8b5cf6,color:#e2e8f0
    classDef infra  fill:#1f0a18,stroke:#db2777,color:#e2e8f0
```

OTP values are never stored in plaintext.  The `argon2id` hash is computed at
token generation time and only the hash is persisted.  The raw token is
returned to the administrator exactly once in the generation response.

### mTLS certificate chain validation

```mermaid
flowchart TD
    C["<b>Client</b><br/>TLS ClientHello<br/>+ Certificate"]:::client

    subgraph rustls_verify ["rustls verification"]
        SIG["Verify certificate<br/>signature is valid"]:::crypto
        EXP["Check certificate<br/>is not expired"]:::crypto
        CHAIN["Issuer chain terminates<br/>at configured trust anchor"]:::crypto
        KU["Key usage includes<br/>digitalSignature"]:::crypto
        EKU["Extended key usage<br/>includes clientAuth"]:::crypto
    end

    EXTRACT["<b>kipuka-est extracts</b><br/>Subject DN (audit + authz)<br/>Serial number (identity tracking)<br/>SAN entries (device identification)"]:::server

    C --> SIG
    SIG --> EXP
    EXP --> CHAIN
    CHAIN --> KU
    KU --> EKU
    EKU --> EXTRACT

    classDef client fill:#1a2332,stroke:#3b82f6,color:#e2e8f0
    classDef server fill:#132218,stroke:#16a34a,color:#e2e8f0
    classDef crypto fill:#2d1a0a,stroke:#f0883e,color:#e2e8f0

    style rustls_verify fill:none,stroke:#30363d,stroke-dasharray:5 5
```

### GSSAPI / Kerberos

```mermaid
flowchart LR
    C["<b>Client</b><br/>Negotiate:<br/>SPNEGO token"]:::client
    CTX["Accept security<br/>context using<br/>server keytab"]:::auth
    PRINC["Extract<br/>authenticated<br/>principal<br/>user@REALM"]:::auth
    MAP["Map principal to<br/>certificate subject<br/>via principal_mapping<br/>or default_template"]:::server
    SUBJ["Mapped subject →<br/>certificate<br/>construction"]:::crypto

    C --> CTX --> PRINC --> MAP --> SUBJ

    classDef client fill:#1a2332,stroke:#3b82f6,color:#e2e8f0
    classDef server fill:#132218,stroke:#16a34a,color:#e2e8f0
    classDef crypto fill:#2d1a0a,stroke:#f0883e,color:#e2e8f0
    classDef auth   fill:#1a1025,stroke:#8b5cf6,color:#e2e8f0
```

---

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

---

## EST label routing

EST labels are the primary mechanism for multi-profile and multi-CA operation.
When a request arrives at `/.well-known/est/{label}/simpleenroll`, kipuka
resolves the label to a `[[est.label]]` configuration entry:

```mermaid
flowchart TD
    REQ["<b>Request URL</b><br/>/.well-known/est/<b>iot-devices</b>/simpleenroll"]:::client

    LABEL["<b>Label lookup</b><br/>name == iot-devices"]:::server

    CA["<b>CA lookup</b><br/>ca_id == iot-ca<br/>cert · key · chain<br/>validity_days · hsm_slot"]:::crypto

    HA{"CA in HA group<br/>and in Failed state?"}:::infra

    NEXT["Route to next healthy<br/>CA in group ca_ids"]:::server

    POLICY["<b>Policy enforcement</b><br/>allowed_key_types<br/>required_ext_key_usage<br/>require_san · subject_pattern<br/>max_validity_days"]:::auth

    ISSUE["<b>Certificate issuance</b><br/>using resolved CA key material<br/>and label policy"]:::crypto

    REQ --> LABEL
    LABEL -- "ca_id = iot-ca" --> CA
    CA --> HA
    HA -- "yes" --> NEXT
    NEXT --> POLICY
    HA -- "no" --> POLICY
    POLICY --> ISSUE

    classDef client fill:#1a2332,stroke:#3b82f6,color:#e2e8f0
    classDef server fill:#132218,stroke:#16a34a,color:#e2e8f0
    classDef crypto fill:#2d1a0a,stroke:#f0883e,color:#e2e8f0
    classDef store  fill:#1f1a0a,stroke:#ca8a04,color:#e2e8f0
    classDef auth   fill:#1a1025,stroke:#8b5cf6,color:#e2e8f0
    classDef infra  fill:#1f0a18,stroke:#db2777,color:#e2e8f0
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
