# Audit Logging

kipuka implements comprehensive audit logging designed to meet NIAP Protection Profile for Certification Authorities requirements, specifically FAU_GEN.1 (Audit Data Generation). All security-relevant events are recorded with sufficient detail for forensic analysis and compliance verification.

## NIAP FAU_GEN.1 Compliance

kipuka's audit logging implementation satisfies the following FAU_GEN.1 requirements:

- **Completeness**: All security-relevant events are recorded, including certificate issuance, revocation, authentication attempts, and administrative actions.
- **Sufficient Detail**: Each audit record contains timestamp (UTC), event type, outcome (success/failure), subject identity, source IP address, and event-specific data necessary for forensic analysis.
- **Tamper Evidence**: Audit records are append-only. The database audit tables permit only INSERT operations; UPDATE and DELETE operations are prohibited at the schema level.
- **Reliability**: Audit records are written synchronously to the database, with optional asynchronous replication to file and syslog destinations.

## Audit Event Types

kipuka records 22 distinct event types across four categories:

| Event Name | Category | Description |
|------------|----------|-------------|
| `cert.issued` | Certificate | Certificate successfully issued |
| `cert.denied` | Certificate | Certificate request denied (policy violation) |
| `cert.revoked` | Certificate | Certificate revoked |
| `cert.renewed` | Certificate | Certificate renewed via simplereenroll |
| `cert.expired` | Certificate | Certificate reached expiration |
| `enroll.request` | Enrollment | simpleenroll request received |
| `enroll.success` | Enrollment | Enrollment completed successfully |
| `enroll.failure` | Enrollment | Enrollment failed |
| `reenroll.request` | Enrollment | simplereenroll request received |
| `reenroll.success` | Enrollment | Re-enrollment completed successfully |
| `reenroll.failure` | Enrollment | Re-enrollment failed |
| `auth.mtls.success` | Authentication | mTLS authentication succeeded |
| `auth.mtls.failure` | Authentication | mTLS authentication failed |
| `auth.otp.success` | Authentication | OTP authentication succeeded |
| `auth.otp.failure` | Authentication | OTP authentication failed |
| `auth.otp.lockout` | Authentication | OTP account locked due to excessive failures |
| `auth.gssapi.success` | Authentication | GSSAPI/Kerberos authentication succeeded |
| `auth.gssapi.failure` | Authentication | GSSAPI/Kerberos authentication failed |
| `admin.access` | Admin | Admin API endpoint accessed |
| `otp.created` | Admin | OTP token provisioned |
| `ca.health.changed` | System | CA health state changed (HA) |
| `server.startup` | System | kipuka server started |
| `server.shutdown` | System | kipuka server stopped |

## Audit Destinations

kipuka supports three audit destinations that operate independently. The database destination is always active; file and syslog destinations are optional.

### Database (Always Active)

All audit events are written to the `audit_log` table in the kipuka database. This destination is always active and cannot be disabled.

**Characteristics**:
- INSERT-only: The database schema enforces that audit records can only be inserted, never updated or deleted.
- Queryable: Audit records can be retrieved via the Admin API for compliance reporting and forensic analysis.
- Persistent: Records remain in the database until explicitly purged by an administrator through documented procedures.

### File (Append-Only JSON)

When configured, kipuka writes audit events to a file in JSON Lines format (one JSON object per line). The file is opened with the `O_APPEND` flag to ensure records cannot be overwritten.

**Configuration**:
```toml
[audit]
file = "/var/log/kipuka/audit.json"
```

**Rotation**:
Use `logrotate` with the `copytruncate` option or equivalent log rotation tools. Example logrotate configuration:

```
/var/log/kipuka/audit.json {
    daily
    rotate 90
    compress
    delaycompress
    copytruncate
    missingok
    notifempty
}
```

**Example JSON Record**:
```json
{
  "timestamp": "2026-06-24T14:32:10.123456Z",
  "event_type": "cert.issued",
  "outcome": "success",
  "subject": "CN=server.example.com",
  "source_ip": "192.0.2.45",
  "serial": "4A:3F:21:8C:09:77:34:2B",
  "issuer": "CN=Example CA",
  "not_before": "2026-06-24T14:32:00Z",
  "not_after": "2027-06-24T14:32:00Z"
}
```

### Syslog (RFC 5424, Optional TLS)

kipuka can forward audit events to a remote syslog server using RFC 5424 format. UDP, TCP, and TLS-encrypted TCP are supported.

**Configuration**:
```toml
[audit]
syslog = "tcp+tls://syslog.example.com:6514"
syslog_facility = "local0"
```

**Supported URL Schemes**:
- `udp://host:port` - Unencrypted UDP (not recommended for production)
- `tcp://host:port` - Unencrypted TCP
- `tcp+tls://host:port` - TLS-encrypted TCP (recommended for NIAP compliance)

**Syslog Facilities**:
The `syslog_facility` option accepts `local0` through `local7`. Default is `local0`.

**Structured Data**:
Audit events are encoded as RFC 5424 structured data elements. Example syslog message:

```
<134>1 2026-06-24T14:32:10.123456Z server1 kipuka 12345 cert.issued [audit event_type="cert.issued" outcome="success" subject="CN=server.example.com" source_ip="192.0.2.45" serial="4A:3F:21:8C:09:77:34:2B"]
```

## Event Filtering

The `events` array in the `[audit]` section controls which events are forwarded to file and syslog destinations. The database always records all events regardless of this filter.

**Default Behavior**:
If the `events` array is omitted or empty, all event types are forwarded to file and syslog.

**Filtering Example**:
To log only security-critical events to file/syslog:

```toml
[audit]
file = "/var/log/kipuka/audit.json"
events = [
    "cert.issued",
    "cert.denied",
    "cert.revoked",
    "auth.otp.failure",
    "auth.otp.lockout",
    "auth.mtls.failure",
    "admin.access",
]
```

In this configuration, successful routine operations (e.g., `enroll.success`, `auth.otp.success`) are recorded only in the database, reducing file and syslog volume while maintaining complete audit trail in the database for compliance queries.

## Certificate Data in Audit Records

By default, audit records for certificate lifecycle events include metadata (serial number, subject, issuer, validity dates) but not the full certificate. The `include_cert_data` option controls whether the complete PEM-encoded certificate is included.

**Default** (`include_cert_data = false`):
```json
{
  "timestamp": "2026-06-24T14:32:10.123456Z",
  "event_type": "cert.issued",
  "serial": "4A:3F:21:8C:09:77:34:2B",
  "subject": "CN=server.example.com",
  "issuer": "CN=Example CA",
  "not_before": "2026-06-24T14:32:00Z",
  "not_after": "2027-06-24T14:32:00Z"
}
```

**With Full Certificate Data** (`include_cert_data = true`):
```json
{
  "timestamp": "2026-06-24T14:32:10.123456Z",
  "event_type": "cert.issued",
  "serial": "4A:3F:21:8C:09:77:34:2B",
  "subject": "CN=server.example.com",
  "issuer": "CN=Example CA",
  "not_before": "2026-06-24T14:32:00Z",
  "not_after": "2027-06-24T14:32:00Z",
  "certificate": "-----BEGIN CERTIFICATE-----\nMIIDXTCCAkWgAwIBAgIJAEo/IYwJdzQr...\n-----END CERTIFICATE-----"
}
```

**Trade-offs**:
- Enabling `include_cert_data` significantly increases audit log size (typical certificate is 1-2 KB).
- Required by some compliance frameworks (e.g., certain government PKI policies) for complete certificate lifecycle tracking.
- Useful for forensic analysis when the original certificate is no longer available in the database.

## Configuration Examples

### Minimal Configuration (File Only)

```toml
[audit]
file = "/var/log/kipuka/audit.json"
```

This configuration writes all audit events to a local file with default settings.

### Production Configuration (File + Syslog over TLS)

```toml
[audit]
file = "/var/log/kipuka/audit.json"
syslog = "tcp+tls://syslog.example.com:6514"
syslog_facility = "local1"
events = [
    "cert.issued",
    "cert.denied",
    "cert.revoked",
    "auth.otp.failure",
    "auth.otp.lockout",
    "auth.mtls.failure",
    "admin.access",
    "otp.created",
    "server.startup",
    "server.shutdown",
]
```

This configuration:
- Logs all events to the database (always active).
- Logs security-critical events to both file and remote syslog over TLS.
- Reduces file and syslog volume by filtering routine successful operations.

### NIAP-Compliant Configuration

```toml
[audit]
file = "/var/log/kipuka/audit.json"
syslog = "tcp+tls://syslog.example.com:6514"
syslog_facility = "local0"
include_cert_data = true
# events array omitted: all events forwarded to file and syslog
```

This configuration:
- Logs all 22 event types to database, file, and syslog.
- Uses TLS-encrypted syslog for confidentiality and integrity.
- Includes full certificate data in audit records for complete lifecycle tracking.
- Meets NIAP FAU_GEN.1 requirements for completeness, detail, and tamper evidence.

**Note**: Enabling `include_cert_data` will substantially increase storage requirements. Plan for approximately 2-5 KB per certificate lifecycle event (issuance, renewal, revocation).
