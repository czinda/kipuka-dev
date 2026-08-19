# CMS-EST Configuration

CMS-EST (Cryptographic Message Syntax for EST) extends the Enrollment over Secure Transport protocol with CMS wrapping, as defined in RFC 8295. This enables EST operations in disconnected, air-gapped, or store-and-forward scenarios where direct HTTPS connectivity is unavailable.

## Overview

### CMS-EST vs Plain EST

Plain EST (RFC 7030) requires a direct HTTPS connection between client and server. CMS-EST allows:

- **Offline enrollment**: Generate CMS-wrapped requests on disconnected systems
- **Store-and-forward**: Transport requests via removable media, email, or batch processing
- **Enhanced security**: Mandatory message signing and optional encryption
- **Air-gapped operations**: No network connectivity required during request generation

The trade-off is increased complexity and message size due to CMS envelope overhead.

## Use Cases

### Air-Gapped Manufacturing

Enroll devices in a secure manufacturing facility without internet access:

1. Device generates CSR and wraps it in CMS on the factory floor
2. Operator transfers CMS file to network-connected workstation via USB
3. Workstation submits to kipuka CMS-EST endpoint
4. Signed certificate response is transferred back via USB
5. Device imports certificate

### Batch Processing

Process enrollment requests from hundreds of devices simultaneously:

1. Devices generate CMS-wrapped enrollment requests during off-peak hours
2. Requests are queued on a management server
3. Batch submission to kipuka during maintenance window
4. Encrypted responses are distributed back to devices

### Disconnected Field Operations

Military, maritime, or remote infrastructure scenarios:

1. Field technicians generate enrollment requests locally
2. Requests are stored until network connectivity is available
3. Periodic sync transfers requests to headquarters
4. Responses are synced back during next connectivity window

### Frozen Device Enrollment During PQC Migration

As organizations migrate from classical cryptography (RSA/ECC) to post-quantum algorithms (ML-DSA, ML-KEM), some devices **cannot migrate** — sealed hardware, regulatory-locked platforms (FDA 510(k), Common Criteria EAL4+), and long-lifecycle embedded systems (20-30 year weapon platforms, industrial SCADA controllers). These "frozen devices" will continue using classical certificates for their entire remaining service life.

CMS-EST is the enrollment protocol for frozen devices because these systems typically:

- Operate behind air gaps or data diodes with no direct CA connectivity
- Cannot run ACME clients (constrained protocol stacks)
- Require offline enrollment that survives network outages spanning weeks or months
- Need certificate renewal without firmware updates

**Enrollment workflow for frozen devices:**

1. Frozen device generates a CSR using its existing classical key (RSA/ECC)
2. CSR is wrapped in CMS `SignedData` for integrity and optionally `EnvelopedData` for confidentiality
3. CMS-wrapped request crosses the air gap via removable media, data diode, or courier
4. Operator submits to kipuka's CMS-EST endpoint on the connected network
5. kipuka processes the request against the Dogtag CA, which issues a classical certificate per the device's certificate profile
6. Signed certificate response is CMS-wrapped and carried back across the air gap
7. Device imports the certificate

**MTC transparency integration:**

When combined with Merkle Tree Certificate transparency logging, every classical certificate issued to a frozen device is recorded in a tamper-evident log. An independent monitor validates each issuance against a frozen device registry:

- **Authorized:** The device identity, issuing CA, and algorithm match the frozen device record → issuance proceeds normally
- **Unauthorized identity:** A classical certificate is requested for an entity not in the frozen device registry → alert (potential attack or misconfiguration)
- **Wrong CA:** A classical certificate for a known frozen device is issued by an unexpected CA → alert (CA compromise)
- **Wrong algorithm:** A classical certificate uses a weaker algorithm than authorized (e.g., RSA-1024 instead of RSA-2048) → alert (downgrade)
- **Expired authorization:** A classical certificate is requested after the frozen device record's expiry date → alert (device should have been migrated or decommissioned)

This turns frozen devices from an unmonitored security blind spot into an audited, policy-controlled exception within the broader PQC migration.

**Configuration for frozen device profiles:**

```toml
[cms_est]
enabled = true
require_signed_requests = true
encrypt_responses = true

# Frozen device certificate profiles restrict algorithm and validity
# These are enforced by the Dogtag CA certificate profile, not kipuka
# kipuka passes the enrollment request to the CA, which applies profile constraints
```

The Dogtag CA certificate profile for frozen devices should enforce:

- Classical algorithms only (RSA-2048, RSA-3072, or ECDSA-P256 per device capability)
- Maximum validity period aligned with the device's remaining service life
- Key usage restrictions appropriate to the device's function
- Extended key usage limiting the certificate's applicability

## Configuration

Enable CMS-EST in your `kipuka.toml` configuration:

```toml
[cms_est]
enabled = true

# Message protection requirements
require_signed_requests = true     # Mandate digital signatures on all requests
encrypt_responses = true           # Encrypt all response messages

# Encryption algorithms (in preference order)
allowed_content_encryption = [
    "AES-256-GCM",   # Preferred: AEAD with 256-bit key
    "AES-128-GCM",   # Fallback: AEAD with 128-bit key
    "AES-256-CBC"    # Legacy support (avoid if possible)
]
```

### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | bool | false | Enable CMS-EST endpoints |
| `require_signed_requests` | bool | true | Reject unsigned enrollment requests |
| `encrypt_responses` | bool | true | Encrypt certificate responses with recipient's public key |
| `allowed_content_encryption` | array | ["AES-256-GCM", "AES-128-GCM"] | Supported encryption algorithms (preference order) |

## Content Encryption Algorithms

kipuka supports three encryption algorithms for CMS-EST responses:

### AES-256-GCM (Recommended)

Authenticated Encryption with Associated Data (AEAD) providing both confidentiality and integrity. Requires clients support GCM mode.

**Advantages:**
- Single operation provides encryption and authentication
- No padding oracle vulnerabilities
- Faster than CBC for hardware-accelerated platforms

**Configuration:**
```toml
allowed_content_encryption = ["AES-256-GCM"]
```

### AES-128-GCM

Similar to AES-256-GCM but with 128-bit key length. Suitable for resource-constrained devices.

**Use when:**
- Client hardware lacks 256-bit AES support
- Regulatory requirements mandate AES-128 minimum
- Performance constraints require smaller key sizes

### AES-256-CBC (Legacy)

Cipher Block Chaining mode with 256-bit key. Included for backward compatibility with older CMS implementations.

**Considerations:**
- Requires separate HMAC for integrity protection
- Vulnerable to padding oracle attacks if improperly implemented
- Slower than GCM on modern hardware

**Only use if:**
- Interoperating with legacy systems that don't support GCM
- Regulatory compliance requires CBC mode specifically

## Request/Response Flow

### CMS-Wrapped Enrollment Request

1. **Client generates CSR**:
   ```bash
   openssl req -new -key device-key.pem -out device.csr
   ```

2. **Client wraps CSR in CMS**:
   ```bash
   # Sign the CSR with client's existing certificate
   openssl cms -sign \
     -in device.csr \
     -out device-cms-request.p7s \
     -signer client-cert.pem \
     -inkey client-key.pem \
     -outform DER \
     -binary \
     -nodetach
   ```

3. **Submit CMS request to kipuka**:
   ```bash
   curl -X POST \
     --data-binary @device-cms-request.p7s \
     -H "Content-Type: application/pkcs7-mime" \
     -o device-cms-response.p7c \
     https://est.example.com/.well-known/est/simpleenroll
   ```

4. **Client unwraps CMS response**:
   ```bash
   # Decrypt the response (if encrypted)
   openssl cms -decrypt \
     -in device-cms-response.p7c \
     -recip client-cert.pem \
     -inkey client-key.pem \
     -out device-cert.pem
   ```

### CMS-Wrapped Reenrollment

For certificate renewal, the flow is similar but uses the current certificate:

```bash
# 1. Generate new CSR
openssl req -new -key new-key.pem -out renew.csr

# 2. Sign with current certificate
openssl cms -sign \
  -in renew.csr \
  -out renew-cms-request.p7s \
  -signer current-cert.pem \
  -inkey current-key.pem \
  -outform DER \
  -binary

# 3. Submit to reenroll endpoint
curl -X POST \
  --data-binary @renew-cms-request.p7s \
  -H "Content-Type: application/pkcs7-mime" \
  -o renew-cms-response.p7c \
  https://est.example.com/.well-known/est/simplereenroll

# 4. Decrypt response
openssl cms -decrypt \
  -in renew-cms-response.p7c \
  -recip current-cert.pem \
  -inkey current-key.pem \
  -out renewed-cert.pem
```

## Security Considerations

### Signature Verification

When `require_signed_requests = true`, kipuka performs these checks on incoming CMS requests:

1. **Signature validity**: Cryptographic signature must verify against signer's certificate
2. **Certificate chain**: Signer's certificate must chain to a trusted root
3. **Certificate status**: Signer's certificate must not be revoked (OCSP/CRL check)
4. **Timestamp validation**: CMS signature timestamp must be within acceptable window

**Recommendation:** Always enable `require_signed_requests` in production. Unsigned requests bypass authentication and should only be allowed in isolated test environments.

### Response Encryption

When `encrypt_responses = true`, kipuka encrypts the certificate response using the public key from the signer's certificate. This ensures:

- **Confidentiality**: Certificate is only readable by the requesting device
- **Binding**: Response is cryptographically bound to the request
- **Non-repudiation**: Requester cannot claim they didn't receive the certificate

**Recommendation:** Enable encryption unless all CMS-EST operations occur over physically secure channels.

### Algorithm Selection

Order `allowed_content_encryption` from strongest to weakest:

```toml
allowed_content_encryption = [
    "AES-256-GCM",   # Try first
    "AES-128-GCM",   # Fallback for compatibility
]
# Omit AES-256-CBC unless required for legacy interop
```

kipuka selects the first algorithm supported by both client and server.

### Transport Security

CMS-EST still requires HTTPS transport when used over a network. The CMS wrapping provides:

- Protection of request/response content during offline storage
- End-to-end security spanning disconnected segments
- Defense against transport-layer downgrade attacks

Do not transmit CMS-EST messages over unencrypted HTTP.

## Example Workflows

### Air-Gapped Device Enrollment

**On disconnected device:**
```bash
# Generate key and CSR
openssl genpkey -algorithm RSA -out device-key.pem -pkeyopt rsa_keygen_bits:2048
openssl req -new -key device-key.pem -out device.csr \
  -subj "/CN=device-12345/O=Example Corp"

# Create self-signed temp cert for CMS signing (if no existing cert)
openssl req -x509 -key device-key.pem -out temp-cert.pem -days 1 \
  -subj "/CN=device-12345/O=Example Corp"

# Sign CSR with temp cert
openssl cms -sign -in device.csr -out device-cms-request.p7s \
  -signer temp-cert.pem -inkey device-key.pem -outform DER -binary

# Transfer device-cms-request.p7s to USB drive
```

**On network-connected workstation:**
```bash
# Submit to kipuka
curl -X POST \
  --data-binary @/media/usb/device-cms-request.p7s \
  -H "Content-Type: application/pkcs7-mime" \
  -o /media/usb/device-cms-response.p7c \
  https://est.example.com/.well-known/est/simpleenroll
```

**Back on disconnected device:**
```bash
# Extract certificate from response
openssl cms -decrypt \
  -in device-cms-response.p7c \
  -recip temp-cert.pem \
  -inkey device-key.pem \
  -out device-cert.pem

# Verify certificate
openssl x509 -in device-cert.pem -text -noout
```

### Batch Processing Script

```bash
#!/bin/bash
# batch-cms-enroll.sh - Process multiple CMS requests

REQUEST_DIR="/var/cms-est/requests"
RESPONSE_DIR="/var/cms-est/responses"
EST_URL="https://est.example.com/.well-known/est/simpleenroll"

for request in "$REQUEST_DIR"/*.p7s; do
    base=$(basename "$request" .p7s)
    echo "Processing $base..."
    
    curl -X POST \
      --data-binary @"$request" \
      -H "Content-Type: application/pkcs7-mime" \
      -o "$RESPONSE_DIR/${base}.p7c" \
      -w "HTTP %{http_code}\n" \
      "$EST_URL"
    
    if [ $? -eq 0 ]; then
        echo "  ✓ Response saved to $RESPONSE_DIR/${base}.p7c"
        mv "$request" "$REQUEST_DIR/processed/"
    else
        echo "  ✗ Failed to process $base"
    fi
done
```

## Troubleshooting

### "CMS signature verification failed"

**Cause:** Signer's certificate doesn't chain to a trusted root, or the signature is invalid.

**Solution:**
1. Verify the signer's certificate chains to a CA trusted by kipuka
2. Check that the private key used for signing matches the certificate
3. Ensure the signer's certificate is not expired or revoked
4. Inspect server logs for detailed verification errors

### "Unsupported content encryption algorithm"

**Cause:** Client requested an encryption algorithm not in `allowed_content_encryption`.

**Solution:**
1. Add the algorithm to the server configuration:
   ```toml
   allowed_content_encryption = ["AES-256-GCM", "AES-128-GCM", "AES-256-CBC"]
   ```
2. Or update the client to request a supported algorithm
3. Check client and server logs for algorithm negotiation details

### Response decryption fails

**Cause:** Response was encrypted for a different recipient certificate.

**Solution:**
1. Ensure the certificate used for decryption matches the one used to sign the request
2. Verify the decryption key corresponds to the certificate's public key
3. Check for corruption during file transfer (verify file hash)

### Large message sizes

**Cause:** CMS envelope overhead adds significant size to requests/responses.

**Solution:**
- Use binary DER encoding instead of PEM (saves ~33% space)
- Minimize certificate chain length by using direct trust anchors
- Compress CMS files during transport (CMS content is not compressible, but envelope metadata is)
- Consider plain EST for high-volume, connected deployments

## Integration Examples

### Python Client

```python
#!/usr/bin/env python3
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.backends import default_backend
import requests

# Generate key
private_key = rsa.generate_private_key(
    public_exponent=65537,
    key_size=2048,
    backend=default_backend()
)

# Create CSR
csr = x509.CertificateSigningRequestBuilder().subject_name(
    x509.Name([
        x509.NameAttribute(x509.NameOID.COMMON_NAME, "device-67890"),
        x509.NameAttribute(x509.NameOID.ORGANIZATION_NAME, "Example Corp"),
    ])
).sign(private_key, hashes.SHA256(), default_backend())

# Wrap in CMS (requires python-cms library)
# ... CMS signing code ...

# Submit to kipuka
response = requests.post(
    "https://est.example.com/.well-known/est/simpleenroll",
    data=cms_request,
    headers={"Content-Type": "application/pkcs7-mime"}
)

# Unwrap CMS response
# ... CMS decryption code ...
```

## Performance Considerations

CMS-EST operations are slower than plain EST due to:

- **Signature verification**: ~10-50ms per request depending on key size
- **Encryption/decryption**: ~5-20ms per response
- **Certificate validation**: ~50-200ms including OCSP/CRL checks

For high-throughput deployments:

1. Cache trusted certificates to reduce chain validation overhead
2. Use OCSP stapling to eliminate outbound OCSP requests
3. Consider hardware acceleration for AES-GCM operations
4. Batch multiple enrollment requests when possible

Typical throughput: 100-500 CMS-EST enrollments per second on modern server hardware.
