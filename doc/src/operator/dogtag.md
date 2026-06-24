# Dogtag PKI Integration

## Overview

kipuka can use Red Hat Certificate System (Dogtag PKI) as a backend CA instead of, or alongside, file-based or HSM-backed local CAs. This integration enables organizations already running Dogtag/RHCS to add EST enrollment capabilities without modifying their existing PKI infrastructure.

**Architecture:**

- Dogtag provides a full-featured PKI with REST API, comprehensive audit logging, HSM support, and complete certificate lifecycle management
- kipuka acts as an EST frontend (Registration Authority) to Dogtag's CA subsystem
- The integration preserves all Dogtag policies, approval workflows, and certificate profiles while exposing EST protocol endpoints

**Benefits:**

- Leverage existing Dogtag infrastructure and operational expertise
- Maintain centralized certificate policy enforcement in Dogtag profiles
- Benefit from Dogtag's enterprise features: HSM integration, audit trails, approval workflows, Key Recovery Authority (KRA)
- Add EST enrollment to IoT devices, network equipment, and mobile endpoints without deploying new CA infrastructure

## REST API Client

kipuka communicates with Dogtag exclusively via its REST API, typically exposed at `https://dogtag.example.com:8443/ca/rest/certrequests`.

### Authentication

kipuka authenticates to Dogtag using a client certificate (agent cert) that has enrollment privileges. This certificate must be issued by the Dogtag CA itself and associated with an agent user in the Dogtag database.

**Obtaining an agent certificate:**

1. On the Dogtag server, create an agent user (if not already present):
   ```bash
   pki -d /var/lib/pki/pki-tomcat/alias -c <password> \
       ca-user-add kipuka-agent --fullName "kipuka EST RA"
   ```

2. Generate a certificate request and submit it for the agent certificate:
   ```bash
   pki -d /var/lib/pki/pki-tomcat/alias -c <password> \
       client-cert-request "CN=kipuka EST RA,O=Example Corp" \
       --profile caAgentServerCert
   ```

3. Approve and issue the certificate via the Dogtag web UI or CLI

4. Export the agent certificate and key for use by kipuka

### Configuration

Configure Dogtag as a CA entry with `type = "dogtag"`:

```toml
[[ca]]
id = "dogtag-ca"
name = "Dogtag Enterprise CA"
type = "dogtag"

# Dogtag instance URL (without /ca/rest suffix)
url = "https://dogtag.example.com:8443"

# Agent certificate for authenticating to Dogtag
agent_cert = "/etc/kipuka/dogtag/agent.pem"
agent_key = "/etc/kipuka/dogtag/agent-key.pem"

# Dogtag CA certificate chain for TLS verification
ca_cert = "/etc/kipuka/dogtag/ca-chain.pem"

# Default certificate profile for this CA
profile = "caServerCert"

# Optional: Request timeout (default: 30s)
timeout = "30s"

# Optional: Enable certificate caching to reduce Dogtag load
cache_certificates = true
cache_ttl = "1h"
```

**File formats:**

- `agent_cert` and `ca_cert`: PEM-encoded X.509 certificates
- `agent_key`: PEM-encoded RSA or EC private key (can be encrypted; kipuka will prompt for passphrase)

## Enrollment

When kipuka receives an EST `/simpleenroll` request, it translates the PKCS#10 CSR into a Dogtag certificate enrollment request and submits it to the Dogtag REST API.

### Profile Mapping

Dogtag uses certificate profiles (e.g., `caServerCert`, `caUserCert`, `caTPSCert`) to define certificate content, extensions, and policy constraints. kipuka maps EST labels to Dogtag profiles:

```toml
[[est.label]]
name = "server-tls"
ca_id = "dogtag-ca"
dogtag_profile = "caServerCert"

[[est.label]]
name = "client-auth"
ca_id = "dogtag-ca"
dogtag_profile = "caUserCert"

[[est.label]]
name = "token-signing"
ca_id = "dogtag-ca"
dogtag_profile = "caTPSCert"
```

**Default profile:** If no label is provided in the EST request, the `profile` specified in the `[[ca]]` entry is used.

### Enrollment Flow

1. Client sends EST `/simpleenroll` request with PKCS#10 CSR
2. kipuka validates the CSR and authenticates the client (via HTTP Basic or TLS client cert)
3. kipuka determines the Dogtag profile based on the EST label
4. kipuka submits the CSR to Dogtag: `POST /ca/rest/certrequests`
5. Dogtag processes the request according to the profile policy:
   - If auto-approval is enabled in the profile, the certificate is issued immediately
   - If approval is required, the request enters pending state
6. kipuka polls Dogtag until the certificate is issued (or timeout expires)
7. kipuka returns the issued certificate to the EST client in PKCS#7 format

### Manual Approval Workflow

If the Dogtag profile requires manual approval (common for high-assurance certificates):

1. The enrollment request remains in Dogtag's pending queue
2. An agent approves the request via Dogtag web UI or CLI:
   ```bash
   pki ca-cert-request-review <request_id> --action approve
   ```
3. kipuka's next poll retrieves the issued certificate
4. The EST client receives the certificate (this may take seconds to minutes depending on poll interval)

**Polling configuration:**

```toml
[[ca]]
id = "dogtag-ca"
type = "dogtag"
# ... other config ...

# Poll interval for pending certificate requests (default: 5s)
poll_interval = "5s"

# Maximum time to wait for approval (default: 5m)
approval_timeout = "5m"
```

If `approval_timeout` expires before the certificate is issued, kipuka returns an HTTP 202 response to the client with a retry-after header.

## Revocation

kipuka's Admin API revocation calls are forwarded to Dogtag's revocation endpoint.

### Revoke via Admin API

```bash
curl -X POST https://kipuka.example.com/admin/revoke \
  -H "Authorization: Bearer <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "serial": "0x1A2B3C4D",
    "reason": "keyCompromise"
  }'
```

### Revocation Flow

1. kipuka receives the revocation request via Admin API
2. kipuka maps the serial number to the issuing CA (in this case, `dogtag-ca`)
3. kipuka submits a revocation request to Dogtag: `POST /ca/rest/agent/certs/<serial>/revoke`
4. Dogtag revokes the certificate and updates its internal database
5. Dogtag automatically updates CRLs and OCSP responder (if enabled)
6. kipuka returns success to the caller

### Revocation Reason Mapping

kipuka maps its revocation reason codes to Dogtag's reason codes per RFC 5280:

| kipuka Reason       | Dogtag Reason Code | RFC 5280 Code |
|---------------------|--------------------|---------------|
| `unspecified`       | 0                  | 0             |
| `keyCompromise`     | 1                  | 1             |
| `caCompromise`      | 2                  | 2             |
| `affiliationChanged`| 3                  | 3             |
| `superseded`        | 4                  | 4             |
| `cessationOfOperation` | 5               | 5             |
| `certificateHold`   | 6                  | 6             |
| `removeFromCRL`     | 8                  | 8             |
| `privilegeWithdrawn`| 9                  | 9             |
| `aaCompromise`      | 10                 | 10            |

**Note:** Dogtag does not support `removeFromCRL` (un-hold) via the REST API for certificates revoked with `certificateHold`. Use the Dogtag CLI for un-hold operations.

## KRA Server-Side Key Generation

EST's `/serverkeygen` endpoint can use Dogtag's Key Recovery Authority (KRA) subsystem for server-side key generation and archival.

### Overview

When server-side key generation is requested:

1. kipuka forwards the request to Dogtag with the KRA archival flag enabled
2. Dogtag's KRA subsystem generates the key pair server-side
3. The private key is encrypted and archived in the KRA database
4. Dogtag issues the certificate using the generated public key
5. kipuka receives both the certificate and the encrypted private key
6. The private key is returned to the EST client as a PKCS#8 `EncryptedPrivateKeyInfo` wrapped in the EST response

### Prerequisites

- Dogtag KRA subsystem must be installed and configured
- The KRA must be configured to communicate with the CA subsystem
- The agent certificate used by kipuka must have key archival privileges

### Configuration

```toml
[[ca]]
id = "dogtag-ca"
type = "dogtag"
url = "https://dogtag.example.com:8443"

# KRA endpoint (often same host as CA)
kra_url = "https://dogtag.example.com:8443"

# KRA agent credentials (may be same as CA agent or separate)
kra_agent_cert = "/etc/kipuka/dogtag/kra-agent.pem"
kra_agent_key = "/etc/kipuka/dogtag/kra-agent-key.pem"

# ... other CA config ...
```

**If `kra_url` is not specified, server-side key generation is disabled for this CA.**

### EST Request

```bash
curl -X POST https://kipuka.example.com/.well-known/est/serverkeygen \
  --user client:password \
  --cacert ca.pem \
  -H "Content-Type: application/pkcs10" \
  --data-binary @csr.p10 \
  -o response.p7
```

The response is a PKCS#7 structure containing:

- The issued certificate
- The encrypted private key (PKCS#8 EncryptedPrivateKeyInfo)
- Optional additional CA certificates

**Client-side decryption:** The client must decrypt the private key using the password provided during enrollment (passed in the CSR's challenge password attribute, or via out-of-band key).

### Key Recovery

If a client loses their private key, authorized users can recover it from the KRA:

```bash
pki kra-key-recover --keyID <key_id> --output recovered-key.p12
```

This operation requires dual approval from KRA agents (depending on KRA policy).

## Multi-CA Pool with Circuit Breaker

Multiple Dogtag instances can be configured as separate CA entries to provide high availability and load distribution.

### Configuration

```toml
[[ca]]
id = "dogtag-primary"
type = "dogtag"
url = "https://dogtag1.example.com:8443"
agent_cert = "/etc/kipuka/dogtag/agent.pem"
agent_key = "/etc/kipuka/dogtag/agent-key.pem"
ca_cert = "/etc/kipuka/dogtag/ca-chain.pem"
profile = "caServerCert"

[[ca]]
id = "dogtag-secondary"
type = "dogtag"
url = "https://dogtag2.example.com:8443"
agent_cert = "/etc/kipuka/dogtag/agent.pem"
agent_key = "/etc/kipuka/dogtag/agent-key.pem"
ca_cert = "/etc/kipuka/dogtag/ca-chain.pem"
profile = "caServerCert"

[ha]
enabled = true
strategy = "active-passive"

[[ha.group]]
name = "dogtag-pool"
ca_ids = ["dogtag-primary", "dogtag-secondary"]

# Health check interval
health_check_interval = "30s"

# Circuit breaker thresholds
failure_threshold = 3
success_threshold = 2
timeout = "10s"
```

### Failover Behavior

**Active-Passive Strategy:**

- All requests are routed to `dogtag-primary`
- If `dogtag-primary` fails health checks (3 consecutive failures), the circuit breaker trips
- Traffic is routed to `dogtag-secondary` while `dogtag-primary` is unavailable
- Once `dogtag-primary` passes health checks (2 consecutive successes), traffic is restored to primary

**Active-Active Strategy (future):**

```toml
[ha]
enabled = true
strategy = "active-active"

[[ha.group]]
name = "dogtag-pool"
ca_ids = ["dogtag-primary", "dogtag-secondary"]
load_balancing = "round-robin"  # or "least-connections"
```

### Health Checks

kipuka performs health checks against each Dogtag instance:

```http
GET /ca/rest/certs/ca HTTP/1.1
Host: dogtag1.example.com:8443
```

A successful response (HTTP 200 with the CA certificate) indicates the instance is healthy.

**Monitoring endpoint:**

```bash
curl https://kipuka.example.com/health/ca
```

Response:

```json
{
  "dogtag-primary": {
    "status": "healthy",
    "last_check": "2026-06-24T10:30:00Z",
    "consecutive_failures": 0
  },
  "dogtag-secondary": {
    "status": "circuit_open",
    "last_check": "2026-06-24T10:30:00Z",
    "consecutive_failures": 5
  }
}
```

## Full CMC Passthrough (RFC 5272)

When `fullcmc = true` in the `[est]` configuration, kipuka can pass Full CMC (Certificate Management over CMS) requests directly to Dogtag.

### Overview

Full CMC (RFC 5272/5273/5274) supports complex certificate management operations beyond simple enrollment:

- Batch enrollment (multiple certificates in a single request)
- Certificate update/renewal
- Key recovery requests
- Revocation requests
- Get certificate/CRL operations

Dogtag is one of the few CAs that fully implements RFC 5272/5273/5274, making it ideal for enterprise CMC deployments.

### Configuration

```toml
[est]
enabled = true
fullcmc = true

# Optional: CMC-specific settings
[est.cmc]
# Maximum CMC message size (default: 10MB)
max_message_size = "10MB"

# Allow unsigned CMC requests (default: false)
allow_unsigned = false
```

### CMC Request Flow

1. Client constructs a Full CMC request (typically using `CMCRequest` tool or smart card management software)
2. Client submits the CMC request to kipuka's EST endpoint: `POST /.well-known/est/fullcmc`
3. kipuka validates the CMC request structure and authenticates the client
4. kipuka forwards the CMC payload to Dogtag: `POST /ca/rest/certrequests/cmc`
5. Dogtag processes the CMC request according to its internal policies
6. Dogtag returns a CMC Full PKI Response
7. kipuka returns the CMC response to the EST client

### Example: Batch Enrollment via CMC

```bash
# Create a CMC request with multiple CSRs
CMCRequest \
  -d /path/to/nssdb \
  -i csr1.pem \
  -i csr2.pem \
  -i csr3.pem \
  -o batch-request.cmc

# Submit to kipuka
curl -X POST https://kipuka.example.com/.well-known/est/fullcmc \
  --user agent:password \
  --cacert ca.pem \
  -H "Content-Type: application/pkcs7-mime" \
  --data-binary @batch-request.cmc \
  -o batch-response.cmc

# Parse the response
CMCResponse -d /path/to/nssdb -i batch-response.cmc
```

### Token Processing System (TPS) Integration

Dogtag's Token Processing System (TPS) uses Full CMC for smart card lifecycle management:

- Format and enroll smart cards
- Update certificates on existing tokens
- Recover keys from KRA to re-provision tokens

kipuka acts as a CMC gateway, enabling TPS to operate over EST endpoints. This is particularly useful for remote TPS operations where direct Dogtag access is restricted by firewall policy.

**TPS configuration example:**

```toml
[[ca]]
id = "dogtag-ca"
type = "dogtag"
url = "https://dogtag.example.com:8443"
kra_url = "https://dogtag.example.com:8443"
tps_url = "https://dogtag.example.com:8443"
# ... agent certs ...

[est.cmc]
# TPS may send large CMC messages with multiple key recovery requests
max_message_size = "50MB"

# TPS operations require signed CMC requests
allow_unsigned = false
```

## Prerequisites

Before configuring kipuka with Dogtag integration, ensure:

1. **Dogtag PKI Installation:**
   - Dogtag PKI 10.x or 11.x (RHEL 7/8/9: Red Hat Certificate System 9.x or 10.x)
   - Fedora: Dogtag PKI 11.x available via dnf
   - CA subsystem installed and operational

2. **Agent Certificate:**
   - Agent certificate issued by the Dogtag CA with enrollment privileges
   - For KRA integration: separate agent cert with key archival/recovery privileges
   - Agent user configured in Dogtag database and added to appropriate groups

3. **Network Connectivity:**
   - kipuka must reach Dogtag REST API port (default: 8443)
   - If using Dogtag behind a load balancer, ensure session affinity for approval workflows
   - Firewall rules permit bidirectional HTTPS between kipuka and Dogtag

4. **TLS Certificates:**
   - Dogtag CA certificate chain for TLS verification
   - If Dogtag uses a private CA, install the root and intermediate certificates on kipuka host

5. **Optional: KRA Subsystem:**
   - KRA installed and configured if server-side key generation is required
   - KRA transport certificate and storage certificate properly configured
   - KRA connector enabled in CA subsystem

6. **Profiles:**
   - Ensure the certificate profiles referenced in kipuka configuration exist in Dogtag
   - Verify profile policies match your security requirements
   - Test profile submission via Dogtag CLI before configuring kipuka

### Verification

Test Dogtag connectivity from the kipuka host:

```bash
# Verify CA REST API is accessible
curl -k https://dogtag.example.com:8443/ca/rest/certs/ca

# Submit a test certificate request using agent cert
curl -k https://dogtag.example.com:8443/ca/rest/certrequests \
  -X POST \
  --cert /etc/kipuka/dogtag/agent.pem \
  --key /etc/kipuka/dogtag/agent-key.pem \
  -H "Content-Type: application/json" \
  -d '{
    "ProfileID": "caServerCert",
    "Renewal": false,
    "Input": [{
      "Name": "cert_request_type",
      "Value": "pkcs10"
    }, {
      "Name": "cert_request",
      "Value": "<base64-encoded-csr>"
    }]
  }'
```

A successful response indicates the agent certificate is configured correctly and has enrollment privileges.

## See Also

- [High Availability Configuration](ha.md) for general HA strategies
- [Admin API Reference](../api/admin.md) for revocation endpoints
- [Certificate Profiles](profiles.md) for mapping EST labels to CA profiles
- Red Hat Certificate System documentation: https://access.redhat.com/documentation/en-us/red_hat_certificate_system/
- Dogtag PKI wiki: https://www.dogtagpki.org/wiki/PKI_Main_Page
