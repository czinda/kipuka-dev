# Admin API Reference

The admin API provides management operations for kipuka: health checks, CA
status, OTP lifecycle, and issued certificate queries.  It runs on a separate
TLS listener (default port 9444) from the EST enrollment endpoints, allowing
operators to restrict admin access at the network level independently of
client enrollment traffic.

## Admin listener configuration

The admin API binds to its own address and port, configured in the `[admin]`
section of the kipuka configuration file:

```toml
[admin]
listen = "0.0.0.0:9444"

[admin.tls]
cert = "/etc/kipuka/admin-server.crt"
key = "/etc/kipuka/admin-server.key"
client_ca = "/etc/kipuka/admin-ca.pem"
```

The admin TLS certificate and trust anchors are independent of the EST
listener.  This separation allows operators to:

- Issue admin certificates from a different CA than enrollment certificates.
- Restrict admin access to a management VLAN by binding to a specific interface.
- Apply different TLS policies (cipher suites, minimum version) for admin
  traffic.

## Authentication

The admin API supports two authentication methods:

| Method | Header | Description |
| ------ | ------ | ----------- |
| **mTLS** | (client certificate) | The client presents a certificate trusted by the admin `client_ca`.  Preferred for automated integrations. |
| **Bearer token** | `Authorization: Bearer <token>` | A static token configured in the `[admin]` section.  Suitable for quick manual access and scripts. |

```toml
[admin]
bearer_token = "${KIPUKA_ADMIN_TOKEN}"
```

All examples below use Bearer token authentication.  Substitute `--cert` /
`--key` flags for mTLS.

---

## Endpoints

### GET /admin/health

System health check.  Returns server uptime, version, and the health status of
every configured CA.

**Response:** `200 OK`

```bash
curl -s \
  -H "Authorization: Bearer ${KIPUKA_ADMIN_TOKEN}" \
  --cacert admin-ca.pem \
  https://admin.example.com:9444/admin/health | jq .
```

```json
{
  "status": "healthy",
  "version": "0.4.0",
  "uptime_seconds": 86412,
  "cas": [
    {
      "id": "default",
      "label": null,
      "status": "healthy",
      "last_sign_time": "2026-06-24T14:22:01Z"
    },
    {
      "id": "iot-fleet",
      "label": "iot-fleet",
      "status": "healthy",
      "last_sign_time": "2026-06-24T14:18:33Z"
    },
    {
      "id": "corp-devices",
      "label": "corp-devices",
      "status": "degraded",
      "last_sign_time": "2026-06-24T13:55:10Z",
      "error": "HSM session pool exhausted, 1 of 2 replicas available"
    }
  ],
  "database": {
    "status": "healthy",
    "backend": "postgresql",
    "pool_size": 10,
    "active_connections": 3
  }
}
```

The top-level `status` field aggregates CA and database health:

| Value | Meaning |
| ----- | ------- |
| `healthy` | All CAs and the database are operational. |
| `degraded` | At least one CA is degraded (partial replica loss) but enrollment is still possible. |
| `unhealthy` | A critical CA or the database is down.  Enrollment requests will fail. |

---

### GET /admin/ca

List all configured CAs with their current health status.

**Response:** `200 OK`

```bash
curl -s \
  -H "Authorization: Bearer ${KIPUKA_ADMIN_TOKEN}" \
  --cacert admin-ca.pem \
  https://admin.example.com:9444/admin/ca | jq .
```

```json
[
  {
    "id": "default",
    "label": null,
    "type": "local",
    "status": "healthy",
    "last_sign_time": "2026-06-24T14:22:01Z"
  },
  {
    "id": "iot-fleet",
    "label": "iot-fleet",
    "type": "hsm",
    "status": "healthy",
    "last_sign_time": "2026-06-24T14:18:33Z"
  },
  {
    "id": "corp-devices",
    "label": "corp-devices",
    "type": "dogtag",
    "status": "degraded",
    "last_sign_time": "2026-06-24T13:55:10Z"
  }
]
```

---

### GET /admin/ca/:id

Retrieve detailed information about a specific CA, including its type,
EST label binding, certificate chain, and operational status.

**Response:** `200 OK`

```bash
curl -s \
  -H "Authorization: Bearer ${KIPUKA_ADMIN_TOKEN}" \
  --cacert admin-ca.pem \
  https://admin.example.com:9444/admin/ca/iot-fleet | jq .
```

```json
{
  "id": "iot-fleet",
  "label": "iot-fleet",
  "type": "hsm",
  "status": "healthy",
  "hsm": {
    "module": "/usr/lib/libCryptoki2_64.so",
    "slot": 1,
    "key_label": "iot-signing-key"
  },
  "certificate_chain": [
    {
      "subject": "CN=IoT Fleet Issuing CA, O=Example Corp",
      "issuer": "CN=Example Root CA, O=Example Corp",
      "serial": "0A:1B:2C:3D:4E:5F",
      "not_before": "2025-01-15T00:00:00Z",
      "not_after": "2030-01-15T00:00:00Z",
      "key_algorithm": "ECDSA P-384"
    },
    {
      "subject": "CN=Example Root CA, O=Example Corp",
      "issuer": "CN=Example Root CA, O=Example Corp",
      "serial": "01",
      "not_before": "2020-01-01T00:00:00Z",
      "not_after": "2040-01-01T00:00:00Z",
      "key_algorithm": "RSA 4096"
    }
  ],
  "last_sign_time": "2026-06-24T14:18:33Z",
  "total_certs_issued": 14832
}
```

**Error:** `404 Not Found` if the CA id does not exist.

---

### POST /admin/otp

Generate a one-time password for initial device enrollment.  The OTP is bound
to an entity identifier (typically a device hostname or serial number) and is
valid for a limited time and number of uses.

**Request body:** `application/json`

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `entity_id` | string | yes | Identifier for the device or entity. Must match the HTTP Basic username during enrollment. |
| `ttl` | integer | no | Time-to-live in seconds. Default: 3600 (1 hour). |
| `max_uses` | integer | no | Maximum number of times the OTP can be used. Default: 1. |

**Response:** `201 Created`

```bash
curl -s -X POST \
  -H "Authorization: Bearer ${KIPUKA_ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  --cacert admin-ca.pem \
  -d '{
    "entity_id": "device-001.example.com",
    "ttl": 7200,
    "max_uses": 1
  }' \
  https://admin.example.com:9444/admin/otp | jq .
```

```json
{
  "id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "entity_id": "device-001.example.com",
  "otp": "a7f3b9c2d1e4",
  "created": "2026-06-24T15:00:00Z",
  "expires": "2026-06-24T17:00:00Z",
  "max_uses": 1,
  "remaining_uses": 1
}
```

The `otp` value is returned only in this response and is never stored in
plaintext on the server (the server stores a salted hash).  Record it
immediately.

---

### GET /admin/otp

List all active (non-expired, non-exhausted) OTPs.  The OTP secret value is
not included -- only metadata.

**Response:** `200 OK`

```bash
curl -s \
  -H "Authorization: Bearer ${KIPUKA_ADMIN_TOKEN}" \
  --cacert admin-ca.pem \
  https://admin.example.com:9444/admin/otp | jq .
```

```json
[
  {
    "id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
    "entity_id": "device-001.example.com",
    "created": "2026-06-24T15:00:00Z",
    "expires": "2026-06-24T17:00:00Z",
    "max_uses": 1,
    "remaining_uses": 1
  },
  {
    "id": "e29b1d4a-7c83-4f91-b234-1a23c4d5e678",
    "entity_id": "device-002.example.com",
    "created": "2026-06-24T14:30:00Z",
    "expires": "2026-06-24T15:30:00Z",
    "max_uses": 3,
    "remaining_uses": 2
  }
]
```

---

### DELETE /admin/otp/:id

Revoke an active OTP before it expires or is fully consumed.  Revoked OTPs
are immediately invalid for enrollment.

**Response:** `204 No Content`

```bash
curl -s -X DELETE \
  -H "Authorization: Bearer ${KIPUKA_ADMIN_TOKEN}" \
  --cacert admin-ca.pem \
  https://admin.example.com:9444/admin/otp/f47ac10b-58cc-4372-a567-0e02b2c3d479
```

**Error:** `404 Not Found` if the OTP id does not exist or has already expired.

---

### GET /admin/certs

List certificates issued by kipuka.  Results are paginated and can be filtered
by subject, issuer, status, or date range.

**Query parameters:**

| Parameter | Type | Default | Description |
| --------- | ---- | ------- | ----------- |
| `page` | integer | 1 | Page number (1-indexed). |
| `per_page` | integer | 50 | Results per page (max 500). |
| `subject` | string | -- | Filter by subject CN (substring match). |
| `status` | string | -- | Filter by status: `active`, `expired`, `revoked`. |
| `issued_after` | string | -- | ISO 8601 datetime.  Only certificates issued after this time. |
| `issued_before` | string | -- | ISO 8601 datetime.  Only certificates issued before this time. |

**Response:** `200 OK`

```bash
curl -s \
  -H "Authorization: Bearer ${KIPUKA_ADMIN_TOKEN}" \
  --cacert admin-ca.pem \
  "https://admin.example.com:9444/admin/certs?status=active&per_page=5" | jq .
```

```json
{
  "page": 1,
  "per_page": 5,
  "total": 14832,
  "certificates": [
    {
      "serial": "0A:1B:2C:3D:4E:5F:60:71",
      "subject": "CN=device-001.example.com",
      "issuer": "CN=IoT Fleet Issuing CA, O=Example Corp",
      "not_before": "2026-06-24T14:22:01Z",
      "not_after": "2027-06-24T14:22:01Z",
      "status": "active",
      "ca_id": "iot-fleet",
      "enrollment_type": "simpleenroll"
    },
    {
      "serial": "0A:1B:2C:3D:4E:5F:60:72",
      "subject": "CN=device-002.example.com",
      "issuer": "CN=IoT Fleet Issuing CA, O=Example Corp",
      "not_before": "2026-06-24T14:18:33Z",
      "not_after": "2027-06-24T14:18:33Z",
      "status": "active",
      "ca_id": "iot-fleet",
      "enrollment_type": "serverkeygen"
    }
  ]
}
```

---

## Error responses

Admin API errors return JSON with a consistent structure:

```json
{
  "error": "not_found",
  "message": "CA with id 'nonexistent' does not exist"
}
```

| Status | Meaning |
| ------ | ------- |
| `400 Bad Request` | Invalid request body or query parameters. |
| `401 Unauthorized` | Missing or invalid Bearer token; untrusted client certificate. |
| `404 Not Found` | Resource (CA, OTP, certificate) not found. |
| `500 Internal Server Error` | Server-side failure. |
