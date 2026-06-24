# Certificate Authorities

kipuka supports multiple Certificate Authorities (CAs) through its `[[ca]]` array configuration. This architecture enables operators to serve different trust domains, key algorithms, and PKI hierarchies from a single EST server instance.

## Multi-CA Architecture

Each CA in kipuka is defined by a unique `id` field used to bind EST labels to specific certificate authorities. Multiple CAs are configured in `kipuka.toml`:

```toml
[[ca]]
id = "internal-rsa"
cert = "/etc/kipuka/ca/internal-rsa-ca.crt"
key = "/etc/kipuka/ca/internal-rsa-ca.key"
chain = "/etc/kipuka/ca/internal-rsa-chain.pem"
max_validity_days = 90

[[ca]]
id = "external-ecdsa"
cert = "/etc/kipuka/ca/external-ecdsa-ca.crt"
key = "/etc/kipuka/ca/external-ecdsa-ca.key"
chain = "/etc/kipuka/ca/external-ecdsa-chain.pem"
max_validity_days = 90
```

### Use Cases for Multiple CAs

**Separate Trust Domains**: Internal infrastructure certificates from one CA, external-facing services from another. This isolation prevents compromise of one domain from affecting the other.

**Algorithm Migration**: Run both RSA and ECDSA CAs simultaneously to support legacy clients while transitioning to modern algorithms.

**Tiered Assurance Levels**: Different CAs for different assurance requirements (standard validation vs. extended validation, different key sizes).

**Geographic or Organizational Boundaries**: Separate CAs for different regions or business units within an organization.

**Development vs. Production**: Dedicated CAs for testing environments prevent accidental trust of development certificates in production.

## CA Lifecycle

### Creating a Root CA

Generate a self-signed root CA private key and certificate:

```bash
# RSA 4096-bit root CA
openssl genrsa -out root-ca.key 4096
openssl req -new -x509 -days 7300 -key root-ca.key -out root-ca.crt \
  -subj "/C=US/O=Example Corp/CN=Example Root CA"

# ECDSA P-384 root CA
openssl ecparam -name secp384r1 -genkey -noout -out root-ca.key
openssl req -new -x509 -days 7300 -key root-ca.key -out root-ca.crt \
  -subj "/C=US/O=Example Corp/CN=Example Root CA"
```

Root CAs typically have 10-20 year validity periods and are kept offline. The root private key should be stored in secure offline storage (HSM, encrypted media in a safe).

### Creating an Intermediate CA

Generate an intermediate CA signed by the root:

```bash
# Generate intermediate CA private key
openssl ecparam -name prime256v1 -genkey -noout -out intermediate-ca.key

# Create CSR for intermediate CA
openssl req -new -key intermediate-ca.key -out intermediate-ca.csr \
  -subj "/C=US/O=Example Corp/CN=Example Issuing CA"

# Sign intermediate CSR with root CA (5 year validity)
openssl x509 -req -in intermediate-ca.csr -CA root-ca.crt -CAkey root-ca.key \
  -CAcreateserial -out intermediate-ca.crt -days 1825 \
  -extensions v3_ca -extfile openssl-ca.cnf
```

The `openssl-ca.cnf` must include intermediate CA extensions:

```ini
[v3_ca]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
```

### Building the Certificate Chain

The chain file contains certificates from the issuing CA up to (but typically not including) the root:

```bash
# Create chain file (intermediate only, root excluded)
cat intermediate-ca.crt > chain.pem

# If there are multiple intermediates, order from issuing CA to root:
# cat issuing-intermediate.crt sub-intermediate.crt > chain.pem
```

Chain ordering is critical: the first certificate in the chain must be the issuer of the end-entity certificate, and each subsequent certificate must be the issuer of the previous one.

### Configuring kipuka to Use the Intermediate

```toml
[[ca]]
id = "prod-issuing-ca"
cert = "/etc/kipuka/ca/intermediate-ca.crt"
key = "/etc/kipuka/ca/intermediate-ca.key"
chain = "/etc/kipuka/ca/chain.pem"
max_validity_days = 90
```

The `/cacerts` endpoint returns the intermediate certificate plus the chain (but not the root). Clients must have the root CA in their trust store independently.

## Key Types and Recommendations

### RSA Keys

```bash
# RSA 2048-bit (legacy compatibility)
openssl genrsa -out ca-rsa2048.key 2048

# RSA 3072-bit (transitional strength)
openssl genrsa -out ca-rsa3072.key 3072

# RSA 4096-bit (high assurance, slower)
openssl genrsa -out ca-rsa4096.key 4096
```

**RSA 2048**: Minimum for legacy compatibility. Acceptable for short-lived certificates (under 100 days). Avoid for new deployments.

**RSA 3072**: Equivalent security to AES-128. Reasonable choice for transitional deployments.

**RSA 4096**: Equivalent security to AES-256. Use for long-lived root CAs. Performance penalty for signing and verification operations.

### ECDSA Keys

```bash
# NIST P-256 (secp256r1, prime256v1)
openssl ecparam -name prime256v1 -genkey -noout -out ca-p256.key

# NIST P-384 (secp384r1)
openssl ecparam -name secp384r1 -genkey -noout -out ca-p384.key

# NIST P-521 (secp521r1)
openssl ecparam -name secp521r1 -genkey -noout -out ca-p521.key
```

**P-256 (prime256v1)**: Recommended for general use. Equivalent security to AES-128. Wide client support, fast operations, small certificate size.

**P-384**: Equivalent security to AES-192. Use for high-assurance environments. Moderate performance impact.

**P-521**: Equivalent security to AES-256. Use for maximum security requirements. Larger certificates and slower operations than P-256.

### Algorithm Selection Guidance

For new deployments, prefer **ECDSA P-256** unless specific requirements dictate otherwise:

- Smaller key and certificate sizes reduce bandwidth
- Faster signing and verification operations
- Equivalent or better security than RSA 2048
- Supported by all modern clients (TLS 1.2+, most TLS 1.3 implementations)

Use **RSA 2048** only when legacy client compatibility is required (older embedded devices, Windows XP, ancient Java versions).

Use **P-384** or **RSA 4096** for root CAs in high-assurance environments where the performance penalty is acceptable.

## HSM-Backed vs File-Based Keys

### File-Based Keys

File-based keys are stored as PEM-encoded files on the filesystem:

```toml
[[ca]]
id = "file-based-ca"
cert = "/etc/kipuka/ca/ca.crt"
key = "/etc/kipuka/ca/ca.key"
chain = "/etc/kipuka/ca/chain.pem"
max_validity_days = 90
```

**Advantages**:
- Simple configuration and operation
- No additional hardware or drivers required
- Easy backup and disaster recovery
- Standard OpenSSL tooling for key generation

**Disadvantages**:
- Private key exists in cleartext on disk (even if file permissions are restrictive)
- Key compromise if filesystem is breached
- No audit trail for key usage
- Key can be copied without detection

**Security Measures for File-Based Keys**:
- Store keys on encrypted filesystems
- Use file permissions to restrict access (mode 0400, root-owned)
- Consider encrypted key files with passphrase protection (requires manual unlock on service start)
- Implement filesystem integrity monitoring (AIDE, Tripwire)
- Regular key rotation

### HSM-Backed Keys

HSM-backed keys reference a PKCS#11 token and slot instead of filesystem paths:

```toml
[hsm]
module = "/usr/lib64/libsofthsm2.so"
pin = "1234"

[[ca]]
id = "hsm-backed-ca"
cert = "/etc/kipuka/ca/ca.crt"
hsm_slot = 0
chain = "/etc/kipuka/ca/chain.pem"
max_validity_days = 90
```

**Advantages**:
- Private key never leaves the HSM hardware
- Tamper-resistant hardware with physical security controls
- Audit logging of all key usage operations
- FIPS 140-2/140-3 compliance available
- Key backup and recovery through HSM vendor mechanisms

**Disadvantages**:
- Additional hardware cost and complexity
- PKCS#11 driver setup and maintenance
- Potential performance bottleneck for high-volume signing
- Vendor lock-in for key backup/recovery
- Operational complexity (HSM initialization, token management, PIN management)

**HSM Selection Considerations**:

Network HSMs (Thales Luna, Entrust nShield) provide centralized key management and high availability but introduce network dependencies.

USB HSMs (YubiHSM, Nitrokey HSM) offer lower cost and simpler deployment but limited performance and single points of failure.

Software HSMs (SoftHSM) provide PKCS#11 API compatibility for testing but offer no security advantage over file-based keys.

For production issuing CAs, network HSMs are recommended. For offline root CAs, USB HSMs stored in physically secure locations are acceptable.

## Certificate Chain Configuration

The `chain` parameter provides the certificate chain from the issuing CA to the root (root typically excluded). This chain is returned via the `/cacerts` endpoint.

### Chain File Format

Chain files are PEM-encoded, containing one or more certificates. Order matters:

```
-----BEGIN CERTIFICATE-----
[Issuing Intermediate CA Certificate]
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
[Sub-Intermediate CA Certificate, if any]
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
[Root CA Certificate - optional, often excluded]
-----END CERTIFICATE-----
```

### Chain Ordering Rules

1. First certificate is the issuer of the end-entity certificates that the CA signs
2. Each subsequent certificate is the issuer of the previous certificate
3. Last certificate is either the root CA or the certificate directly issued by the root
4. Root CA is often excluded from the chain (clients must have it in their trust store)

### Why Exclude the Root CA

Most TLS/PKI implementations expect clients to have the root CA in their local trust store. Including the root in the chain:

- Increases bandwidth unnecessarily
- May cause validation issues with strict clients
- Violates some certificate profile specifications

However, some closed environments include the root in the chain for convenience. kipuka supports both approaches.

### Verifying Chain Correctness

```bash
# Verify the intermediate can be validated against the root
openssl verify -CAfile root-ca.crt intermediate-ca.crt

# Verify the complete chain
openssl verify -CAfile root-ca.crt -untrusted chain.pem end-entity.crt
```

### Multiple Intermediate Levels

For deep hierarchies (root -> policy CA -> issuing CA):

```bash
# Build chain with two intermediates
cat issuing-ca.crt policy-ca.crt > chain.pem

# Root CA is still excluded
```

kipuka returns the issuing CA certificate concatenated with the `chain` file contents via `/cacerts`.

## CA/B Forum Validity Limits

The CA/Browser Forum mandates maximum validity periods for publicly-trusted certificates. These limits progressively shorten:

| Effective Date | Maximum Validity |
|---------------|-----------------|
| Current       | 398 days        |
| March 15, 2026 | 200 days       |
| March 15, 2027 | 100 days       |
| March 15, 2029 | 47 days        |

### Configuring max_validity_days

The `max_validity_days` parameter in each `[[ca]]` section enforces these limits:

```toml
[[ca]]
id = "public-ca-2026"
cert = "/etc/kipuka/ca/ca.crt"
key = "/etc/kipuka/ca/ca.key"
chain = "/etc/kipuka/ca/chain.pem"
max_validity_days = 200  # Ready for March 2026 limit
```

kipuka rejects CSRs requesting validity beyond `max_validity_days`. Clients must request shorter lifetimes or accept the CA's default.

### Planning for Shorter Lifetimes

**March 2026 (200 days)**: Transition to quarterly certificate renewal cycles. Most organizations can adapt existing manual processes.

**March 2027 (100 days)**: Manual renewal becomes impractical. EST-based automation is essential. Plan for 90-day certificate lifetimes to allow renewal buffer.

**March 2029 (47 days)**: Monthly or bi-weekly renewal cycles. Full automation required. No manual certificate issuance workflows can scale.

### Why Shorter Lifetimes Drive EST Adoption

**Reduced Blast Radius**: Compromised keys have limited validity windows. Stolen certificates expire quickly.

**Faster Cryptographic Agility**: Transitioning to new algorithms (post-quantum cryptography) becomes operationally feasible when certificates renew frequently.

**Improved Revocation Handling**: Short lifetimes reduce reliance on CRL and OCSP infrastructure. Expired certificates are automatically untrusted.

**Forcing Automation**: Organizations must build robust certificate lifecycle management. This operational maturity pays dividends in incident response and compliance.

**EST as the Solution**: Manual CSR generation, approval workflows, and certificate installation cannot scale to 47-day lifetimes. EST provides:
- Automated enrollment via `/simpleenroll`
- Automated renewal via `/simplereenroll`
- Automated trust anchor updates via `/cacerts`
- Standard protocol implemented by network equipment, IoT devices, operating systems

### Operational Recommendations

Set `max_validity_days` to 90 days for new CAs. This provides:
- Compliance with current and near-term CA/B Forum limits
- 30-day renewal buffer (renew at 60 days remaining)
- Operational experience with short-lived certificates before 47-day limit

For existing CAs, plan a staged reduction:
- 2026: 180 days
- 2027: 90 days
- 2029: 45 days

Use monitoring to track certificate expiration across your fleet. Alert when certificates are not renewed on schedule. EST's `/simplereenroll` should be triggered automatically when 1/3 of the validity period remains.

### Internal vs. Publicly-Trusted CAs

CA/B Forum limits apply only to publicly-trusted CAs (trust anchors in browser and OS trust stores). Internal CAs can use longer lifetimes:

```toml
[[ca]]
id = "internal-ca"
cert = "/etc/kipuka/ca/internal-ca.crt"
key = "/etc/kipuka/ca/internal-ca.key"
chain = "/etc/kipuka/ca/chain.pem"
max_validity_days = 365  # Internal CA, not subject to CA/B Forum
```

However, adopting short lifetimes even for internal CAs provides operational benefits (automation, reduced compromise windows) and prepares infrastructure for future regulatory requirements.
