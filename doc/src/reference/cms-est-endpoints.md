# CMS-EST Endpoints

kipuka supports CMS-based EST (RFC 8295) for enhanced security through Cryptographic Message Syntax (CMS) wrapping. CMS-EST provides confidentiality (encryption), integrity (signing), and authentication beyond standard EST's TLS-only protection.

## Overview

Standard EST (RFC 7030) relies on TLS for transport security but transmits certificate requests and responses as plaintext PKCS#7 or PKCS#10 within the TLS tunnel. CMS-EST adds an additional layer by wrapping EST payloads in CMS structures:

- **Signed data** (`SignedData`): Authenticates sender and ensures integrity
- **Enveloped data** (`EnvelopedData`): Encrypts payload for confidentiality
- **Signed-and-enveloped data**: Combines both (sign-then-encrypt)

**Use cases:**
- Defense-in-depth security (protect against TLS compromise)
- End-to-end encryption between client and CA (bypassing intermediate proxies)
- Compliance requirements (NIAP, FIPS) mandating application-layer encryption
- Protection of sensitive CSR attributes (email, organizationIdentifier)

## Endpoint Paths

CMS-EST uses the same operation names as standard EST but under the `/.well-known/cms-est/` prefix:

| Endpoint | HTTP Method | Description |
|----------|-------------|-------------|
| `/.well-known/cms-est/cacerts` | GET | Retrieve CA certificate chain (CMS-wrapped) |
| `/.well-known/cms-est/csrattrs` | GET | Retrieve CSR attributes hint (CMS-wrapped) |
| `/.well-known/cms-est/simpleenroll` | POST | Simple enrollment (CMS-wrapped CSR → CMS-wrapped certificate) |
| `/.well-known/cms-est/simplereenroll` | POST | Simple re-enrollment (renewal with proof-of-possession) |
| `/.well-known/cms-est/serverkeygen` | POST | Server-side key generation (CMS-wrapped response with encrypted private key) |
| `/.well-known/cms-est/fullcmc` | POST | Full CMC (Certificate Management over CMS, RFC 5272) |

**Note:** `/fullcmc` is available in both standard EST and CMS-EST. In CMS-EST, the CMC request itself is CMS-wrapped for double encapsulation.

## Content Types

CMS-EST uses different MIME types than standard EST to indicate CMS wrapping:

### Standard EST (for comparison)

| Operation | Request Content-Type | Response Content-Type |
|-----------|---------------------|----------------------|
| `/simpleenroll` | `application/pkcs10` | `application/pkcs7-mime; smime-type=certs-only` |
| `/simplereenroll` | `application/pkcs10` | `application/pkcs7-mime; smime-type=certs-only` |
| `/cacerts` | N/A (GET) | `application/pkcs7-mime; smime-type=certs-only` |

### CMS-EST

| Operation | Request Content-Type | Response Content-Type |
|-----------|---------------------|----------------------|
| `/simpleenroll` | `application/pkcs7-mime; smime-type=CMC-request` (signed) | `application/pkcs7-mime; smime-type=CMC-response` (signed) |
| `/simplereenroll` | `application/pkcs7-mime; smime-type=CMC-request` | `application/pkcs7-mime; smime-type=CMC-response` |
| `/serverkeygen` | `application/pkcs7-mime; smime-type=CMC-request` | `application/pkcs7-mime; smime-type=enveloped-data` (encrypted private key) |
| `/cacerts` | N/A (GET) | `application/pkcs7-mime; smime-type=certs-only` (same as standard EST) |
| `/csrattrs` | N/A (GET) | `application/pkcs7-mime; smime-type=CMC-response` (signed attributes) |

**Key differences:**
1. **Requests** use `smime-type=CMC-request` instead of `application/pkcs10`
2. **Responses** use `smime-type=CMC-response` instead of `smime-type=certs-only`
3. **Enveloped data** (`smime-type=enveloped-data`) for encrypted payloads (serverkeygen)

## CMS Wrapping Details

### Signed Data (SignedData)

Used for authentication and integrity. The original EST payload (PKCS#10 CSR or certificate response) is embedded in a CMS `SignedData` structure.

**Structure:**
```asn1
SignedData ::= SEQUENCE {
  version CMSVersion,
  digestAlgorithms DigestAlgorithmIdentifiers,
  encapContentInfo EncapsulatedContentInfo,  -- Contains original payload
  certificates [0] IMPLICIT CertificateSet OPTIONAL,  -- Signer's cert chain
  signerInfos SignerInfos  -- Digital signature
}
```

**Verification:**
1. Extract signer certificate from `certificates` field
2. Verify certificate chain against CA bundle
3. Validate signature in `signerInfos` using signer's public key
4. Check signer certificate is not revoked (CRL/OCSP)

### Enveloped Data (EnvelopedData)

Used for confidentiality. The payload is encrypted with a symmetric key (AES-256-GCM), and the symmetric key is encrypted with the recipient's public key.

**Structure:**
```asn1
EnvelopedData ::= SEQUENCE {
  version CMSVersion,
  recipientInfos RecipientInfos,  -- Encrypted symmetric key
  encryptedContentInfo EncryptedContentInfo  -- Encrypted payload
}
```

**Decryption:**
1. Extract `recipientInfos` (key encryption key, KEK)
2. Decrypt KEK using recipient's private key (RSA-OAEP or ECDH)
3. Decrypt `encryptedContentInfo` using KEK (AES-256-GCM)
4. Parse decrypted payload as ASN.1 DER

### Signed-and-Enveloped Data

For requests requiring both authentication and confidentiality, the payload is signed first, then the `SignedData` structure is enveloped:

```
Original CSR → SignedData → EnvelopedData → CMS-EST request
```

Recipient decrypts the envelope, then verifies the signature.

## Example Requests

### Example 1: Simple Enrollment (Signed CSR)

**Request:**
```http
POST /.well-known/cms-est/simpleenroll HTTP/1.1
Host: ca.example.com
Content-Type: application/pkcs7-mime; smime-type=CMC-request
Content-Length: 1456

[Binary CMS SignedData containing PKCS#10 CSR]
```

**CMS structure:**
```asn1
SignedData {
  digestAlgorithms: { sha256 }
  encapContentInfo: {
    eContentType: id-data (1.2.840.113549.1.7.1)
    eContent: [PKCS#10 CSR in DER format]
  }
  certificates: [client_cert, issuing_ca_cert]
  signerInfos: {
    sid: IssuerAndSerialNumber (client_cert)
    digestAlgorithm: sha256
    signatureAlgorithm: rsaEncryption (or ECDSA)
    signature: BIT STRING
  }
}
```

**Response:**
```http
HTTP/1.1 200 OK
Content-Type: application/pkcs7-mime; smime-type=CMC-response
Content-Length: 2048

[Binary CMS SignedData containing issued certificate]
```

**CMS structure:**
```asn1
SignedData {
  encapContentInfo: {
    eContentType: id-data
    eContent: [Issued X.509 certificate in DER format]
  }
  certificates: [ca_cert_chain]
  signerInfos: {
    sid: SubjectKeyIdentifier (CA signing key)
    signatureAlgorithm: sha256WithRSAEncryption
    signature: BIT STRING (CA signature over certificate)
  }
}
```

### Example 2: Server Key Generation (Enveloped Response)

**Request:**
```http
POST /.well-known/cms-est/serverkeygen HTTP/1.1
Host: ca.example.com
Content-Type: application/pkcs7-mime; smime-type=CMC-request
Content-Length: 892

[Binary CMS SignedData containing server-keygen request]
```

**Request payload:**
- `encapContentInfo.eContent`: Empty or minimal CSR (no key material, CA generates key)

**Response:**
```http
HTTP/1.1 200 OK
Content-Type: application/pkcs7-mime; smime-type=enveloped-data
Content-Length: 3456

[Binary CMS EnvelopedData containing certificate + encrypted private key]
```

**CMS structure:**
```asn1
EnvelopedData {
  version: 0
  recipientInfos: {
    rid: IssuerAndSerialNumber (client_cert)
    keyEncryptionAlgorithm: rsaesOaep (RSA-OAEP with SHA-256)
    encryptedKey: [Encrypted AES-256 key]
  }
  encryptedContentInfo: {
    contentType: id-data
    contentEncryptionAlgorithm: aes256-GCM
    encryptedContent: [Encrypted payload = issued cert + PKCS#8 private key]
  }
}
```

**Decrypted payload:**
- Certificate in DER format
- PKCS#8 `EncryptedPrivateKeyInfo` (private key encrypted with client's transport key)

### Example 3: Retrieve CA Certificates (No CMS Difference)

**Request:**
```http
GET /.well-known/cms-est/cacerts HTTP/1.1
Host: ca.example.com
```

**Response:**
```http
HTTP/1.1 200 OK
Content-Type: application/pkcs7-mime; smime-type=certs-only
Content-Length: 2048

[Binary PKCS#7 certs-only structure (same as standard EST)]
```

**Note:** `/cacerts` does not require CMS wrapping in most implementations, since it's public data. RFC 8295 allows this for simplicity.

## Differences from Standard EST

| Aspect | Standard EST | CMS-EST |
|--------|-------------|---------|
| **Request format** | PKCS#10 CSR (DER) | CMS SignedData containing PKCS#10 CSR |
| **Response format** | PKCS#7 certs-only | CMS SignedData or EnvelopedData |
| **Content-Type (request)** | `application/pkcs10` | `application/pkcs7-mime; smime-type=CMC-request` |
| **Content-Type (response)** | `application/pkcs7-mime; smime-type=certs-only` | `application/pkcs7-mime; smime-type=CMC-response` |
| **Authentication** | TLS client certificate or HTTP Basic Auth | CMS signature (signed request) |
| **Confidentiality** | TLS transport encryption only | CMS enveloped data (end-to-end encryption) |
| **Proof-of-possession** | Self-signed CSR signature | CMS signature over request |
| **Use case** | General EST deployments | High-security, defense-in-depth, compliance |

## OpenSSL Examples

### Generate CMS-EST enrollment request

```bash
# Generate key pair
openssl genrsa -out device.key 2048

# Create PKCS#10 CSR (standard)
openssl req -new -key device.key \
  -subj "/CN=device003.example.com/O=Example Inc" \
  -out device.csr

# Wrap CSR in CMS SignedData
openssl cms -sign \
  -in device.csr \
  -signer client-cert.pem \
  -inkey client-key.pem \
  -out cms-request.der \
  -outform DER \
  -binary

# Send to CA
curl -X POST https://ca.example.com/.well-known/cms-est/simpleenroll \
  -H "Content-Type: application/pkcs7-mime; smime-type=CMC-request" \
  --data-binary @cms-request.der \
  -o cms-response.der
```

### Verify and extract certificate from CMS response

```bash
# Verify CMS signature
openssl cms -verify \
  -in cms-response.der \
  -inform DER \
  -CAfile ca-bundle.pem \
  -out cert.der

# Convert to PEM
openssl x509 -in cert.der -inform DER -out cert.pem

# Inspect certificate
openssl x509 -in cert.pem -text -noout
```

### Decrypt serverkeygen response (EnvelopedData)

```bash
# Receive encrypted response from CA
curl -X POST https://ca.example.com/.well-known/cms-est/serverkeygen \
  -H "Content-Type: application/pkcs7-mime; smime-type=CMC-request" \
  --data-binary @cms-serverkeygen-req.der \
  -o cms-encrypted-response.der

# Decrypt using client certificate's private key
openssl cms -decrypt \
  -in cms-encrypted-response.der \
  -inform DER \
  -recip client-cert.pem \
  -inkey client-key.pem \
  -out decrypted-payload.der

# Extract certificate and private key
# (payload format is application-specific; may be concatenated DER or PKCS#12)
```

## Security Considerations

1. **TLS is still required** – CMS-EST is not a replacement for TLS. Always use HTTPS.
2. **Validate CMS signatures** – Verify `SignedData` against trusted CA bundle before processing.
3. **Check certificate revocation** – Ensure signer certificates are not revoked (CRL/OCSP).
4. **Use strong algorithms** – Require SHA-256+ for digests, RSA-3072+/ECDSA-P256+ for signatures.
5. **Protect recipient keys** – Private keys for decrypting `EnvelopedData` must be HSM-protected.
6. **Audit all operations** – Log CMS signature validation results and decryption attempts.
7. **Limit request size** – CMS wrapping increases payload size; enforce `max_body_size` limits (e.g., 1 MB).

## Configuration

Enable CMS-EST in `kipuka.toml`:

```toml
[cms_est]
enabled = true
endpoint_prefix = "/.well-known/cms-est"
require_signed_requests = true
require_enveloped_responses = false  # Set true for high-security deployments
max_message_size = 1048576  # 1 MB
allowed_digest_algorithms = ["SHA-256", "SHA-384", "SHA-512"]
allowed_signature_algorithms = ["RSA-PSS", "ECDSA", "Ed25519"]
allowed_encryption_algorithms = ["AES-256-GCM", "AES-256-CBC"]
```

## Troubleshooting

### CMS signature verification failed

**Symptom:** HTTP 400 Bad Request with "CMS signature verification failed".

**Causes:**
- Signer certificate expired or revoked
- Signer certificate not in `certificates` field
- CA bundle doesn't include signer's issuing CA
- Signature algorithm not allowed (e.g., SHA-1, MD5)

**Fix:**
- Verify signer certificate: `openssl x509 -in cert.pem -text -noout`
- Check revocation: `openssl ocsp -issuer ca.pem -cert cert.pem -url http://ocsp.example.com`
- Update CA bundle with intermediate CAs

### Decryption failed (EnvelopedData)

**Symptom:** `openssl cms -decrypt` fails with "wrong recipient".

**Causes:**
- RecipientInfo references wrong certificate
- Private key doesn't match recipient certificate
- Unsupported key encryption algorithm

**Fix:**
- Inspect `recipientInfos`: `openssl asn1parse -in cms-response.der -inform DER`
- Verify certificate matches: `openssl x509 -in cert.pem -pubkey -noout | openssl dgst -sha256`
- Use supported KEK algorithms: RSA-OAEP (preferred) or RSAES-PKCS1-v1_5 (legacy)

### Payload too large

**Symptom:** HTTP 413 Payload Too Large.

**Cause:** CMS wrapping increased request size beyond `max_message_size`.

**Fix:**
- Increase `max_message_size` to 2 MB or 5 MB
- Reduce certificate chain length in `certificates` field (send only leaf cert)
- Use DER instead of PEM (smaller encoding)

## References

- RFC 8295: EST Extensions
- RFC 5652: Cryptographic Message Syntax (CMS)
- RFC 3370: Cryptographic Message Syntax (CMS) Algorithms
- RFC 5083: Cryptographic Message Syntax (CMS) Authenticated-Enveloped-Data Content Type
- RFC 7030: Enrollment over Secure Transport (EST)
