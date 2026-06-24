# Configuration Reference

This document provides a complete reference for `kipuka.toml`, the main configuration file for the kipuka EST server.

## Configuration Sections

### [server]

Core server settings for HTTP/HTTPS listeners and runtime behavior.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `listen` | string | `"0.0.0.0:8443"` | Address and port for the main EST endpoint (HTTPS). |
| `admin_listen` | string | `"127.0.0.1:9443"` | Address and port for the administrative API. Bind to localhost by default for security. |
| `workers` | integer | `num_cpus` | Number of worker threads. Defaults to the number of CPU cores. |
| `max_body_size` | string | `"1MB"` | Maximum allowed request body size. Accepts suffixes: B, KB, MB, GB. |
| `shutdown_timeout` | string | `"30s"` | Grace period for connection draining during shutdown. Accepts suffixes: s, m, h. |

### [tls]

TLS configuration for the main EST endpoint.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `cert` | string | required | Path to PEM-encoded server certificate. |
| `key` | string | required | Path to PEM-encoded private key for the server certificate. |
| `min_version` | string | `"1.2"` | Minimum TLS protocol version. Valid values: `"1.2"`, `"1.3"`. |
| `cipher_suites` | array of strings | (TLS library defaults) | Explicit list of allowed cipher suites. Omit to use secure defaults. |

### [tls.client_auth]

Mutual TLS (mTLS) client authentication settings.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `trust_anchors` | string | required | Path to PEM file containing trusted CA certificates for client authentication. |
| `mode` | string | `"required"` | Client certificate verification mode: `required`, `optional`, or `none`. |

### [db]

Database connection settings.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `url` | string | `"sqlite://kipuka.db"` | Database connection URL. Supports `sqlite://`, `postgres://`, and `mysql://` (MariaDB) schemes. |
| `max_connections` | integer | `5` | Maximum number of database connections in the pool. |
| `connect_timeout` | string | `"5s"` | Timeout for establishing database connections. |
| `auto_migrate` | boolean | `true` | Automatically apply schema migrations on startup. |

### [[ca]]

Certificate Authority (CA) definitions. Multiple `[[ca]]` sections define multiple CAs.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `id` | string | required | Unique identifier for this CA. Referenced by EST labels. |
| `name` | string | required | Human-readable CA name. |
| `cert` | string | required | Path to PEM-encoded CA certificate. |
| `key` | string | required | Path to PEM-encoded CA private key (or HSM key reference). |
| `chain` | string | optional | Path to PEM-encoded intermediate chain (if applicable). |
| `validity_days` | integer | `365` | Default validity period for issued certificates (days). |
| `max_validity_days` | integer | `398` | Maximum allowed validity period. RFC 5280 and NIAP recommend 398 days max. |
| `default_key_usage` | array of strings | `["digitalSignature", "keyEncipherment"]` | Default X.509 Key Usage extensions. |
| `default_ext_key_usage` | array of strings | `["serverAuth"]` | Default Extended Key Usage OIDs. |
| `hsm_slot` | integer | optional | HSM slot number if this CA key is stored in an HSM. |

### [est]

EST protocol feature flags and global settings.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `base_path` | string | `"/.well-known/est"` | Base URL path for EST endpoints. |
| `cacerts` | boolean | `true` | Enable `/cacerts` endpoint (RFC 7030 section 4.1). |
| `simpleenroll` | boolean | `true` | Enable `/simpleenroll` endpoint (initial certificate enrollment). |
| `simplereenroll` | boolean | `true` | Enable `/simplereenroll` endpoint (certificate renewal). |
| `fullcmc` | boolean | `false` | Enable `/fullcmc` endpoint (full CMC protocol). |
| `serverkeygen` | boolean | `false` | Enable `/serverkeygen` endpoint (server-generated key pairs). |
| `csrattrs` | boolean | `true` | Enable `/csrattrs` endpoint (CSR attribute hints). |
| `csr_attributes` | array of strings | `[]` | OIDs to return in `/csrattrs` response. Empty means no specific attributes. |
| `retry_after` | integer | `60` | Seconds to return in `Retry-After` header for pending requests. |

### [[est.label]]

EST label definitions for CA-specific endpoints. Multiple `[[est.label]]` sections define multiple labels.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `name` | string | required | Label name. Appears in URL as `/.well-known/est/{name}/simpleenroll`. |
| `ca_id` | string | required | ID of the CA to use for this label (references `[[ca]]` section). |
| `allowed_key_types` | array of strings | `[]` | Restrict key types (e.g., `["rsa-2048", "ecdsa-p256"]`). Empty allows all. |
| `required_ext_key_usage` | array of strings | `[]` | Require specific EKU OIDs in CSR. |
| `max_validity_days` | integer | (inherited from CA) | Override CA's max validity for this label. |
| `require_san` | boolean | `true` | Require Subject Alternative Name extension in CSR. |
| `subject_pattern` | string | optional | Regex pattern for validating CSR subject DN. |

### [hsm]

Hardware Security Module (HSM) configuration.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `library` | string | required | Path to PKCS#11 library (e.g., `/usr/lib/softhsm/libsofthsm2.so`). |
| `slot` | integer | optional | Default HSM slot number. Can be overridden per CA. |
| `token_label` | string | optional | Token label for slot selection. |
| `pin` | string | optional | HSM PIN. **NOT RECOMMENDED** (use `pin_env` or `pin_file` instead). |
| `pin_env` | string | optional | Environment variable containing the HSM PIN. |
| `pin_file` | string | optional | Path to file containing the HSM PIN (first line, newline stripped). |

### [otp]

One-Time Password (OTP) authentication for initial enrollment.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | boolean | `false` | Enable OTP authentication. |
| `token_length` | integer | `20` | Length of generated OTP tokens. **NIAP requires >= 16 characters.** |
| `default_ttl` | string | `"24h"` | Default OTP validity period. |
| `max_uses` | integer | `1` | Maximum times an OTP can be used before expiration. |
| `hash_algorithm` | string | `"argon2id"` | Password hashing algorithm: `argon2id`, `bcrypt`, or `sha256-hmac`. |
| `max_failures` | integer | `5` | Maximum failed OTP attempts before lockout. |
| `failure_window` | string | `"15m"` | Time window for counting failed attempts. |
| `lockout_duration` | string | `"30m"` | Duration of account lockout after exceeding `max_failures`. |

### [audit]

Audit logging configuration.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `file` | string | optional | Path to audit log file. JSON Lines format. |
| `syslog` | string | optional | Syslog server URL (e.g., `tcp+tls://syslog.example.com:6514`). |
| `syslog_facility` | string | `"local0"` | Syslog facility for audit events. |
| `events` | array of strings | (all events) | Filter events to log. Omit to log all. Examples: `enroll`, `renew`, `reject`. |
| `include_cert_data` | boolean | `false` | Include full certificate PEM in audit logs. **Increases log volume.** |

### [ha]

High Availability configuration for CA failover.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | boolean | `false` | Enable HA mode. |
| `strategy` | string | `"active-passive"` | Global failover strategy: `active-passive`, `round-robin`, `weighted`, `latency-based`. |
| `check_interval` | string | `"10s"` | Health check interval for CAs. |
| `failure_threshold` | integer | `3` | Consecutive failures before marking CA unhealthy. |
| `recovery_timeout` | string | `"60s"` | Time to wait before retrying a failed CA. |
| `check_timeout` | string | `"5s"` | Timeout for individual health checks. |

### [[ha.group]]

HA groups for label-specific CA failover. Multiple `[[ha.group]]` sections define multiple groups.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `name` | string | required | Group name. |
| `ca_ids` | array of strings | required | List of CA IDs in priority order. |
| `strategy` | string | (inherited from `[ha]`) | Override global HA strategy for this group. |

### [admin]

Administrative API configuration.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | boolean | `false` | Enable the admin API. |
| `auth` | string | `"mtls"` | Authentication method: `mtls`, `bearer`, or `both`. |
| `trust_anchors` | string | optional | Path to PEM file with trusted CAs for admin mTLS. Required if `auth` includes `mtls`. |
| `bearer_token_env` | string | optional | Environment variable containing bearer token. Required if `auth` includes `bearer`. |

## Configuration Examples

### Minimal Configuration

A basic single-CA deployment with one EST label.

```toml
[server]
listen = "0.0.0.0:8443"

[tls]
cert = "/etc/kipuka/server.pem"
key = "/etc/kipuka/server-key.pem"

[tls.client_auth]
trust_anchors = "/etc/kipuka/client-ca.pem"
mode = "required"

[db]
url = "sqlite:///var/lib/kipuka/kipuka.db"

[[ca]]
id = "main-ca"
name = "Main CA"
cert = "/etc/kipuka/ca.pem"
key = "/etc/kipuka/ca-key.pem"
validity_days = 365
max_validity_days = 398

[est]
base_path = "/.well-known/est"

[[est.label]]
name = "default"
ca_id = "main-ca"
require_san = true
```

### Production Configuration

A realistic production deployment with HSM, HA, audit logging, admin API, OTP, and multiple CAs.

```toml
[server]
listen = "0.0.0.0:8443"
admin_listen = "127.0.0.1:9443"
workers = 8
max_body_size = "2MB"
shutdown_timeout = "60s"

[tls]
cert = "/etc/kipuka/certs/server.pem"
key = "/etc/kipuka/certs/server-key.pem"
min_version = "1.3"

[tls.client_auth]
trust_anchors = "/etc/kipuka/certs/client-ca-bundle.pem"
mode = "required"

[db]
url = "postgres://kipuka:password@db.example.com/kipuka?sslmode=require"
max_connections = 20
connect_timeout = "10s"
auto_migrate = true

[hsm]
library = "/usr/lib/softhsm/libsofthsm2.so"
slot = 0
token_label = "kipuka-prod"
pin_env = "KIPUKA_HSM_PIN"

[[ca]]
id = "root-ca"
name = "Production Root CA"
cert = "/etc/kipuka/ca/root-ca.pem"
key = "pkcs11:object=root-ca-key"
chain = "/etc/kipuka/ca/root-chain.pem"
validity_days = 365
max_validity_days = 398
default_key_usage = ["digitalSignature", "keyEncipherment"]
default_ext_key_usage = ["serverAuth", "clientAuth"]
hsm_slot = 0

[[ca]]
id = "backup-ca"
name = "Production Backup CA"
cert = "/etc/kipuka/ca/backup-ca.pem"
key = "pkcs11:object=backup-ca-key"
chain = "/etc/kipuka/ca/backup-chain.pem"
validity_days = 365
max_validity_days = 398
default_key_usage = ["digitalSignature", "keyEncipherment"]
default_ext_key_usage = ["serverAuth", "clientAuth"]
hsm_slot = 1

[[ca]]
id = "iot-ca"
name = "IoT Device CA"
cert = "/etc/kipuka/ca/iot-ca.pem"
key = "pkcs11:object=iot-ca-key"
validity_days = 180
max_validity_days = 180
default_key_usage = ["digitalSignature"]
default_ext_key_usage = ["clientAuth"]
hsm_slot = 2

[est]
base_path = "/.well-known/est"
cacerts = true
simpleenroll = true
simplereenroll = true
fullcmc = false
serverkeygen = false
csrattrs = true
csr_attributes = ["2.5.4.3", "2.5.4.11"]
retry_after = 120

[[est.label]]
name = "servers"
ca_id = "root-ca"
allowed_key_types = ["rsa-2048", "rsa-4096", "ecdsa-p256"]
required_ext_key_usage = ["serverAuth"]
max_validity_days = 398
require_san = true
subject_pattern = "^CN=.*\\.example\\.com$"

[[est.label]]
name = "clients"
ca_id = "root-ca"
allowed_key_types = ["ecdsa-p256", "ecdsa-p384"]
required_ext_key_usage = ["clientAuth"]
max_validity_days = 365
require_san = true

[[est.label]]
name = "iot"
ca_id = "iot-ca"
allowed_key_types = ["ecdsa-p256"]
required_ext_key_usage = ["clientAuth"]
max_validity_days = 180
require_san = false

[otp]
enabled = true
token_length = 20
default_ttl = "24h"
max_uses = 1
hash_algorithm = "argon2id"
max_failures = 5
failure_window = "15m"
lockout_duration = "30m"

[audit]
file = "/var/log/kipuka/audit.jsonl"
syslog = "tcp+tls://syslog.example.com:6514"
syslog_facility = "local0"
events = ["enroll", "renew", "reject", "revoke"]
include_cert_data = false

[ha]
enabled = true
strategy = "active-passive"
check_interval = "10s"
failure_threshold = 3
recovery_timeout = "60s"
check_timeout = "5s"

[[ha.group]]
name = "production"
ca_ids = ["root-ca", "backup-ca"]
strategy = "active-passive"

[[ha.group]]
name = "iot"
ca_ids = ["iot-ca"]
strategy = "active-passive"

[admin]
enabled = true
auth = "both"
trust_anchors = "/etc/kipuka/certs/admin-ca.pem"
bearer_token_env = "KIPUKA_ADMIN_TOKEN"
```

## Notes

- **Security**: Never commit `kipuka.toml` with plaintext secrets to version control. Use environment variables or HSM-backed keys.
- **Validation**: kipuka validates the configuration at startup and reports errors for missing required fields or invalid values.
- **Reloading**: Configuration changes require a server restart. Plan maintenance windows for production deployments.
- **HSM Keys**: When using HSM-backed CA keys, specify `key` as a PKCS#11 URI (e.g., `pkcs11:object=my-key`) and ensure `hsm_slot` matches the token slot.
- **NIAP Compliance**: For NIAP Common Criteria compliance, ensure `otp.token_length >= 16`, `tls.min_version = "1.3"`, and `ca.max_validity_days <= 398`.
