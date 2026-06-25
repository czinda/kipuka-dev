# OCSP Configuration

The Online Certificate Status Protocol (OCSP) is defined in RFC 6960. kipuka implements OCSP checking to verify the revocation status of client certificates during mutual TLS authentication for EST enrollment operations.

## Overview

### OCSP in EST Context

EST enrollment requires client authentication via mutual TLS (mTLS). kipuka validates client certificates by:

1. **Chain verification**: Certificate chains to a trusted root
2. **Validity period**: Certificate is not expired
3. **Revocation status**: Certificate has not been revoked (via OCSP or CRL)

OCSP checking happens during the TLS handshake before EST operations are processed. Revoked certificates are rejected at the transport layer.

### OCSP vs CRL

| Feature | OCSP | CRL |
|---------|------|-----|
| Response time | Real-time | Periodic updates |
| Bandwidth | Minimal (per-cert query) | High (full list download) |
| Privacy | Reveals which certs are checked | Anonymous |
| Freshness | Seconds | Hours/days |
| Fallback | CRL | None |

kipuka prefers OCSP for real-time revocation checking but falls back to CRL when OCSP is unavailable.

## Configuration

Enable OCSP in your `kipuka.toml` configuration:

```toml
[ocsp]
enabled = true

# OCSP responder URL (optional, overrides AIA extension)
responder_url = "http://ocsp.example.com"

# Caching and performance
cache_ttl_secs = 300       # Cache OCSP responses for 5 minutes
timeout_secs = 10          # OCSP request timeout

# Security settings
require_nonce = true       # Require OCSP nonce (RFC 6960 §4.4.1)
soft_fail = false          # Reject clients if OCSP check fails
```

### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | bool | false | Enable OCSP checking for client certificates |
| `responder_url` | string | None | Override OCSP responder URL; None = use AIA extension |
| `cache_ttl_secs` | u64 | 300 | Cache OCSP responses (seconds) |
| `timeout_secs` | u64 | 10 | OCSP request timeout (seconds) |
| `require_nonce` | bool | true | Require nonce in OCSP request/response |
| `soft_fail` | bool | false | Allow authentication if OCSP check fails |

### OCSP Responder URL

kipuka determines the OCSP responder URL using this priority:

1. **Configuration override**: `responder_url` if set
2. **AIA extension**: OCSP URL from certificate's Authority Information Access extension
3. **Fail**: Reject certificate if neither is available (unless `soft_fail = true`)

**When to use `responder_url` override:**

- All certificates use the same OCSP responder
- AIA extension points to an internal URL not reachable from kipuka's network
- Testing with a local OCSP responder

**Example:**

```toml
# Override for all certificates
responder_url = "http://ocsp.internal.example.com:8080"
```

**When to omit `responder_url`:**

- Certificates from multiple CAs with different OCSP responders
- AIA extensions are correctly configured and reachable
- Production environments (prefer AIA for proper PKI hygiene)

## Soft-Fail vs Hard-Fail

The `soft_fail` setting determines behavior when OCSP checking encounters errors.

### Hard-Fail Mode (Default)

```toml
soft_fail = false
```

**Behavior:**
- OCSP responder unreachable → Reject client certificate
- OCSP response timeout → Reject client certificate
- OCSP response invalid → Reject client certificate
- Certificate has no AIA extension → Reject client certificate

**Use when:**
- Security is paramount (zero-trust environments)
- OCSP infrastructure is highly available (99.9%+ uptime)
- Network connectivity to OCSP responders is reliable

**Risks:**
- Service outage if OCSP responder fails
- Denial of service if network connectivity is lost

### Soft-Fail Mode

```toml
soft_fail = true
```

**Behavior:**
- OCSP responder unreachable → Allow client certificate, log warning
- OCSP response timeout → Allow client certificate, log warning
- OCSP response invalid → Allow client certificate, log warning
- Certificate explicitly revoked → Reject client certificate
- Certificate has no AIA extension → Allow client certificate, log warning

**Use when:**
- Availability is more important than absolute security
- OCSP infrastructure has known reliability issues
- Gradual OCSP deployment (monitoring before enforcement)

**Risks:**
- Revoked certificates may be accepted if OCSP is down
- Increased attack surface during OCSP outages

**Recommendation:** Start with `soft_fail = true` in development, transition to `soft_fail = false` in production after verifying OCSP infrastructure reliability.

## Nonce Requirements

RFC 6960 §4.4.1 recommends using nonces to prevent OCSP response replay attacks.

### Nonce Enabled (Default)

```toml
require_nonce = true
```

**Behavior:**
- kipuka includes a random nonce in OCSP requests
- OCSP responder must echo the nonce in the response
- Responses without matching nonce are rejected

**Security benefit:**
- Prevents attacker from replaying old "good" responses for revoked certificates
- Ensures response freshness

**Compatibility:**
- All modern OCSP responders support nonces
- Some legacy responders may not support nonces

### Nonce Disabled

```toml
require_nonce = false
```

**Use when:**
- OCSP responder doesn't support nonces
- Interoperating with legacy PKI infrastructure
- OCSP responses are pre-generated and cached (can't include unique nonces)

**Security implication:**
- Attacker could replay old OCSP responses during the cache window
- Mitigation: Use shorter `cache_ttl_secs` (e.g., 60 seconds)

## Cache Behavior

kipuka caches OCSP responses in memory to reduce load on OCSP responders and improve performance.

### Cache Mechanics

1. **Cache key**: SHA-256 hash of certificate serial + issuer DN
2. **Cache value**: OCSP response (Good, Revoked, Unknown) + timestamp
3. **TTL**: `cache_ttl_secs` from time of OCSP response receipt
4. **Eviction**: LRU (Least Recently Used) when cache size limit reached

### Cache Tuning

```toml
# High-throughput deployment (many unique clients)
cache_ttl_secs = 600      # 10 minutes
cache_size_entries = 100000

# Low-latency deployment (few clients, strict freshness)
cache_ttl_secs = 60       # 1 minute
cache_size_entries = 1000
```

**Trade-offs:**

| TTL | OCSP Load | Revocation Delay | Latency |
|-----|-----------|------------------|---------|
| 60s | High | 0-60s | Low |
| 300s | Medium | 0-300s | Low |
| 600s | Low | 0-600s | Low |
| 3600s | Very Low | 0-3600s | Very Low |

**Recommendation:** Use `300-600` seconds for production environments. This balances OCSP responder load with reasonable revocation detection latency.

### Cache Invalidation

kipuka automatically invalidates cache entries when:

- TTL expires
- Certificate status changes from Good to Revoked (received from OCSP)
- Cache size limit exceeded (LRU eviction)
- kipuka restart (cache is not persisted to disk)

Manual cache invalidation:

```bash
# Clear OCSP cache via admin API
curl -X POST -H "Authorization: Bearer <admin-token>" \
  https://est.example.com/admin/api/v1/ocsp/cache/clear
```

## CRL Fallback

When OCSP is unavailable or disabled, kipuka automatically falls back to Certificate Revocation Lists (CRL).

### Fallback Scenarios

OCSP → CRL fallback occurs when:

1. `ocsp.enabled = false` (CRL-only mode)
2. OCSP responder unreachable and `soft_fail = true`
3. OCSP response timeout and `soft_fail = true`
4. Certificate has no AIA extension for OCSP

### CRL Configuration

```toml
[crl]
enabled = true
cache_ttl_secs = 3600       # Cache CRL for 1 hour
download_timeout_secs = 30  # CRL download timeout
max_crl_size_mb = 100       # Reject CRLs larger than 100 MB
```

CRL URLs are extracted from the certificate's CRL Distribution Points (CDP) extension.

### OCSP + CRL Combined

Best practice is to enable both:

```toml
[ocsp]
enabled = true
soft_fail = true   # Fallback to CRL on OCSP failure

[crl]
enabled = true
```

This provides:
- **Fast path**: OCSP for real-time revocation checking
- **Fallback**: CRL when OCSP is unavailable
- **Redundancy**: Multiple revocation mechanisms

## Performance Tuning

### Latency Analysis

OCSP checking adds latency to the TLS handshake:

| Component | Typical Latency |
|-----------|----------------|
| Network RTT to OCSP responder | 10-50ms |
| OCSP responder processing | 10-30ms |
| Signature verification | 5-10ms |
| **Total (cache miss)** | **25-90ms** |
| **Total (cache hit)** | **<1ms** |

### High-Throughput Optimization

For deployments with >1000 concurrent connections:

```toml
[ocsp]
enabled = true
cache_ttl_secs = 600           # Longer cache = fewer OCSP requests
timeout_secs = 5               # Shorter timeout = faster failure
soft_fail = true               # Avoid blocking on OCSP outages

# Connection pooling to OCSP responder
http_max_idle_connections = 100
http_max_connections_per_host = 50
```

### Network Optimization

Reduce OCSP latency by:

1. **Deploying local OCSP responders**: Place responders near kipuka instances
2. **Using HTTP/2**: Modern OCSP responders support HTTP/2 multiplexing
3. **Enabling OCSP stapling**: Clients provide OCSP responses during TLS handshake (future kipuka feature)

## Security Considerations

### OCSP Response Validation

kipuka performs these checks on OCSP responses:

1. **Signature verification**: Response signed by trusted OCSP responder
2. **Nonce match**: Response nonce matches request nonce (if `require_nonce = true`)
3. **Timestamp freshness**: Response producedAt within acceptable window
4. **Responder authorization**: Responder certificate authorized to sign OCSP responses

### OCSP Responder Trust

OCSP responders must be trusted via:

- **Delegated responder**: Responder certificate issued by the same CA that issued the client certificate
- **CA-signed responder**: Responder certificate has the `id-kp-OCSPSigning` extended key usage

kipuka validates the responder certificate chain and EKU before accepting responses.

### Replay Attack Prevention

Even with nonces, OCSP responses can be replayed within the cache window. Mitigate by:

- Using shorter `cache_ttl_secs` in high-security environments
- Enabling `require_nonce = true`
- Monitoring for unusual OCSP response patterns (same serial queried repeatedly)

### Privacy Considerations

OCSP requests reveal which certificates are being checked to the OCSP responder. This has privacy implications:

- **User tracking**: OCSP responder can track certificate usage patterns
- **Surveillance**: Network observers see OCSP queries

**Mitigations:**

- Use OCSP responders operated by trusted entities
- Consider CRL for privacy-sensitive deployments (queries are anonymous)
- Future: OCSP stapling (clients cache and provide their own responses)

## Monitoring and Observability

### Metrics

kipuka exposes Prometheus metrics for OCSP operations:

```
# OCSP check results
ocsp_checks_total{result="good"} 156234
ocsp_checks_total{result="revoked"} 12
ocsp_checks_total{result="unknown"} 3
ocsp_checks_total{result="error"} 45

# Cache performance
ocsp_cache_hits_total 298765
ocsp_cache_misses_total 5432
ocsp_cache_size_entries 8765

# Response times
ocsp_request_duration_seconds{quantile="0.5"} 0.025
ocsp_request_duration_seconds{quantile="0.9"} 0.089
ocsp_request_duration_seconds{quantile="0.99"} 0.156
```

### Logging

OCSP operations generate structured logs:

```json
{
  "timestamp": "2026-06-25T14:32:01Z",
  "level": "INFO",
  "event": "ocsp_check_success",
  "serial": "3a:b2:c4:d5:e6:f7:a8:b9",
  "issuer": "CN=Example CA",
  "status": "good",
  "cache_hit": true,
  "duration_ms": 0.8
}
```

```json
{
  "timestamp": "2026-06-25T14:35:12Z",
  "level": "WARN",
  "event": "ocsp_check_revoked",
  "serial": "1a:2b:3c:4d:5e:6f:7a:8b",
  "issuer": "CN=Example CA",
  "status": "revoked",
  "revocation_time": "2026-06-20T10:00:00Z",
  "revocation_reason": "keyCompromise"
}
```

```json
{
  "timestamp": "2026-06-25T14:40:00Z",
  "level": "ERROR",
  "event": "ocsp_check_failed",
  "serial": "9a:8b:7c:6d:5e:4f:3a:2b",
  "issuer": "CN=Example CA",
  "error": "timeout",
  "responder_url": "http://ocsp.example.com",
  "soft_fail": true
}
```

### Alerting Rules

Example Prometheus alerting rules:

```yaml
groups:
  - name: ocsp
    interval: 30s
    rules:
      - alert: OCSPHighErrorRate
        expr: |
          rate(ocsp_checks_total{result="error"}[5m]) > 0.1
        for: 5m
        annotations:
          summary: "High OCSP error rate"
          description: "OCSP checks failing at {{ $value }} errors/sec"

      - alert: OCSPResponderDown
        expr: |
          ocsp_checks_total{result="error"} > 0
        for: 2m
        annotations:
          summary: "OCSP responder appears down"
          description: "OCSP errors detected, responder may be unreachable"

      - alert: RevokedCertificateDetected
        expr: |
          increase(ocsp_checks_total{result="revoked"}[1m]) > 0
        annotations:
          summary: "Revoked certificate detected"
          description: "A revoked certificate attempted authentication"
```

## Troubleshooting

### OCSP timeout errors

**Symptoms:**
- `ocsp_checks_total{result="error"}` increasing
- Logs show "timeout" error

**Causes:**
1. OCSP responder slow or overloaded
2. Network connectivity issues
3. Firewall blocking OCSP traffic

**Diagnosis:**
```bash
# Test OCSP responder manually
openssl ocsp \
  -issuer ca-cert.pem \
  -cert client-cert.pem \
  -url http://ocsp.example.com \
  -resp_text

# Check network connectivity
curl -I http://ocsp.example.com
```

**Solution:**
- Increase `timeout_secs` if responder is consistently slow
- Enable `soft_fail = true` temporarily to avoid service disruption
- Contact CA to report OCSP responder performance issues
- Deploy local OCSP responder replica

### High OCSP load on responder

**Symptoms:**
- OCSP responder CPU/bandwidth saturation
- Slow OCSP responses

**Causes:**
- `cache_ttl_secs` too low
- Many unique client certificates (low cache hit rate)

**Solution:**
```toml
# Increase cache TTL to reduce OCSP queries
cache_ttl_secs = 600   # 10 minutes instead of 5

# Increase cache size to accommodate more certificates
cache_size_entries = 50000
```

Monitor `ocsp_cache_hits_total / (ocsp_cache_hits_total + ocsp_cache_misses_total)` — aim for >80% cache hit rate.

### Revoked certificate accepted

**Symptoms:**
- Known revoked certificate successfully authenticates

**Causes:**
1. OCSP response cached before revocation
2. `soft_fail = true` and OCSP responder down
3. Clock skew between kipuka and OCSP responder

**Diagnosis:**
```bash
# Check cache status
curl -H "Authorization: Bearer <admin-token>" \
  https://est.example.com/admin/api/v1/ocsp/cache/lookup?serial=3a:b2:c4:d5:e6:f7:a8:b9

# Force cache clear
curl -X POST -H "Authorization: Bearer <admin-token>" \
  https://est.example.com/admin/api/v1/ocsp/cache/clear
```

**Solution:**
- Clear OCSP cache to force fresh check
- Reduce `cache_ttl_secs` for faster revocation propagation
- Verify system clocks are synchronized (NTP)
- Switch to `soft_fail = false` to enforce strict checking

### No OCSP URL in certificate

**Symptoms:**
- Logs show "No AIA extension found" or "No OCSP URL"
- `ocsp_checks_total{result="error"}` increasing

**Causes:**
- Certificate lacks Authority Information Access extension
- AIA extension present but missing OCSP URL

**Diagnosis:**
```bash
# Check for AIA extension
openssl x509 -in client-cert.pem -text -noout | grep -A4 "Authority Information Access"

# Expected output:
# Authority Information Access:
#     OCSP - URI:http://ocsp.example.com
```

**Solution:**
- Configure CA to include AIA extension in issued certificates
- Set `responder_url` to provide fallback OCSP URL:
  ```toml
  responder_url = "http://ocsp.example.com"
  ```
- Enable CRL fallback:
  ```toml
  [crl]
  enabled = true
  ```

## Integration Examples

### Python OCSP Client

```python
#!/usr/bin/env python3
from cryptography import x509
from cryptography.x509 import ocsp
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import hashes
import requests

# Load certificate to check
with open("client-cert.pem", "rb") as f:
    cert = x509.load_pem_x509_certificate(f.read(), default_backend())

# Load issuer certificate
with open("issuer-cert.pem", "rb") as f:
    issuer = x509.load_pem_x509_certificate(f.read(), default_backend())

# Build OCSP request
builder = ocsp.OCSPRequestBuilder()
builder = builder.add_certificate(cert, issuer, hashes.SHA256())
req = builder.build()

# Send to OCSP responder
response = requests.post(
    "http://ocsp.example.com",
    data=req.public_bytes(serialization.Encoding.DER),
    headers={"Content-Type": "application/ocsp-request"}
)

# Parse OCSP response
ocsp_resp = ocsp.load_der_ocsp_response(response.content)

# Check status
if ocsp_resp.response_status == ocsp.OCSPResponseStatus.SUCCESSFUL:
    status = ocsp_resp.certificate_status
    if status == ocsp.OCSPCertStatus.GOOD:
        print("Certificate is GOOD")
    elif status == ocsp.OCSPCertStatus.REVOKED:
        print(f"Certificate REVOKED at {ocsp_resp.revocation_time}")
    else:
        print("Certificate status UNKNOWN")
else:
    print(f"OCSP error: {ocsp_resp.response_status}")
```

### OpenSSL OCSP Query

```bash
# Query OCSP responder for certificate status
openssl ocsp \
  -issuer ca-cert.pem \
  -cert client-cert.pem \
  -url http://ocsp.example.com \
  -header "Host" "ocsp.example.com" \
  -resp_text

# Output:
# OCSP Response Data:
#     OCSP Response Status: successful (0x0)
#     Response Type: Basic OCSP Response
#     ...
#     Cert Status: good
#     This Update: Jun 25 14:00:00 2026 GMT
#     Next Update: Jun 25 15:00:00 2026 GMT
```

## Best Practices

1. **Enable both OCSP and CRL**:
   ```toml
   [ocsp]
   enabled = true
   soft_fail = true
   
   [crl]
   enabled = true
   ```

2. **Use reasonable cache TTLs**: 300-600 seconds balances performance and freshness

3. **Monitor cache hit rate**: Target >80% to minimize OCSP responder load

4. **Start with soft-fail**: Deploy with `soft_fail = true`, transition to hard-fail after stability verification

5. **Require nonces**: Keep `require_nonce = true` for security unless compatibility issues arise

6. **Set appropriate timeouts**: `timeout_secs = 10` is reasonable for most networks

7. **Monitor revocation events**: Alert on `ocsp_checks_total{result="revoked"}` for security incidents

8. **Test OCSP infrastructure**: Periodically verify OCSP responder availability and performance

9. **Plan for OCSP outages**: Document incident response procedures for OCSP responder failures

10. **Keep clocks synchronized**: Use NTP to prevent timestamp-related OCSP validation failures
