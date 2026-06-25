# CMP Protocol Configuration

The Certificate Management Protocol (CMP) is defined in RFC 4210 and updated in RFC 9810 (CMP v3). kipuka implements CMP as an alternative to EST for certificate lifecycle operations, providing stronger cryptographic protection options and more granular control over request types.

## Overview

### CMP vs EST

While EST provides a simpler REST-based API over HTTP, CMP offers:

- **Stronger authentication**: MAC-based or signature-based protection of all messages
- **Fine-grained request control**: Enable/disable specific operations (initial enrollment, renewal, revocation)
- **Standardized error handling**: Well-defined error codes and failure messages
- **Vendor interoperability**: Widely implemented in enterprise PKI systems

CMP runs alongside EST on the same server. The endpoint is located at:

```
/.well-known/cmp
```

## Configuration

Enable CMP in your `kipuka.toml` configuration file:

```toml
[cmp]
enabled = true

# Request types allowed
allow_ir = true      # Initialization Request (initial enrollment)
allow_cr = true      # Certification Request (enrollment with existing cert)
allow_kur = true     # Key Update Request (renewal/rekey)
allow_rr = false     # Revocation Request (certificate revocation)

# Protection mechanisms
allow_mac_protection = true
mac_algorithm = "hmac-sha256"  # Options: hmac-sha256, hmac-sha384, hmac-sha512

# Certificate profile for new enrollments
reference_cert_profile = "server-cert"

# MAC shared secrets for authentication
[[cmp.mac_secrets]]
reference = "device-001"
secret_hex = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6"

[[cmp.mac_secrets]]
reference = "device-002"
secret_hex = "f1e2d3c4b5a69788796a5b4c3d2e1f0"
```

### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | bool | false | Enable CMP endpoint |
| `allow_ir` | bool | true | Allow initialization requests (first-time enrollment) |
| `allow_cr` | bool | true | Allow certification requests (enrollment with proof-of-possession) |
| `allow_kur` | bool | true | Allow key update requests (renewal/rekey) |
| `allow_rr` | bool | false | Allow revocation requests |
| `allow_mac_protection` | bool | true | Accept MAC-protected messages |
| `mac_algorithm` | string | "hmac-sha256" | MAC algorithm for protection |
| `reference_cert_profile` | string | None | Default certificate profile |

## Protection Mechanisms

CMP supports two message protection modes:

### MAC-Based Protection

MAC-based protection uses a pre-shared secret between the client and server. This is suitable for automated enrollment scenarios where devices are provisioned with shared secrets.

**Advantages:**
- No existing certificate required for initial enrollment
- Simpler client implementation
- Suitable for IoT and embedded devices

**Configuration:**

```toml
[[cmp.mac_secrets]]
reference = "fleet-alpha"
secret_hex = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
```

The `reference` field matches the `sender` field in the CMP message header. The `secret_hex` must be a hex-encoded value (even number of characters).

### Signature-Based Protection

Signature-based protection uses an existing certificate to sign CMP messages. This provides stronger authentication when the client already possesses a valid certificate.

**Advantages:**
- Stronger cryptographic binding to identity
- No pre-shared secrets to manage
- Required for CR and KUR operations in high-security environments

**Configuration:**

Signature-based protection is automatically available when `allow_mac_protection = true` is not the only protection method configured. Clients provide their certificate chain in the `extraCerts` field.

## Request Types

### IR (Initialization Request)

Used for first-time enrollment when the client has no existing certificate.

**Requirements:**
- `allow_ir = true`
- MAC protection or administrator-approved request
- Valid proof-of-possession (POP) in the request

**Example curl command** (using MAC protection):

```bash
# Note: CMP uses binary ASN.1 encoding; this is a conceptual example
# Real CMP clients use libraries like OpenSSL, Bouncy Castle, or CMP-native tools

openssl cmp -cmd ir \
  -server https://est.example.com/.well-known/cmp \
  -ref "device-001" \
  -secret "pass:a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6" \
  -newkey device-key.pem \
  -certout device-cert.pem
```

### CR (Certification Request)

Used for enrollment when the client already has a certificate (possibly from another CA).

**Requirements:**
- `allow_cr = true`
- Signature-based protection using existing certificate
- Valid proof-of-possession

### KUR (Key Update Request)

Used for certificate renewal or rekey operations.

**Requirements:**
- `allow_kur = true`
- Signature-based protection using current certificate
- New public key (for rekey) or same key (for renewal)

**Example curl command:**

```bash
openssl cmp -cmd kur \
  -server https://est.example.com/.well-known/cmp \
  -cert current-cert.pem \
  -key current-key.pem \
  -newkey new-key.pem \
  -certout renewed-cert.pem
```

### RR (Revocation Request)

Used to revoke a certificate.

**Requirements:**
- `allow_rr = true` (disabled by default for security)
- Signature-based protection
- Authorization check against certificate ownership

**Security Note:** Revocation requests should be carefully controlled. Consider keeping `allow_rr = false` and using the administrative API for revocations instead.

## Security Considerations

### MAC Secret Management

1. **Generate strong secrets**: Use at least 32 bytes (256 bits) of cryptographically random data
   ```bash
   openssl rand -hex 32
   ```

2. **Unique secrets per device**: Never reuse MAC secrets across multiple devices

3. **Rotation**: Plan for periodic secret rotation. Update both server configuration and device provisioning.

4. **Storage**: Protect `kipuka.toml` with appropriate file permissions (0600). Consider using environment variables or secret management systems for production deployments.

### Algorithm Selection

The default `hmac-sha256` provides 256-bit security strength, suitable for most deployments. Use stronger algorithms for high-security environments:

```toml
mac_algorithm = "hmac-sha384"  # 384-bit security
mac_algorithm = "hmac-sha512"  # 512-bit security
```

Ensure clients support the selected algorithm.

### Request Type Restrictions

Disable unused request types to reduce attack surface:

```toml
# Production configuration for renewal-only deployment
allow_ir = false   # Initial enrollment via EST only
allow_cr = false   # No cross-CA enrollment
allow_kur = true   # Renewal enabled
allow_rr = false   # Revocation via admin API only
```

## Troubleshooting

### Client reports "MAC verification failed"

**Cause:** Mismatch between client and server shared secret, or incorrect reference number.

**Solution:**
1. Verify the `reference` field in the client configuration matches a `[[cmp.mac_secrets]]` entry
2. Confirm the shared secret is identical (case-sensitive hex string)
3. Check server logs for the reference number received

### "Request type not allowed" error

**Cause:** The requested operation (IR, CR, KUR, RR) is disabled in server configuration.

**Solution:**
1. Check `allow_ir`, `allow_cr`, `allow_kur`, `allow_rr` settings
2. Enable the required request type or use an alternative enrollment method (EST)

### Certificate profile errors

**Cause:** `reference_cert_profile` points to a non-existent profile.

**Solution:**
1. Verify the profile name matches an entry in the `[cert_profiles]` section
2. Remove `reference_cert_profile` to use the default profile
3. Check server logs for available profile names

### Performance issues with many devices

**Solution:**
- Consider using signature-based protection for high-volume deployments (eliminates MAC secret storage per device)
- Implement client-side caching of CA certificates
- Use HTTP/2 connection pooling

## Integration Examples

### IoT Device Provisioning

Provision devices with unique MAC secrets during manufacturing:

```toml
[[cmp.mac_secrets]]
reference = "sensor-{{ DEVICE_SERIAL }}"
secret_hex = "{{ PROVISIONED_SECRET }}"
```

Use template expansion in your provisioning system to generate unique entries.

### Enterprise PKI Integration

Allow CMP for renewals, EST for initial enrollment:

```toml
[cmp]
enabled = true
allow_ir = false   # Use EST for initial enrollment
allow_kur = true   # CMP for renewals
allow_mac_protection = false  # Signature-based only
```

### Air-Gapped Environments

Combine CMP with CMS-EST for disconnected operations:

```toml
[cmp]
enabled = true
allow_mac_protection = true

[cms_est]
enabled = true
require_signed_requests = true
```

See [CMS-EST Configuration](cms-est.md) for details on offline enrollment workflows.
