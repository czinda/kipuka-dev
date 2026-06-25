# STAR Certificates Configuration

Short-Term, Automatically Renewed (STAR) certificates are defined in RFC 8739. kipuka implements STAR to address the industry-wide shift toward short-lived certificates mandated by the CA/Browser Forum's 47-day maximum validity requirement.

## Overview

### Why STAR?

Traditional certificate management with multi-year validity periods creates operational challenges:

- **Revocation complexity**: Long-lived certificates require reliable OCSP/CRL infrastructure
- **Compromise risk**: Stolen private keys remain valid until detected and revoked
- **Manual renewal**: Annual or multi-year renewals are error-prone and disruptive

The CA/Browser Forum now mandates maximum 47-day validity for publicly trusted certificates. STAR automates this at scale.

### How STAR Works

Instead of manually renewing every 47 days, STAR:

1. **Order creation**: Client requests a STAR certificate with desired lifetime (e.g., 1 year)
2. **Automatic issuance**: kipuka issues the first 47-day certificate immediately
3. **Automatic renewal**: kipuka generates and publishes new certificates before expiration
4. **Client polling**: Client periodically fetches the latest certificate from the STAR endpoint
5. **Lifecycle management**: Order runs until max lifetime or cancellation

### STAR vs Traditional EST

| Feature | Traditional EST | STAR |
|---------|----------------|------|
| Enrollment | Manual per certificate | One-time order |
| Renewal | Manual simplereenroll | Automatic |
| Validity period | Operator-defined | 47 days (CA/B Forum) |
| Client polling | None | Required |
| Revocation | OCSP/CRL | Cancellation |

## Configuration

Enable STAR in your `kipuka.toml` configuration:

```toml
[star]
enabled = true

# Renewal intervals (seconds)
min_renewal_interval_secs = 3600       # 1 hour (minimum allowed)
max_renewal_interval_secs = 604800     # 7 days (maximum allowed)
default_renewal_interval_secs = 86400  # 1 day (default when not specified)

# Lifecycle limits
max_lifetime_days = 365                # Maximum order lifetime
max_active_orders = 10000              # Resource exhaustion protection

# Renewal timing
pre_renewal_factor = 0.5               # Renew at 50% of certificate lifetime
```

### Configuration Options

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `enabled` | bool | false | — | Enable STAR endpoints |
| `min_renewal_interval_secs` | u64 | 3600 | ≥3600 | Minimum time between renewals (1 hour) |
| `max_renewal_interval_secs` | u64 | 604800 | ≤604800 | Maximum time between renewals (7 days) |
| `default_renewal_interval_secs` | u64 | 86400 | 3600-604800 | Default renewal interval (1 day) |
| `max_lifetime_days` | u32 | 365 | 1-730 | Maximum order lifetime (1 year) |
| `max_active_orders` | usize | 10000 | ≥1 | Maximum concurrent STAR orders |
| `pre_renewal_factor` | f64 | 0.5 | 0.1-0.9 | When to renew (0.5 = halfway through cert life) |

### Renewal Timing

The `pre_renewal_factor` controls when kipuka generates the next certificate:

```
renewal_time = (certificate_validity * pre_renewal_factor)
```

**Examples:**

- `pre_renewal_factor = 0.5` (default): Renew 47-day cert after 23.5 days
- `pre_renewal_factor = 0.75`: Renew 47-day cert after 35.25 days
- `pre_renewal_factor = 0.25`: Renew 47-day cert after 11.75 days

**Recommendations:**

- **High-reliability**: `0.25-0.33` — More frequent renewals, longer grace period
- **Balanced** (default): `0.5` — Reasonable renewal frequency and grace period
- **Resource-constrained**: `0.75-0.8` — Fewer renewals, minimal grace period

Lower values increase server load but provide more time to recover from renewal failures.

## STAR Endpoints

### Create Order

```http
POST /.well-known/est/{label}/star-create
Content-Type: application/pkcs10
```

**Request body:** PKCS#10 CSR (DER-encoded)

**Response:**
```json
{
  "order_id": "7f3b9c2a-1e4d-4c8b-9a2e-6d5c8b7a3f1e",
  "status": "pending",
  "lifetime_days": 365,
  "renewal_interval_secs": 86400,
  "certificate_validity_days": 47,
  "fetch_url": "https://est.example.com/.well-known/est/prod/star/7f3b9c2a-1e4d-4c8b-9a2e-6d5c8b7a3f1e"
}
```

### Fetch Certificate

```http
GET /.well-known/est/{label}/star/{order-id}
```

**Response:** Current certificate (PEM-encoded)

Clients should poll this endpoint based on `renewal_interval_secs` to fetch renewed certificates.

### Cancel Order (Admin API)

```http
DELETE /admin/api/v1/star/{order-id}
Authorization: Bearer <admin-token>
```

Immediately cancels the order and stops automatic renewals.

## Order Lifecycle

```
          ┌────────┐
          │ Create │
          │ Order  │
          └───┬────┘
              │
              ▼
        ┌──────────┐
        │ pending  │◄──────────────┐
        └────┬─────┘               │
             │                     │
             │ Initial cert        │
             │ issued              │
             ▼                     │
        ┌──────────┐               │
        │  active  │               │
        └────┬─────┘               │
             │                     │
             │ Renewal timer       │
             │ fires               │
             ├─────────────────────┘
             │
             │ Lifetime expired
             │ or cancelled
             ▼
        ┌──────────┐
        │ expired  │
        │cancelled │
        └──────────┘
```

### Status States

#### pending

Order created but initial certificate not yet issued. Typical duration: <1 second.

**Transitions to:**
- `active` — Initial certificate issued successfully
- `expired` — Order creation failed or timed out

#### active

Certificate issued and automatic renewals enabled. Server generates new certificates based on `pre_renewal_factor`.

**Transitions to:**
- `expired` — Lifetime exceeded `max_lifetime_days`
- `cancelled` — Admin or client cancellation request

#### expired

Order lifetime exceeded. No further renewals will be issued.

**Final state:** Order cannot return to `active`.

#### cancelled

Order cancelled by administrator or client. Immediate termination.

**Final state:** Order cannot return to `active`.

## Client Implementation

### Python Example

```python
#!/usr/bin/env python3
import time
import requests
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.backends import default_backend

# Configuration
EST_SERVER = "https://est.example.com"
EST_LABEL = "prod"
RENEWAL_CHECK_INTERVAL = 86400  # 1 day

# Generate key pair
private_key = rsa.generate_private_key(
    public_exponent=65537,
    key_size=2048,
    backend=default_backend()
)

# Create CSR
csr = x509.CertificateSigningRequestBuilder().subject_name(
    x509.Name([
        x509.NameAttribute(x509.NameOID.COMMON_NAME, "www.example.com"),
    ])
).sign(private_key, hashes.SHA256(), default_backend())

# Submit STAR order
response = requests.post(
    f"{EST_SERVER}/.well-known/est/{EST_LABEL}/star-create",
    data=csr.public_bytes(serialization.Encoding.DER),
    headers={"Content-Type": "application/pkcs10"}
)

order = response.json()
order_id = order["order_id"]
fetch_url = order["fetch_url"]
print(f"STAR order created: {order_id}")

# Polling loop
while True:
    # Fetch current certificate
    cert_response = requests.get(fetch_url)
    
    if cert_response.status_code == 200:
        cert_pem = cert_response.text
        cert = x509.load_pem_x509_certificate(
            cert_pem.encode(), 
            default_backend()
        )
        
        print(f"Certificate valid until: {cert.not_valid_after}")
        
        # Install certificate
        with open("/etc/ssl/certs/server.crt", "w") as f:
            f.write(cert_pem)
        
        # Reload web server (example: nginx)
        import subprocess
        subprocess.run(["systemctl", "reload", "nginx"])
        
    elif cert_response.status_code == 404:
        print("Order expired or cancelled")
        break
    
    # Wait before next poll
    time.sleep(RENEWAL_CHECK_INTERVAL)
```

### Systemd Timer

Run the polling script as a systemd service:

```ini
# /etc/systemd/system/star-cert-renew.service
[Unit]
Description=STAR Certificate Renewal
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/star-renew.py
Restart=always
RestartSec=3600

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/star-cert-renew.timer
[Unit]
Description=STAR Certificate Renewal Timer

[Timer]
OnBootSec=5min
OnUnitActiveSec=1d

[Install]
WantedBy=timers.target
```

Enable:
```bash
systemctl enable --now star-cert-renew.timer
```

## Resource Exhaustion Protection

The `max_active_orders` setting prevents resource exhaustion attacks:

```toml
max_active_orders = 10000
```

When this limit is reached:

1. New STAR order requests return HTTP 429 (Too Many Requests)
2. Existing orders continue renewing normally
3. Orders transition to `expired` or `cancelled` states free up capacity

**Monitoring:**

```bash
# Check active STAR order count
curl -H "Authorization: Bearer <admin-token>" \
  https://est.example.com/admin/api/v1/star/stats

# Response:
# {
#   "active_orders": 8567,
#   "max_orders": 10000,
#   "capacity_percent": 85.67
# }
```

**Capacity Planning:**

- **Small deployment** (<100 devices): `max_active_orders = 1000`
- **Medium deployment** (100-1000 devices): `max_active_orders = 5000`
- **Large deployment** (1000-10000 devices): `max_active_orders = 25000`
- **Enterprise deployment** (>10000 devices): `max_active_orders = 100000`

Each order consumes ~1KB of memory for metadata storage.

## Security Considerations

### Order ID Entropy

Order IDs are generated using cryptographically secure random UUIDs (128 bits of entropy). This prevents:

- **Enumeration attacks**: Guessing valid order IDs
- **Prediction**: Deriving order IDs from observable data
- **Collisions**: Duplicate order IDs across the system

### Fetch URL Authorization

The fetch endpoint (`/.well-known/est/{label}/star/{order-id}`) requires:

1. **Knowledge of order ID**: Only clients with the UUID can fetch certificates
2. **TLS transport security**: Prevents interception of fetch requests
3. **No additional authentication**: Order ID serves as bearer token

**Implications:**

- Protect order IDs like API keys
- Don't log order IDs in publicly accessible logs
- Use HTTPS for all fetch operations
- Rotate orders if order ID is compromised (cancel old, create new)

### Cancellation Authorization

Only authenticated administrators can cancel STAR orders via the admin API. This prevents:

- Unauthorized service disruption
- Denial-of-service through order cancellation
- Client-initiated cancellation (clients must contact admin)

## Monitoring and Observability

### Metrics

kipuka exposes Prometheus metrics for STAR operations:

```
# Total active STAR orders
star_active_orders{label="prod"} 8567

# Orders by status
star_orders_by_status{label="prod",status="active"} 8560
star_orders_by_status{label="prod",status="pending"} 7
star_orders_by_status{label="prod",status="expired"} 0
star_orders_by_status{label="prod",status="cancelled"} 0

# Renewal operations
star_renewals_total{label="prod",result="success"} 156234
star_renewals_total{label="prod",result="failure"} 12

# Fetch operations
star_fetches_total{label="prod",http_code="200"} 298765
star_fetches_total{label="prod",http_code="404"} 45
```

### Logging

STAR operations generate structured logs:

```json
{
  "timestamp": "2026-06-25T14:32:01Z",
  "level": "INFO",
  "event": "star_order_created",
  "order_id": "7f3b9c2a-1e4d-4c8b-9a2e-6d5c8b7a3f1e",
  "lifetime_days": 365,
  "renewal_interval_secs": 86400,
  "subject": "CN=www.example.com"
}
```

```json
{
  "timestamp": "2026-06-25T15:00:00Z",
  "level": "INFO",
  "event": "star_certificate_renewed",
  "order_id": "7f3b9c2a-1e4d-4c8b-9a2e-6d5c8b7a3f1e",
  "serial": "3a:b2:c4:d5:e6:f7:a8:b9",
  "not_before": "2026-06-25T15:00:00Z",
  "not_after": "2026-08-11T15:00:00Z"
}
```

### Health Checks

Monitor STAR renewal health:

```bash
# Check for failed renewals in the last hour
curl -s https://est.example.com/admin/api/v1/star/health | jq '.failed_renewals_1h'

# Alert if > 0
```

## Troubleshooting

### Certificates not renewing

**Symptoms:**
- Client fetches return expired certificates
- `star_renewals_total{result="failure"}` metric increasing

**Causes:**
1. CA backend unavailable
2. CA policy rejecting renewals
3. HSM communication failure

**Diagnosis:**
```bash
# Check renewal logs
journalctl -u kipuka -g "star_certificate_renewal_failed" --since "1 hour ago"

# Check CA backend health
curl https://est.example.com/admin/api/v1/ca/health
```

**Solution:**
- Verify CA backend connectivity
- Check CA audit logs for rejection reasons
- Ensure HSM is accessible and responsive

### High fetch failure rate

**Symptoms:**
- `star_fetches_total{http_code="404"}` increasing rapidly

**Causes:**
1. Clients polling cancelled or expired orders
2. Order IDs leaked or mistyped
3. Mass order expiration event

**Diagnosis:**
```bash
# List recently expired orders
curl -H "Authorization: Bearer <admin-token>" \
  https://est.example.com/admin/api/v1/star/orders?status=expired&limit=100
```

**Solution:**
- Notify clients to recreate orders
- Investigate mass expiration (check `max_lifetime_days` configuration)
- Audit for unauthorized cancellations

### Resource exhaustion

**Symptoms:**
- HTTP 429 responses on order creation
- `star_active_orders` metric at `max_active_orders` limit

**Causes:**
1. Legitimate growth exceeding capacity
2. Order creation abuse
3. Orders not expiring (configuration issue)

**Solution:**
```bash
# Increase capacity
# Edit kipuka.toml:
# max_active_orders = 50000

# Restart kipuka
systemctl restart kipuka

# Or cancel stale orders
curl -X DELETE -H "Authorization: Bearer <admin-token>" \
  https://est.example.com/admin/api/v1/star/orders/cleanup?older_than_days=400
```

## Integration with Existing PKI

### Hybrid Deployment

Run STAR alongside traditional EST for gradual migration:

```toml
# EST for initial enrollment
[est]
enabled = true

# STAR for automated renewals
[star]
enabled = true
max_lifetime_days = 365
```

**Workflow:**

1. Clients perform initial enrollment via EST `/simpleenroll`
2. Clients create STAR order for automatic renewals
3. Clients cancel STAR order when device is decommissioned

### Certificate Revocation

STAR orders don't require revocation because:

1. **Short validity**: 47-day certificates have limited exposure window
2. **Cancellation**: Stop renewals by cancelling the order
3. **Immediate effect**: Next fetch returns HTTP 404

**Comparison to OCSP/CRL:**

| Method | Revocation Speed | Infrastructure |
|--------|------------------|----------------|
| OCSP | ~1 hour (cache TTL) | OCSP responder required |
| CRL | ~24 hours (CRL TTL) | CRL distribution required |
| STAR cancellation | Immediate (next fetch) | None |

**When to use traditional revocation:**

- Certificates issued outside STAR workflow
- Compliance requirements mandate OCSP/CRL
- Legacy clients don't support STAR

## Performance Tuning

### Renewal Batch Processing

Group renewals to reduce database load:

```toml
# Increase renewal interval to reduce frequency
default_renewal_interval_secs = 259200  # 3 days

# Higher pre_renewal_factor = later renewals
pre_renewal_factor = 0.75
```

### Client Polling Optimization

Instruct clients to use HTTP conditional requests:

```bash
# Fetch with If-Modified-Since
curl -H "If-Modified-Since: Wed, 25 Jun 2026 14:00:00 GMT" \
  https://est.example.com/.well-known/est/prod/star/{order-id}

# Server returns 304 Not Modified if cert unchanged
```

### Database Indexing

Ensure database has indexes on:

- `order_id` (primary key)
- `status` (for querying active orders)
- `next_renewal_time` (for renewal scheduling)

## Future Enhancements

Planned features in future kipuka releases:

- **Multi-certificate orders**: Single order for multiple domains (SAN certificates)
- **Client-initiated cancellation**: Allow clients to cancel their own orders
- **Renewal notifications**: Webhook or email alerts before renewal
- **Order transfer**: Migrate orders between EST labels
- **Analytics dashboard**: Web UI for STAR order visualization
