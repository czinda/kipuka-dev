# Admin API

The Admin API provides privileged endpoints for server management, monitoring, OTP provisioning, and certificate lifecycle operations. It runs on a separate port from the EST service to enable network-level access control and is disabled by default for security.

## Enabling the Admin API

The Admin API is disabled by default. To enable it, configure both the `[admin]` section and the `admin_listen` address in `[server]`.

The Admin API runs on a separate port (default 9443) to allow network-level access control. Bind to `127.0.0.1` for localhost-only access, or to a management VLAN IP for remote administration:

```toml
[server]
admin_listen = "127.0.0.1:9443"

[admin]
enabled = true
auth = "mtls"
trust_anchors = "/etc/kipuka/admin-ca.pem"
```

## Authentication Methods

The Admin API supports three authentication modes configured via the `auth` parameter:

### mTLS Authentication

Admin clients must present a certificate signed by the admin trust anchors CA. This is the most secure option and recommended for production environments.

```toml
[admin]
enabled = true
auth = "mtls"
trust_anchors = "/etc/kipuka/admin-ca.pem"
```

### Bearer Token Authentication

Admin clients provide a bearer token in the Authorization header. The token value is loaded from the environment variable specified by `bearer_token_env`.

```toml
[admin]
enabled = true
auth = "bearer"
bearer_token_env = "KIPUKA_ADMIN_TOKEN"
```

Clients authenticate using:

```bash
curl -H "Authorization: Bearer $KIPUKA_ADMIN_TOKEN" \
  https://localhost:9443/admin/health
```

### Both Authentication

Either mTLS or bearer token accepted. Useful during migration periods or for mixed tooling environments.

```toml
[admin]
enabled = true
auth = "both"
trust_anchors = "/etc/kipuka/admin-ca.pem"
bearer_token_env = "KIPUKA_ADMIN_TOKEN"
```

## Endpoints Overview

| Method | Path | Description |
|--------|------|-------------|
| GET | /admin/health | Server health and component status |
| GET | /admin/health/ready | Readiness probe (for Kubernetes) |
| GET | /admin/health/live | Liveness probe (for Kubernetes) |
| GET | /admin/ca | List all configured CAs with status |
| GET | /admin/ca/{id} | Get specific CA details and health |
| GET | /admin/ca/{id}/chain | Get CA certificate chain (PEM) |
| POST | /admin/otp | Generate a new OTP token |
| GET | /admin/otp | List active (unused) OTP tokens |
| DELETE | /admin/otp/{token_id} | Revoke an unused OTP token |
| GET | /admin/certs | List issued certificates (paginated) |
| GET | /admin/certs/{serial} | Get certificate details by serial |
| POST | /admin/certs/{serial}/revoke | Revoke a certificate |
| GET | /admin/audit | Query audit log (paginated, filterable) |
| GET | /admin/metrics | Prometheus-format metrics |

## OTP Provisioning Workflow

The OTP provisioning workflow enables secure initial enrollment for devices that do not yet have certificates.

### Step 1: Admin Generates OTP

The administrator creates a new OTP token with specified constraints:

```bash
curl -s --cert admin.pem --key admin-key.pem \
  --cacert admin-ca.pem \
  -X POST https://localhost:9443/admin/otp \
  -H "Content-Type: application/json" \
  -d '{"label": "device-42", "ttl": "24h", "max_uses": 1}'
```

Response:

```json
{
  "token_id": "01234567-89ab-cdef-0123-456789abcdef",
  "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "expires": "2026-06-25T14:30:00Z",
  "label": "device-42",
  "max_uses": 1
}
```

Parameters:
- `label`: Human-readable identifier for the token (for audit logs)
- `ttl`: Time-to-live (e.g., "24h", "7d", "1h30m")
- `max_uses`: Maximum number of times the token can be used (typically 1)

### Step 2: Admin Delivers Token to Client Operator

The token value must be delivered out-of-band through a secure channel:
- Encrypted email
- Ticketing system
- Secure messaging platform
- In-person handoff

Never transmit OTP tokens over unencrypted channels.

### Step 3: Client Uses OTP for Initial Enrollment

The client operator uses the OTP token for initial EST enrollment:

```bash
curl --cacert ca.pem \
  -u ":eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..." \
  --data-binary @csr.pem \
  -H "Content-Type: application/pkcs10" \
  -o cert.p7 \
  https://est.example.com/.well-known/est/simpleenroll
```

Note the colon prefix in the `-u` flag: HTTP Basic Auth uses `username:password` format, and OTP tokens are submitted as the password with an empty username.

### Step 4: OTP Consumed After Successful Enrollment

After successful enrollment, the OTP is marked as consumed if `max_uses=1`. Subsequent attempts to use the same token will be rejected.

### Step 5: Future Renewals Use Certificate-Based mTLS

Once the device has a certificate, all future operations (reenrollment, renewal) use the issued certificate for mTLS authentication. The OTP is no longer required.

## CA Status Monitoring

### List All CAs

```bash
curl --cert admin.pem --key admin-key.pem \
  --cacert admin-ca.pem \
  https://localhost:9443/admin/ca
```

Response:

```json
[
  {
    "id": "primary-ca",
    "name": "Primary Issuing CA",
    "status": "healthy",
    "last_check": "2026-06-24T12:34:56Z",
    "cert_not_after": "2028-12-31T23:59:59Z",
    "certs_issued_today": 42,
    "certs_issued_total": 15234
  },
  {
    "id": "backup-ca",
    "name": "Backup Issuing CA",
    "status": "healthy",
    "last_check": "2026-06-24T12:34:56Z",
    "cert_not_after": "2029-06-30T23:59:59Z",
    "certs_issued_today": 0,
    "certs_issued_total": 0
  }
]
```

Status values:
- `healthy`: CA is operational and passing all health checks
- `degraded`: CA is operational but experiencing issues (e.g., approaching expiration)
- `unhealthy`: CA is not operational (e.g., expired, HSM unreachable)

### Get Specific CA Details

```bash
curl --cert admin.pem --key admin-key.pem \
  --cacert admin-ca.pem \
  https://localhost:9443/admin/ca/primary-ca
```

This endpoint provides detailed status for a single CA, including backend-specific health information.

### Get CA Certificate Chain

```bash
curl --cert admin.pem --key admin-key.pem \
  --cacert admin-ca.pem \
  https://localhost:9443/admin/ca/primary-ca/chain
```

Returns the CA certificate chain in PEM format. This is useful for distributing trust anchors to clients.

### Aggregate Health Status

```bash
curl --cert admin.pem --key admin-key.pem \
  --cacert admin-ca.pem \
  https://localhost:9443/admin/health
```

Response:

```json
{
  "status": "healthy",
  "components": {
    "database": "healthy",
    "cas": {
      "primary-ca": "healthy",
      "backup-ca": "healthy"
    },
    "hsm": "healthy"
  },
  "uptime": "3d 14h 22m"
}
```

Use this endpoint for monitoring dashboards and alerting. Aggregate status reflects the worst status of any component:
- All components healthy: `healthy`
- Any component degraded: `degraded`
- Any component unhealthy: `unhealthy`

### Kubernetes Probes

For Kubernetes deployments, use the dedicated probe endpoints:

Readiness probe (server is ready to accept traffic):

```bash
curl https://localhost:9443/admin/health/ready
```

Liveness probe (server is running):

```bash
curl https://localhost:9443/admin/health/live
```

Configure in your Deployment manifest:

```yaml
livenessProbe:
  httpGet:
    path: /admin/health/live
    port: 9443
    scheme: HTTPS
  initialDelaySeconds: 10
  periodSeconds: 30

readinessProbe:
  httpGet:
    path: /admin/health/ready
    port: 9443
    scheme: HTTPS
  initialDelaySeconds: 5
  periodSeconds: 10
```

## Certificate Management

### List Issued Certificates

List certificates with optional filtering and pagination:

```bash
curl --cert admin.pem --key admin-key.pem \
  --cacert admin-ca.pem \
  "https://localhost:9443/admin/certs?status=active&ca=primary-ca&page=1&per_page=50"
```

Query parameters:
- `status`: Filter by certificate status (`active`, `revoked`, `expired`)
- `ca`: Filter by issuing CA ID
- `subject`: Filter by subject DN (substring match)
- `page`: Page number (1-indexed)
- `per_page`: Results per page (default 50, max 1000)

Response:

```json
{
  "certs": [
    {
      "serial": "1a2b3c4d5e6f7890",
      "subject": "CN=device-42.example.com",
      "issuer": "CN=Primary Issuing CA",
      "not_before": "2026-06-24T00:00:00Z",
      "not_after": "2027-06-24T23:59:59Z",
      "status": "active",
      "ca_id": "primary-ca"
    }
  ],
  "total": 15234,
  "page": 1,
  "per_page": 50
}
```

### Get Certificate Details

Retrieve detailed information for a specific certificate by serial number:

```bash
curl --cert admin.pem --key admin-key.pem \
  --cacert admin-ca.pem \
  https://localhost:9443/admin/certs/1a2b3c4d5e6f7890
```

Response includes full certificate details, issuance metadata, and audit trail.

### Revoke a Certificate

Revoke a certificate by serial number with a reason code:

```bash
curl --cert admin.pem --key admin-key.pem \
  --cacert admin-ca.pem \
  -X POST https://localhost:9443/admin/certs/1a2b3c4d5e6f7890/revoke \
  -H "Content-Type: application/json" \
  -d '{"reason": "keyCompromise"}'
```

Valid reason codes (per RFC 5280):
- `unspecified`: Default reason
- `keyCompromise`: Private key compromise
- `caCompromise`: CA key compromise
- `affiliationChanged`: Subject changed affiliation
- `superseded`: Certificate replaced
- `cessationOfOperation`: Certificate no longer needed
- `privilegeWithdrawn`: Certificate privileges revoked

Response:

```json
{
  "serial": "1a2b3c4d5e6f7890",
  "status": "revoked",
  "revocation_time": "2026-06-24T14:30:00Z",
  "revocation_reason": "keyCompromise"
}
```

The certificate is immediately marked as revoked in the database and will appear in the next CRL update.

## Audit Log Queries

Query the audit log for security analysis and compliance:

```bash
curl --cert admin.pem --key admin-key.pem \
  --cacert admin-ca.pem \
  "https://localhost:9443/admin/audit?action=enroll&start=2026-06-01&end=2026-06-24&page=1&per_page=100"
```

Query parameters:
- `action`: Filter by action type (`enroll`, `reenroll`, `serverkeygen`, `revoke`, `otp_generate`, `otp_use`)
- `subject`: Filter by certificate subject DN
- `ca`: Filter by CA ID
- `start`: Start timestamp (ISO 8601)
- `end`: End timestamp (ISO 8601)
- `page`: Page number (1-indexed)
- `per_page`: Results per page (default 100, max 1000)

Response:

```json
{
  "events": [
    {
      "timestamp": "2026-06-24T10:15:30Z",
      "action": "enroll",
      "subject": "CN=device-42.example.com",
      "ca_id": "primary-ca",
      "result": "success",
      "client_ip": "10.0.1.42",
      "auth_method": "otp",
      "serial": "1a2b3c4d5e6f7890"
    }
  ],
  "total": 1523,
  "page": 1,
  "per_page": 100
}
```

## Metrics

The Admin API exposes Prometheus-format metrics for monitoring:

```bash
curl --cert admin.pem --key admin-key.pem \
  --cacert admin-ca.pem \
  https://localhost:9443/admin/metrics
```

Key metrics include:
- `kipuka_enrollments_total`: Counter of enrollment operations by CA and result
- `kipuka_reenrollments_total`: Counter of reenrollment operations by CA and result
- `kipuka_revocations_total`: Counter of revocation operations by CA and reason
- `kipuka_otp_generated_total`: Counter of OTP tokens generated
- `kipuka_otp_consumed_total`: Counter of OTP tokens consumed
- `kipuka_request_duration_seconds`: Histogram of request durations by endpoint
- `kipuka_active_certificates`: Gauge of currently active certificates by CA
- `kipuka_ca_health`: Gauge of CA health status (1=healthy, 0=unhealthy)

Configure Prometheus to scrape the Admin API endpoint with appropriate mTLS credentials.
